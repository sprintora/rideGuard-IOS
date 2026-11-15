import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:path_provider/path_provider.dart';

MapCachingProvider? rideGuardMapCachingProvider;

typedef CachedDoc = QueryDocumentSnapshot<Map<String, dynamic>>;
typedef CachedQueryBuilder = Query<Map<String, dynamic>> Function(
    CollectionReference<Map<String, dynamic>> collection);

/// Shared, read-efficient access layer for Firestore plus the map tile cache.
///
/// How it saves reads:
///  * One in-memory copy per collection/query, reused by every screen until
///    its TTL expires (no more "open a form = read 5 collections").
///  * Concurrent callers share one in-flight request.
///  * Optional delta sync (`delta: true`): after one full read, only documents
///    whose `updatedAt` changed are fetched. The result is merged into the
///    cached copy, which is seeded from Firestore's free local cache on a cold
///    start. A full re-sync runs every [fullSyncInterval].
///  * Writers call [invalidate] so the next read refreshes (cheaply, via delta
///    when enabled) instead of re-reading everything.
///  * Offline / error: stale data or Firestore's local persistence is served.
///  * The cache is dropped automatically when a different user signs in.
///
/// `RideGuardCacheService(firestore)` always returns the same instance, so
/// existing call sites keep working and screens can use
/// [RideGuardCacheService.instance].
class RideGuardCacheService {
  factory RideGuardCacheService(FirebaseFirestore firestore) =>
      _instance ??= RideGuardCacheService._(firestore);

  RideGuardCacheService._(this._firestore);

  static RideGuardCacheService? _instance;

  static RideGuardCacheService get instance =>
      _instance ??= RideGuardCacheService._(FirebaseFirestore.instance);

  static const Duration defaultTtl = Duration(minutes: 10);
  static const Duration fullSyncInterval = Duration(hours: 24);
  static const Duration _warmInterval = Duration(minutes: 15);

  /// Collections that change often get a shorter TTL.
  static const Map<String, Duration> _ttlOverrides = {
    'cards': Duration(minutes: 2),
  };

  /// Call once right after `Firebase.initializeApp()` and before any other
  /// Firestore call. Enables the on-device Firestore cache.
  static void configureFirestore(FirebaseFirestore firestore) {
    firestore.settings = const Settings(
      persistenceEnabled: true,
      cacheSizeBytes: 200 * 1024 * 1024,
    );
  }

  final FirebaseFirestore _firestore;

  final Map<String, _Entry> _entries = {};
  final Map<String, _DocEntry> _docs = {};
  final Map<String, _SyncState> _syncStates = {};
  final Map<String, DateTime> _warmedAt = {};
  String? _activeUid;
  Future<void>? _stateLoad;
  Future<void>? _mapInit;

  // ---------------------------------------------------------------- map tiles

  Future<void> initialize() => _mapInit ??= _initializeMapCache();

