import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_repository.dart';
import 'app_models.dart';
import 'widgets.dart';
import 'ui_theme.dart';
import 'ride_reader_service.dart';
import 'ride_reader_queue.dart';
import 'location_tracking_service.dart';
import 'cache_service.dart';
import 'core/input_rules.dart';

StreamSubscription<String>? _fcmTokenSubscription;

Future<void> _registerFcmToken() async {
  final messaging = FirebaseMessaging.instance;
  await messaging.requestPermission();
  await messaging.setForegroundNotificationPresentationOptions(
    alert: true,
    badge: true,
    sound: true,
  );
  final token = await messaging.getToken();
  final uid = FirebaseAuth.instance.currentUser?.uid;
  if (uid != null && token != null && token.isNotEmpty) {
    await FirebaseFirestore.instance.collection('users').doc(uid).set({
      'fcmTokens': FieldValue.arrayUnion([token]),
    }, SetOptions(merge: true));
  }
  await _fcmTokenSubscription?.cancel();
  _fcmTokenSubscription = messaging.onTokenRefresh.listen((next) async {
    final currentUid = FirebaseAuth.instance.currentUser?.uid;
    if (currentUid != null) {
      await FirebaseFirestore.instance.collection('users').doc(currentUid).set({
        'fcmTokens': FieldValue.arrayUnion([next]),
      }, SetOptions(merge: true));
    }
  });
}

Future<void> logout(BuildContext c) async {
  if (Trip.I.active) {
    if (c.mounted) {
      snack(c, 'End the active trip before logging out.', warn: true);
    }
    return;
  }
  final pending = await RideReaderQueue().pendingCount();
  if (pending > 0 && c.mounted) {
    final upload = await showDialog<bool>(
      context: c,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Pending uploads'),
        content: Text('$pending event(s) are waiting to upload.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Log out anyway'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Upload now'),
          ),
        ],
      ),
    );
    if (upload == null) return;
    if (upload) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
  await RideReaderService.disconnectAll();
  await _stopTracking();
  await SessionLifecycle.reset();
  Trip.I.clear();
  await RideReaderQueue().close();
  try {
    final token = await FirebaseMessaging.instance.getToken();
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null && token != null) {
      await FirebaseFirestore.instance.collection('users').doc(uid).set({
        'fcmTokens': FieldValue.arrayRemove([token]),
      }, SetOptions(merge: true));
    }
  } catch (error, stackTrace) {
    developer.log(
      'FCM token cleanup failed during logout',
      name: 'rideguard.auth',
      error: error,
      stackTrace: stackTrace,
    );
  } finally {
    await _fcmTokenSubscription?.cancel();
    _fcmTokenSubscription = null;
    await AuthRepository(
      FirebaseAuth.instance,
      FirebaseFirestore.instance,
      FirebaseFunctions.instance,
    ).signOut().timeout(const Duration(seconds: 10));
  }
  if (c.mounted) {
    Navigator.of(c, rootNavigator: true).popUntil((route) => route.isFirst);
  }
}

