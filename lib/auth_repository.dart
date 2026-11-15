import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/input_rules.dart';
import 'dart:developer' as developer;

const sessionDuration = Duration(days: 25);
const authRequestTimeout = Duration(seconds: 15);
const _sessionExpiryKey = 'rideguard.session.expiresAt';

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  return AuthRepository(
    FirebaseAuth.instance,
    FirebaseFirestore.instance,
    FirebaseFunctions.instance,
  );
});

final authStateProvider = StreamProvider<User?>((ref) {
  return ref.watch(authRepositoryProvider).authStateChanges;
});

final accessProvider = FutureProvider<UserAccess?>((ref) async {
  final user = await ref.watch(authStateProvider.future);
  if (user == null) return null;
  return ref.watch(authRepositoryProvider).loadAccess(user);
});

class SessionLifecycle {
  static final Set<Future<void> Function()> _cleanups = {};

  static void register(Future<void> Function() cleanup) {
    _cleanups.add(cleanup);
  }

  static void unregister(Future<void> Function() cleanup) {
    _cleanups.remove(cleanup);
  }

  static Future<void> reset() async {
    final cleanups = List<Future<void> Function()>.of(_cleanups);
    _cleanups.clear();
    await Future.wait(cleanups.map((cleanup) async {
      try {
        await cleanup();
      } catch (error, stackTrace) {
        developer.log('Session resource cleanup failed',
            name: 'rideguard.auth', error: error, stackTrace: stackTrace);
      }
    }));
  }
}

Future<HttpsCallableResult<dynamic>> callWithFreshSession(
  String name, [
  Map<String, dynamic>? data,
  bool requireAuth = true,
  bool signOutOnUnauthenticated = true,
]) async {
  final auth = FirebaseAuth.instance;
  final user = auth.currentUser;
  if (user == null && requireAuth) {
    throw FirebaseFunctionsException(
      code: 'unauthenticated',
      message: 'Sign-in is required.',
    );
  }
  if (user == null) {
    return FirebaseFunctions.instance.httpsCallable(name).call(data);
  }
  await user.getIdToken();
  final callable = FirebaseFunctions.instance.httpsCallable(name);
  try {
    return await callable.call(data);
  } on FirebaseFunctionsException catch (error) {
    developer.log('Callable $name failed (${error.code})',
        name: 'rideguard.functions', error: error);
    if (error.code != 'unauthenticated') rethrow;
    final current = auth.currentUser;
    if (current == null) rethrow;
    try {
      await current.getIdToken(true);
    } on FirebaseAuthException catch (refreshError, stackTrace) {
      developer.log('Auth token refresh failed (${refreshError.code})',
          name: 'rideguard.auth',
          error: refreshError,
          stackTrace: stackTrace);
      if (signOutOnUnauthenticated &&
          const {
            'user-disabled',
            'user-not-found',
            'invalid-user-token',
          }.contains(refreshError.code)) {
        await SessionLifecycle.reset();
        await auth.signOut();
      }
      rethrow;
    }
    try {
      return await callable.call(data);
    } on FirebaseFunctionsException catch (retryError) {
      developer.log('Callable retry $name failed (${retryError.code})',
          name: 'rideguard.functions', error: retryError);
      rethrow;
    }
  }
}

class UserAccess {
  const UserAccess({
    required this.uid,
    required this.displayName,
    required this.roles,
    this.busId,
  });

  final String uid;
  final String displayName;
  final Set<String> roles;
  final String? busId;

  bool hasRole(String role) => roles.contains(role);

  factory UserAccess.fromDocument(
    User user,
    DocumentSnapshot<Map<String, dynamic>> document, {
    required Set<String> claimRoles,
  }) {
    final data = document.data() ?? const <String, dynamic>{};
    final rawRoles = data['roles'];
    final documentRoles = rawRoles is List
        ? rawRoles.whereType<String>().toSet()
        : rawRoles is Map
            ? rawRoles.entries
                .where((entry) => entry.value == true)
                .map((entry) => entry.key.toString())
                .toSet()
            : data['role'] is String
                ? {data['role'] as String}
                : data['userRole'] is String
                    ? {data['userRole'] as String}
                    : <String>{};
    final name = (data['fullName'] as String?)?.trim() ??
        (data['name'] as String?)?.trim();
    return UserAccess(
      uid: user.uid,
      displayName:
          name?.isNotEmpty == true ? name! : user.email ?? 'RideGuard user',
      roles: {...documentRoles, ...claimRoles},
      busId: data['busId'] as String?,
    );
  }
}