  Future<void> _initializeMapCache() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      rideGuardMapCachingProvider =
          BuiltInMapCachingProvider.getOrCreateInstance(
        cacheDirectory: directory.path,
        maxCacheSize: 500 * 1024 * 1024,
        overrideFreshAge: const Duration(days: 30),
      );
      developer.log(
        'Persistent map cache initialized at ${directory.path}',
        name: 'rideguard.cache',
      );
    } catch (error, stackTrace) {
      _mapInit = null; // allow a retry
      developer.log(
        'Unable to initialize map cache',
        name: 'rideguard.cache',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  // ------------------------------------------------------------------ reads

  /// Returns the documents of [name]. Deleted documents (`deleted == true`)
  /// are hidden unless [includeDeleted] is set.
  ///
  /// Pass [scope] (with a unique [scopeKey]) for filtered queries.
  /// [delta] is only valid for unscoped collections whose documents always
  /// carry an `updatedAt` server timestamp.
  Future<List<CachedDoc>> collection(
    String name, {
    CachedQueryBuilder? scope,
    String? scopeKey,
    Duration? ttl,
    bool forceRefresh = false,
    bool delta = false,
    bool includeDeleted = false,
  }) async {
    assert(scope == null || scopeKey != null, 'scopeKey is required');
    await _bindUser();
    final key = scope == null ? name : '$name|$scopeKey';
    final entry = _entries.putIfAbsent(key, _Entry.new);
    final maxAge = ttl ?? _ttlFor(name);
    if (forceRefresh || !entry.isFresh(maxAge)) {
      await (entry.inFlight ??= _refresh(
        name,
        entry,
        scope,
        delta && scope == null,
      ).whenComplete(() {
        entry.inFlight = null;
      }));
    }
    return entry.docs.values
        .where((doc) => includeDeleted || doc.data()['deleted'] != true)
        .toList(growable: false);
  }

  /// Returns one document, reusing an already loaded collection when possible.
  Future<DocumentSnapshot<Map<String, dynamic>>?> doc(
    String collection,
    String id, {
    Duration? ttl,
    bool forceRefresh = false,
  }) async {
    await _bindUser();
    final maxAge = ttl ?? _ttlFor(collection);
    if (!forceRefresh) {
      final entry = _entries[collection];
      final fromList = entry?.docs[id];
      if (fromList != null && entry!.isFresh(maxAge)) return fromList;
      final cached = _docs['$collection/$id'];
      if (cached != null && DateTime.now().difference(cached.at) < maxAge) {
        return cached.snapshot;
      }
    }
    final ref = _firestore.collection(collection).doc(id);
    try {
      final snapshot = await ref.get();
      _docs['$collection/$id'] = _DocEntry(snapshot, DateTime.now());
      return snapshot;
    } on FirebaseException catch (error) {
      final stale = _docs['$collection/$id']?.snapshot;
      if (stale != null) return stale;
      try {
        return await ref.get(const GetOptions(source: Source.cache));
      } on FirebaseException {
        throw error;
      }
    }
  }

  /// Marks [collection] (and its scoped queries) stale after a write. The next
  /// read refreshes it; with `delta: true` that only fetches changed docs.
  void invalidate(String collection) {
    for (final entry in _entries.entries) {
      if (entry.key == collection || entry.key.startsWith('$collection|')) {
        entry.value.checkedAt = null;
      }
    }
    _docs.removeWhere((key, _) => key.startsWith('$collection/'));
  }

  void invalidateAll() {
    for (final entry in _entries.values) {
      entry.checkedAt = null;
    }
    _docs.clear();
  }

  /// Drops everything (call on sign-out if you like; a user change is also
  /// detected automatically).
  Future<void> clear() async {
    _entries.clear();
    _docs.clear();
    _syncStates.clear();
    _warmedAt.clear();
    await _persistState();
  }

  /// Pre-loads what the signed-in user's forms need, at most once per
  /// [_warmInterval]. Streams used by list screens are intentionally not
  /// pre-read: they fetch their own data, so reading it here too only doubled
  /// the cost.
  Future<void> warmForUser({
    required String uid,
    required Set<String> roles,
  }) async {
    await _bindUser();
    final last = _warmedAt[uid];
    if (last != null && DateTime.now().difference(last) < _warmInterval) {
      return;
    }
    _warmedAt[uid] = DateTime.now();

    final user = await _guard('users/$uid', () => doc('users', uid));
    final busId = user?.data()?['busId']?.toString();

    if (roles.contains('admin')) {
      await Future.wait([
        for (final name in const ['schools', 'buses', 'routes', 'parents'])
          _guard(name, () => collection(name)),
        _guard('cards', () => collection('cards', delta: true)),
      ]);
    } else if (roles.contains('driver') && busId != null && busId.isNotEmpty) {
      await _guard('buses/$busId', () => doc('buses', busId));
    }
  }

  // --------------------------------------------------------------- internals

  Duration _ttlFor(String collection) =>
      _ttlOverrides[collection] ?? defaultTtl;

  Future<void> _refresh(
    String name,
    _Entry entry,
    CachedQueryBuilder? scope,
    bool delta,
  ) async {
    final ref = _firestore.collection(name);
    try {
      if (scope != null) {
        entry.replace((await scope(ref).get()).docs);
      } else if (delta) {
        await _syncWithDelta(name, ref, entry);
      } else {
        entry.replace((await ref.get()).docs);
      }
      entry.checkedAt = DateTime.now();
    } on FirebaseException catch (error, stackTrace) {
      developer.log(
        'Unable to refresh $name cache',
        name: 'rideguard.cache',
        error: error,
        stackTrace: stackTrace,
      );
      if (entry.loaded) return; // keep serving the stale copy
      try {
        final Query<Map<String, dynamic>> query = scope?.call(ref) ?? ref;
        entry.replace(
            (await query.get(const GetOptions(source: Source.cache))).docs);
      } on FirebaseException {
        throw error;
      }
    }
  }

  Future<void> _syncWithDelta(
    String name,
    CollectionReference<Map<String, dynamic>> ref,
    _Entry entry,
  ) async {
    final now = DateTime.now();
    final state = _syncStates[name];
    final lastFull = state?.lastFullSync;
    final since = state?.maxUpdated;
    if (state != null &&
        lastFull != null &&
        since != null &&
        now.difference(lastFull) < fullSyncInterval) {
      if (!entry.loaded) {
        // Cold start: seed from Firestore's on-device cache (no billed reads).
        try {
          final cached = await ref.get(const GetOptions(source: Source.cache));
          if (cached.docs.isNotEmpty) entry.replace(cached.docs);
        } on FirebaseException {
          // fall through to a full sync
        }
      }
      if (entry.loaded) {
        final changed =
            await ref.where('updatedAt', isGreaterThan: since).get();
        entry.merge(changed.docs);
        final newest = _newestUpdate(changed.docs);
        if (newest != null && newest.compareTo(since) > 0) {
          state.maxUpdated = newest;
          await _persistState();
        }
        return;
      }
    }
    final full = await ref.get();
    entry.replace(full.docs);
    _syncStates[name] = _SyncState(
      lastFullSync: now,
      maxUpdated: _newestUpdate(full.docs),
    );
    await _persistState();
  }

  Timestamp? _newestUpdate(Iterable<CachedDoc> docs) {
    Timestamp? newest;
    for (final doc in docs) {
      final value = doc.data()['updatedAt'];
      if (value is Timestamp &&
          (newest == null || value.compareTo(newest) > 0)) {
        newest = value;
      }
    }
    return newest;
  }

  Future<T?> _guard<T>(String label, Future<T> Function() load) async {
    try {
      return await load();
    } on FirebaseException catch (error, stackTrace) {
      developer.log(
        'Unable to warm $label cache',
        name: 'rideguard.cache',
        error: error,
        stackTrace: stackTrace,
      );
    }
    return null;
  }

  // Per-user isolation + persisted delta-sync bookkeeping.

  Future<void> _bindUser() async {
    await (_stateLoad ??= _loadState());
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == _activeUid) return;
    _entries.clear();
    _docs.clear();
    _syncStates.clear();
    _warmedAt.clear();
    _activeUid = uid;
    await _persistState();
  }

  Future<File?> _stateFile() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      return File('${directory.path}/rideguard_cache_state.json');
    } catch (_) {
      return null;
    }
  }

  Future<void> _loadState() async {
    try {
      final file = await _stateFile();
      if (file == null || !await file.exists()) return;
      final json = jsonDecode(await file.readAsString());
      if (json is! Map) return;
      _activeUid = json['uid']?.toString();
      final collections = json['collections'];
      if (collections is Map) {
        for (final entry in collections.entries) {
          final value = entry.value;
          if (value is Map) {
            _syncStates[entry.key.toString()] = _SyncState.fromJson(value);
          }
        }
      }
    } catch (error) {
      developer.log('Unable to read cache state',
          name: 'rideguard.cache', error: error);
    }
  }

  Future<void> _persistState() async {
    try {
      final file = await _stateFile();
      if (file == null) return;
      await file.writeAsString(jsonEncode({
        'uid': _activeUid,
        'collections': {
          for (final entry in _syncStates.entries)
            entry.key: entry.value.toJson(),
        },
      }));
    } catch (error) {
      developer.log('Unable to save cache state',
          name: 'rideguard.cache', error: error);
    }
  }
}