Future<void> _stopTracking() async {
  await LocationTrackingService.stopAll();
}

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _form = GlobalKey<FormState>();
  final _phone = TextEditingController();
  final _pw = TextEditingController();
  bool _loading = false;
  bool _obscureNic = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _resumeSession();
  }

  Future<void> _resumeSession() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;
      final repository = ref.read(authRepositoryProvider);
      if (!await repository.hasValidSession()) {
        await repository.signOut();
        return;
      }
      await user.getIdToken(true);
      await repository.loadAccess(user);
    } catch (error, stackTrace) {
      developer.log(
        'Unable to restore session',
        name: 'rideguard.auth',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    if (_loading) return;
    setState(() {
      _error = null;
      _loading = true;
    });
    try {
      final access = await ref.read(authRepositoryProvider).signIn(
            phoneOrEmail: _phone.text,
            password: _pw.text,
          );
      unawaited(RideGuardCacheService(FirebaseFirestore.instance).warmForUser(
        uid: access.uid,
        roles: access.roles,
      ));
      try {
        await _registerFcmToken().timeout(authRequestTimeout);
      } catch (error, stackTrace) {
        developer.log(
          'FCM token registration failed after sign-in',
          name: 'rideguard.auth',
          error: error,
          stackTrace: stackTrace,
        );
      }
    } on FirebaseAuthException catch (error) {
      final message = switch (error.code) {
        'invalid-credential' ||
        'user-not-found' ||
        'wrong-password' =>
          'Wrong phone number or NIC number / password. (LG-1)',
        'user-disabled' =>         'This account is disabled. (LG-2)',
        'network-request-failed' =>         'No connection. Please try again. (LG-5)',
        'invalid-email' || 'invalid-phone-number' =>
          'Enter a valid phone number. (LG-6)',
        'too-many-requests' =>         'Too many attempts. Try again later. (LG-1)',
        'profile-missing' =>
          'Your account is not fully set up. Contact your admin. (LG-3)',
        _ => 'Sign-in failed. Contact the admin. (LG-6)',
      };
      developer.log(
        'Firebase Auth sign-in rejected (${error.code})',
        name: 'rideguard.auth',
        error: error,
      );
      if (!mounted) return;
      setState(() => _error = message);
    } on FirebaseException catch (error) {
      developer.log('Account profile load failed: ${error.code}',
          name: 'rideguard.auth', error: error);
      if (!mounted) return;
      final callableCode = error is FirebaseFunctionsException
          ? error.message
          : null;
      setState(() => _error = switch (error.code) {
            'profile-missing' ||
            'failed-precondition' when callableCode == 'PROFILE_MISSING' =>
              'Your account is not fully set up. Contact your admin. (LG-3)',
            'failed-precondition' when callableCode == 'ACCOUNT_DISABLED' ||
                error.code == 'user-disabled' =>
              'This account is disabled. (LG-2)',
            'permission-denied' =>
              'Unable to load your account. Try again or contact your admin. (LG-4)',
            'unavailable' ||
            'deadline-exceeded' =>
              'Unable to reach RideGuard. Check your connection and try again. (LG-5)',
            _ =>
              'Unable to load your account. Try again or contact your admin. (LG-4)',
          });
    } catch (error, stackTrace) {
      developer.log(
        'Sign-in failed outside Firebase Auth',
        name: 'rideguard.auth',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      setState(() =>
          _error = 'Unable to sign in. Check your connection and try again. (LG-6)');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Theme(
      data: RideTheme.light(),
      child: Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Form(
                  key: _form,
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Center(
                          child: Image.asset(
                            'assets/images/logo_extended.png',
                            width: 280,
                            height: 96,
                            fit: BoxFit.contain,
                          ),
                        ),
                        const SizedBox(height: 8),
                        const SizedBox(height: 28),
                        TextFormField(
                          controller: _phone,
                          keyboardType: TextInputType.phone,
                          decoration: const InputDecoration(
                              labelText: 'Phone number',
                              prefixIcon: Icon(Icons.phone)),
                          validator: (v) {
                            if (v == null || v.trim().isEmpty) {
                              return 'Enter a phone number.';
                            }
                            return canonicalPhone(v) != null
                                ? null
                                : 'Enter a valid phone number.';
                          },
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _pw,
                          obscureText: _obscureNic,
                          autocorrect: false,
                          enableSuggestions: false,
                          textCapitalization: TextCapitalization.none,
                          decoration: InputDecoration(
                            labelText: 'NIC number / password',
                            prefixIcon: const Icon(Icons.lock),
                            suffixIcon: IconButton(
                              tooltip: _obscureNic
                                  ? 'Show password'
                                  : 'Hide password',
                              icon: Icon(_obscureNic
                                  ? Icons.visibility
                                  : Icons.visibility_off),
                              onPressed: () =>
                                  setState(() => _obscureNic = !_obscureNic),
                            ),
                          ),
                          validator: (v) => v == null || v.trim().isEmpty
                              ? 'Enter your NIC number.'
                              : null,
                        ),
                        if (_error != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                  color: s.errorContainer,
                                  borderRadius: BorderRadius.circular(8)),
                              child: Text(_error!,
                                  style: TextStyle(color: s.onErrorContainer)),
                            ),
                          ),
                        const SizedBox(height: 20),
                        FilledButton(
                            onPressed: _loading ? null : _submit,
                            child: _loading
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Text('Log in')),
                        TextButton(
                          onPressed: () => showForgotCredentialsDialog(context),
                          child: const Text('Forgot password?'),
                        ),
                      ]),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> showForgotCredentialsDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Forgot password?'),
      content: const Text(
        'Use your NIC number and your mobile phone number to log in. '
        'If you forgot them, contact your driver or admin.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key, required this.role});
  final Role role;

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      return const Center(child: Text('Sign in to view your profile.'));
    }
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream:
          FirebaseFirestore.instance.collection('users').doc(uid).snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
              child: const Text('Unable to load profile. Please retry.'));
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final data = snapshot.data!.data() ?? const <String, dynamic>{};
        final name = data['name']?.toString().trim();
        final phone = data['phone']?.toString().trim();
        final email = data['email']?.toString().trim();
        final title = name?.isNotEmpty == true
            ? name!
            : email?.isNotEmpty == true
                ? email!
                : 'Signed-in user';
        final contact = phone?.isNotEmpty == true
            ? phone!
            : email?.isNotEmpty == true
                ? email!
                : roleName(widget.role);
        return ListView(padding: const EdgeInsets.all(16), children: [
          Card(
            child: ListTile(
              leading: const CircleAvatar(child: Icon(Icons.person)),
              title: Text(title),
              subtitle: Text('$contact  •  ${roleName(widget.role)}'),
            ),
          ),
          const SizedBox(height: 16),
          Text('Theme', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          ValueListenableBuilder<ThemeMode>(
            valueListenable: themeMode,
            builder: (_, m, __) => SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(
                    value: ThemeMode.system,
                    label: Text('Auto'),
                    icon: Icon(Icons.brightness_auto)),
                ButtonSegment(
                    value: ThemeMode.light,
                    label: Text('Light'),
                    icon: Icon(Icons.light_mode)),
                ButtonSegment(
                    value: ThemeMode.dark,
                    label: Text('Dark'),
                    icon: Icon(Icons.dark_mode)),
              ],
              selected: {m},
              onSelectionChanged: (v) => setThemeMode(v.first),
            ),
          ),
          const SizedBox(height: 24),
          OutlinedButton.icon(
              onPressed: () => logout(context),
              icon: const Icon(Icons.logout),
              label: const Text('Log out')),
        ]);
      },
    );
  }
}