class AuthRepository {
  AuthRepository(this._auth, this._firestore, FirebaseFunctions _);

  final FirebaseAuth _auth;
  final FirebaseFirestore _firestore;
  final FlutterSecureStorage _sessionStorage = const FlutterSecureStorage();

  Stream<User?> get authStateChanges => _auth.authStateChanges();
  User? get currentUser => _auth.currentUser;

  Future<UserAccess> signIn({
    required String phoneOrEmail,
    required String password,
  }) async {
    final phone = canonicalPhone(phoneOrEmail);
    if (phone == null) {
      throw FirebaseAuthException(
        code: 'invalid-phone-number',
        message: 'A valid phone number is required.',
      );
    }
    final trimmedPassword = normalizeNic(password) ?? password.trim();
    UserCredential credential;
    try {
      credential = await _auth
          .signInWithEmailAndPassword(
            email: authIdentifier(phone),
            password: trimmedPassword,
          )
          .timeout(authRequestTimeout);
    } on FirebaseAuthException {
      rethrow;
    }
    final user = credential.user!;
    await user.getIdToken(true).timeout(authRequestTimeout);
    await _sessionStorage.write(
      key: _sessionExpiryKey,
      value: DateTime.now().toUtc().add(sessionDuration).toIso8601String(),
    );
    try {
      return await loadAccess(user).timeout(authRequestTimeout);
    } catch (_) {
      await SessionLifecycle.reset();
      rethrow;
    }
  }

  Future<bool> hasValidSession() async {
    final value = await _sessionStorage.read(key: _sessionExpiryKey);
    final expiry = value == null ? null : DateTime.tryParse(value);
    if (expiry == null || !expiry.isAfter(DateTime.now().toUtc())) {
      await _sessionStorage.delete(key: _sessionExpiryKey);
      return false;
    }
    return true;
  }

  Future<UserAccess> loadAccess(User user) async {
    await user.getIdToken(true).timeout(authRequestTimeout);
    await callWithFreshSession('ensureUserProfile')
        .timeout(authRequestTimeout);
    final token = await user.getIdTokenResult(true).timeout(authRequestTimeout);
    final claims = token.claims ?? const <String, dynamic>{};
    var document = await _firestore
        .collection('users')
        .doc(user.uid)
        .get()
        .timeout(authRequestTimeout);
    final data = document.data();
    final legacyDisabled = data?['disabled'] == true;
    final bool enabled;
    if (data?['enabled'] is bool) {
      enabled = data!['enabled'] as bool;
    } else if (data?['isAvailable'] is bool) {
      enabled = data!['isAvailable'] as bool;
    } else {
      enabled = !legacyDisabled;
    }
    if (!document.exists || !enabled) {
      throw FirebaseException(
        plugin: 'firebase_auth',
        code: document.exists ? 'user-disabled' : 'profile-missing',
      );
    }
    final roles = <String>{};
    final rawRoles = claims['roles'];
    if (rawRoles is List) {
      roles.addAll(rawRoles.whereType<String>());
    } else if (rawRoles is Map) {
      roles.addAll(rawRoles.entries
          .where((entry) => entry.value == true)
          .map((entry) => entry.key.toString()));
    }
    for (final role in const ['admin', 'driver', 'parent']) {
      if (claims[role] == true) roles.add(role);
    }
    return UserAccess.fromDocument(user, document, claimRoles: roles);
  }

  Future<void> signOut() async {
    try {
      await _sessionStorage.delete(key: _sessionExpiryKey);
    } finally {
      await _auth.signOut();
    }
  }
}