class _Entry {
  final Map<String, CachedDoc> docs = {};
  DateTime? checkedAt;
  Future<void>? inFlight;
  bool loaded = false;

  bool isFresh(Duration ttl) =>
      loaded &&
      checkedAt != null &&
      DateTime.now().difference(checkedAt!) < ttl;

  void replace(Iterable<CachedDoc> items) {
    docs.clear();
    merge(items);
    loaded = true;
  }

  void merge(Iterable<CachedDoc> items) {
    for (final item in items) {
      docs[item.id] = item;
    }
  }
}

class _DocEntry {
  _DocEntry(this.snapshot, this.at);
  final DocumentSnapshot<Map<String, dynamic>> snapshot;
  final DateTime at;
}

class _SyncState {
  _SyncState({this.lastFullSync, this.maxUpdated});

  factory _SyncState.fromJson(Map<dynamic, dynamic> json) {
    final full = json['fullSync'];
    final updated = json['maxUpdated'];
    return _SyncState(
      lastFullSync:
          full is int ? DateTime.fromMillisecondsSinceEpoch(full) : null,
      maxUpdated:
          updated is int ? Timestamp.fromMicrosecondsSinceEpoch(updated) : null,
    );
  }

  DateTime? lastFullSync;
  Timestamp? maxUpdated;

  Map<String, dynamic> toJson() => {
        'fullSync': lastFullSync?.millisecondsSinceEpoch,
        'maxUpdated': maxUpdated?.microsecondsSinceEpoch,
      };
}
