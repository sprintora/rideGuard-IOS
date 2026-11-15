import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sqflite/sqflite.dart';

import 'permission_service.dart';

const locationSampleInterval = Duration(seconds: 30);

/// Decides whether a GPS fix is good enough to be saved.
///
/// [minInterval] defaults to the 30 second sample interval. The tracking
/// service passes a slightly shorter value for its 30 second timer so that
/// normal timing jitter never makes it skip a whole cycle.
bool acceptsLocationSample({
  required double accuracy,
  required double speed,
  required double previousLatitude,
  required double previousLongitude,
  required DateTime previousTimestamp,
  required double latitude,
  required double longitude,
  required DateTime timestamp,
  Duration minInterval = locationSampleInterval,
}) {
  if (!accuracy.isFinite || accuracy > 80) return false;
  final elapsed = timestamp.difference(previousTimestamp);
  if (elapsed < minInterval) return false;
  final seconds = elapsed.inMilliseconds / Duration.millisecondsPerSecond;
  final distance = Geolocator.distanceBetween(
    previousLatitude,
    previousLongitude,
    latitude,
    longitude,
  );
  return distance / seconds <= 55;
}

class _CachedIds {
  _CachedIds(this.ids) : at = DateTime.now();
  final List<String> ids;
  final DateTime at;
}

/// Saves the phone's GPS position every 30 seconds during an active trip.
///
/// Durability rules:
///  * every accepted point is written to a local SQLite queue FIRST;
///  * points are uploaded in batches to trips/{tripId}/locations;
///  * a point is deleted from the phone ONLY after Firestore confirms the
///    batch, so offline time, a killed app or a failed write never loses data;
///  * document ids are deterministic ("tripId-timestamp"), so retries can
///    never create duplicates;
///  * the queue table is created with CREATE TABLE IF NOT EXISTS every time
///    the database opens, so "no such table: location_queue" cannot happen.
class LocationTrackingService {
  LocationTrackingService(this._firestore);

  static final Set<LocationTrackingService> _active = {};

  static Future<void> stopAll() async {
    for (final service in List<LocationTrackingService>.of(_active)) {
      await service.stop();
    }
  }

  // ------------------------------------------------------- local queue

  static const String _table = 'location_queue';
  static const int _batchSize = 50;
  static const int _maxAttempts = 20;
  static Future<Database>? _dbFuture;

  // A new database file, so a missing table in an older file can never
  // affect this service.
  static Future<Database> _database() {
    final existing = _dbFuture;
    if (existing != null) return existing;
    final opening = _openDatabase();
    _dbFuture = opening;
    opening.catchError((Object error) {
      _dbFuture = null; // allow a clean retry after a failed open
      throw error;
    });
    return opening;
  }

  static Future<Database> _openDatabase() async {
    final dir = await getDatabasesPath();
    return openDatabase(
      '$dir/rideguard_location_queue.db',
      version: 1,
      onOpen: (db) async {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS $_table (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            key TEXT NOT NULL UNIQUE,
            trip_id TEXT NOT NULL,
            payload TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            attempts INTEGER NOT NULL DEFAULT 0
          )
        ''');
        await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_${_table}_trip ON $_table(trip_id)');
      },
    );
  }

  // ------------------------------------------------------------ state

  final FirebaseFirestore _firestore;
  StreamSubscription<Position>? _subscription;
  LocationSettings? _settings;
  String? _busId;
  String? _tripId;
  Position? _latestFix; // newest acceptable fix (also used for card taps)
  Position? _lastSaved; // last fix written to the queue
  Timer? _tickTimer;
  Timer? _recoveryTimer;
  Timer? _drainTimer;
  bool _starting = false;
  bool _ticking = false;
  bool _flushing = false;
  final Map<String, _CachedIds> _parentIds = {};

  /// Human-readable GPS state, shown on the driver screen so problems are
  /// visible without a debugger.
  final ValueNotifier<String> status = ValueNotifier<String>('GPS not started');

  /// Points confirmed by Firestore during the current trip.
  final ValueNotifier<int> uploaded = ValueNotifier<int>(0);

  /// Points still waiting on the phone to be uploaded.
  final ValueNotifier<int> pending = ValueNotifier<int>(0);

  void _setStatus(String message) {
    debugPrint('[gps] $message');
    status.value = message;
  }

  String _clock() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
  }

  Future<void> _refreshPending() async {
    try {
      final db = await _database();
      pending.value = Sqflite.firstIntValue(
              await db.rawQuery('SELECT COUNT(*) AS count FROM $_table')) ??
          0;
    } catch (_) {}
  }

  Future<void> _reportGpsReadiness() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        _setStatus('Location is turned OFF on this phone. Turn it on.');
        return;
      }
      final permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        _setStatus('Location permission is denied. Allow it in app settings.');
        return;
      }
      _setStatus('Waiting for the first GPS fix...');
    } catch (error) {
      developer.log('GPS readiness check failed: $error',
          name: 'rideguard.location');
    }
  }

  bool get isTracking => _tripId != null || _starting;
  Position? get latestPosition => _latestFix;

  Future<int> pendingCountForTrip(String tripId) async {
    try {
      final db = await _database();
      return Sqflite.firstIntValue(await db.rawQuery(
              'SELECT COUNT(*) AS count FROM $_table WHERE trip_id = ?',
              [tripId])) ??
          0;
    } catch (error) {
      developer.log('Pending count failed: $error', name: 'rideguard.location');
      return 0;
    }
  }

  // ------------------------------------------------------------ start

  Future<void> start({required String tripId}) async {
    if (_starting || _tripId == tripId) return; // already running this trip
    _starting = true;
    try {
      _setStatus('Starting GPS...');
      if (_tripId != null) await stop(); // a different trip was running
      final permissions = RideGuardPermissionService();
      try {
        await permissions
            .requestBackgroundLocation()
            .timeout(const Duration(seconds: 30));
      } catch (error) {
        developer.log('Background location request failed: $error',
            name: 'rideguard.location');
      }
      final userId = FirebaseAuth.instance.currentUser?.uid;
      if (userId == null) {
        throw StateError('Sign-in is required for GPS tracking.');
      }
      final user = await _firestore.collection('users').doc(userId).get();
      final busId = user.data()?['busId']?.toString();
      if (busId == null || busId.isEmpty) {
        throw StateError('No bus is assigned to this driver.');
      }
      _busId = busId;
      _tripId = tripId;
      _latestFix = null;
      _lastSaved = null;
      _active.add(this);
      uploaded.value = 0;
      _drainTimer?.cancel();
      _drainTimer = null;

      // Give points that failed earlier a fresh set of retries.
      try {
        final db = await _database();
        await db.update(_table, {'attempts': 0});
      } catch (error) {
        developer.log('Queue reset failed: $error', name: 'rideguard.location');
      }

      await _subscription?.cancel();
      if (Platform.isAndroid) {
        _settings = AndroidSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 10,
          foregroundNotificationConfig: const ForegroundNotificationConfig(
            notificationTitle: 'RideGuard active trip',
            notificationText: 'RideGuard is tracking the bus location.',
            enableWakeLock: true,
            enableWifiLock: true,
          ),
        );
      } else if (Platform.isIOS) {
        // Keeps GPS (and therefore the app) alive with the screen locked.
        // Needs UIBackgroundModes=location and "Always" permission.
        _settings = AppleSettings(
          accuracy: LocationAccuracy.high,
          activityType: ActivityType.automotiveNavigation,
          distanceFilter: 10,
          pauseLocationUpdatesAutomatically: false,
          showBackgroundLocationIndicator: true,
          allowBackgroundLocationUpdates: true,
        );
      } else {
        _settings = const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 10,
        );
      }
      _listenForPositions();
      await _reportGpsReadiness();

      _tickTimer?.cancel();
      _tickTimer =
          Timer.periodic(locationSampleInterval, (_) => unawaited(_tick()));
      unawaited(_tick()); // first point immediately
    } finally {
      _starting = false;
    }
  }

  void _listenForPositions() {
    final settings = _settings;
    if (settings == null) return;
    _subscription = Geolocator.getPositionStream(locationSettings: settings)
        .listen(_onPosition, onError: (Object error, StackTrace stack) {
      developer.log('Location stream failed',
          name: 'rideguard.location', error: error, stackTrace: stack);
      _subscription = null;
      _recoveryTimer?.cancel();
      _recoveryTimer = Timer(const Duration(seconds: 5), () {
        if (_tripId != null && _subscription == null) _listenForPositions();
      });
    });
  }

  void _onPosition(Position position) {
    if (position.accuracy.isNaN || position.accuracy > 80) {
      final acc = position.accuracy.isNaN
          ? 'unknown'
          : '${position.accuracy.round()} m';
      _setStatus('GPS accuracy too low ($acc, needs 80 m or better).');
      return;
    }
    _latestFix = position; // always keep the newest good fix
    if (_lastSaved == null && _tripId != null) unawaited(_tick());
  }

  // ----------------------------------------------------- 30 s sampling

  Future<void> _tick() async {
    final tripId = _tripId;
    if (tripId == null || _ticking) return;
    _ticking = true;
    try {
      final fix = await _freshFix();
      if (fix != null) await _saveSample(tripId, fix);
      await _flush();
    } catch (error, stackTrace) {
      developer.log('Location tick failed',
          name: 'rideguard.location', error: error, stackTrace: stackTrace);
    } finally {
      _ticking = false;
    }
  }

  /// The stream only reports movement (distanceFilter), so a parked bus would
  /// stop producing fixes. If the newest fix is old, ask for a fresh one so a
  /// stationary bus still gets a point every 30 seconds.
  Future<Position?> _freshFix() async {
    final cached = _latestFix;
    if (cached != null &&
        DateTime.now().difference(cached.timestamp) <=
            const Duration(seconds: 40)) {
      return cached;
    }
    try {
      final fresh = await Geolocator.getCurrentPosition()
          .timeout(const Duration(seconds: 15));
      if (fresh.accuracy.isNaN || fresh.accuracy > 80) {
        _setStatus('GPS accuracy too low, needs 80 m or better.');
        return null;
      }
      _latestFix = fresh;
      return fresh;
    } catch (error) {
      developer.log('No fresh GPS fix: $error', name: 'rideguard.location');
      _setStatus('No GPS fix yet. On an emulator, set a location in '
          'Extended controls > Location.');
      return null; // never save a stale position as if it were current
    }
  }

  Future<void> _saveSample(String tripId, Position position) async {
    final previous = _lastSaved;
    if (previous != null &&
        !acceptsLocationSample(
          accuracy: position.accuracy,
          speed: position.speed,
          previousLatitude: previous.latitude,
          previousLongitude: previous.longitude,
          previousTimestamp: previous.timestamp,
          latitude: position.latitude,
          longitude: position.longitude,
          timestamp: position.timestamp,
          minInterval: const Duration(seconds: 20),
        )) {
      return;
    }
    final busId = _busId;
    if (busId == null || busId.isEmpty) return;
    final speed = position.speed.isFinite ? position.speed : 0.0;
    final payload = <String, dynamic>{
      'busId': busId,
      'tripId': tripId,
      'driverId': FirebaseAuth.instance.currentUser?.uid,
      'lat': position.latitude,
      'lng': position.longitude,
      'accuracy': position.accuracy,
      'speed': speed,
      'moving': speed >= 1.0,
    };
    final db = await _database();
    await db.insert(
      _table,
      {
        'key': '$tripId-${position.timestamp.millisecondsSinceEpoch}',
        'trip_id': tripId,
        'payload': jsonEncode(payload),
        'created_at': DateTime.now().millisecondsSinceEpoch,
        'attempts': 0,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    _lastSaved = position;
    _setStatus('Saved point at ${_clock()}');
    unawaited(_refreshPending());
  }

  // ----------------------------------------------------------- upload

  /// Uploads queued points now. Safe to call at any time.
  Future<void> flush() => _flush();

  Future<void> _flush() async {
    if (_flushing) return;
    _flushing = true;
    var allConfirmed = false;
    var fullBatch = false;
    try {
      final db = await _database();
      final rows = await db.query(
        _table,
        where: 'attempts < ?',
        whereArgs: [_maxAttempts],
        orderBy: 'attempts ASC, created_at ASC',
        limit: _batchSize,
      );
      if (rows.isEmpty) return;
      fullBatch = rows.length >= _batchSize;
      final byTrip = <String, List<Map<String, Object?>>>{};
      for (final row in rows) {
        byTrip.putIfAbsent(row['trip_id'] as String, () => []).add(row);
      }
      allConfirmed = true;
      for (final entry in byTrip.entries) {
        if (!await _commitGroup(db, entry.key, entry.value)) {
          allConfirmed = false;
        }
      }
    } catch (error, stackTrace) {
      developer.log('Location queue flush failed',
          name: 'rideguard.location', error: error, stackTrace: stackTrace);
    } finally {
      _flushing = false;
    }
    if (allConfirmed && fullBatch) unawaited(_flush()); // more waiting
  }

  /// Parent ids can change while a trip runs (students boarding), so they are
  /// re-read from the trip roughly once per upload, not once per point.
  Future<List<String>?> _parentIdsFor(String tripId) async {
    final cached = _parentIds[tripId];
    if (cached != null &&
        DateTime.now().difference(cached.at) < const Duration(seconds: 20)) {
      return cached.ids;
    }
    try {
      final trip = await _firestore
          .collection('trips')
          .doc(tripId)
          .get()
          .timeout(const Duration(seconds: 10));
      if (!trip.exists) return cached?.ids;
      final raw = trip.data()?['parentIds'];
      final ids = <String>{
        if (raw is List) ...raw.whereType<String>(),
      }.where((id) => id.isNotEmpty).toList();
      _parentIds[tripId] = _CachedIds(ids);
      return ids;
    } catch (error) {
      developer.log('Trip parent ids unavailable: $error',
          name: 'rideguard.location');
      return cached?.ids; // may be null: then try again next cycle
    }
  }

  Future<bool> _commitGroup(
      Database db, String tripId, List<Map<String, Object?>> rows) async {
    final parentIds = await _parentIdsFor(tripId);
    if (parentIds == null) {
      _setStatus('Cannot read the trip yet; points are kept and will retry.');
      return false; // offline: keep points, retry later
    }

    final keys = [for (final row in rows) row['key'] as String];
    final marks = List.filled(keys.length, '?').join(',');
    try {
      final batch = _firestore.batch();
      Map<String, dynamic>? newest;
      for (final row in rows) {
        final payload =
            Map<String, dynamic>.from(jsonDecode(row['payload'] as String));
        final firestorePayload = <String, dynamic>{
          ...payload,
          'parentIds': parentIds,
          'updatedAt': FieldValue.serverTimestamp(),
        };
        batch.set(
          _firestore
              .collection('trips')
              .doc(tripId)
              .collection('locations')
              .doc(row['key'] as String),
          firestorePayload,
        );
        newest = firestorePayload; // rows are in capture order
      }
      // Completes only once the server accepted the whole batch.
      await batch.commit().timeout(const Duration(seconds: 20));

      // Confirmed by the server: now it is safe to delete from the phone.
      await db.delete(_table, where: 'key IN ($marks)', whereArgs: keys);
      uploaded.value += rows.length;
      _setStatus('Uploaded ${rows.length} point(s) at ${_clock()}');
      unawaited(_refreshPending());

      if (newest != null && tripId == _tripId) {
        unawaited(_publishLive(newest));
      }
      return true;
    } on TimeoutException {
      developer.log('Location batch timed out; will retry',
          name: 'rideguard.location');
      _setStatus(
          'Waiting for network; ${rows.length} point(s) kept on the phone.');
      return false; // offline is not a failure: do not count an attempt
    } on FirebaseException catch (error, stackTrace) {
      developer.log('Location batch rejected: ${error.code}',
          name: 'rideguard.location', error: error, stackTrace: stackTrace);
      _setStatus('Upload rejected: ${error.code}');
      if (error.code != 'unavailable' && error.code != 'deadline-exceeded') {
        await _markFailed(db, marks, keys);
      }
      return false;
    } catch (error, stackTrace) {
      developer.log('Location batch failed',
          name: 'rideguard.location', error: error, stackTrace: stackTrace);
      _setStatus('Upload failed; points are kept and will retry.');
      await _markFailed(db, marks, keys);
      return false;
    }
  }

  Future<void> _markFailed(Database db, String marks, List<String> keys) async {
    try {
      await db.rawUpdate(
          'UPDATE $_table SET attempts = attempts + 1 WHERE key IN ($marks)',
          keys);
    } catch (_) {}
  }

  /// Updates the single live document used by the maps. If this fails the
  /// saved trip points are not affected.
  Future<void> _publishLive(Map<String, dynamic> data) async {
    final busId = _busId;
    if (busId == null || busId.isEmpty) return;
    try {
      await _firestore
          .collection('liveLocations')
          .doc(busId)
          .set(data, SetOptions(merge: true))
          .timeout(const Duration(seconds: 10));
    } catch (error) {
      developer.log('Live location update failed: $error',
          name: 'rideguard.location');
    }
  }

  // ------------------------------------------------------------- stop

  Future<void> stop() async {
    final tripId = _tripId;
    _tickTimer?.cancel();
    _tickTimer = null;
    _recoveryTimer?.cancel();
    _recoveryTimer = null;
    await _subscription?.cancel();
    _subscription = null;

    if (tripId != null) {
      // Save one last point so the end of the trip is recorded.
      final last = _latestFix;
      if (last != null &&
          DateTime.now().difference(last.timestamp) <=
              const Duration(seconds: 60)) {
        try {
          await _saveSample(tripId, last);
        } catch (_) {}
      }
      try {
        await _flush().timeout(const Duration(seconds: 8));
      } catch (_) {}
    }

    _tripId = null;
    _latestFix = null;
    _lastSaved = null;
    _active.remove(this);
    _setStatus('GPS stopped');
    unawaited(_refreshPending());
    _scheduleDrain();
  }

  /// After a trip ends, keep retrying unsent points every 30 seconds until
  /// the queue is empty, another trip starts, or the user signs out.
  void _scheduleDrain() {
    if (_drainTimer != null) return;
    _drainTimer = Timer.periodic(locationSampleInterval, (timer) async {
      if (_tripId != null || FirebaseAuth.instance.currentUser == null) {
        timer.cancel();
        _drainTimer = null;
        return;
      }
      await _flush();
      if (await _retryablePending() == 0) {
        timer.cancel();
        _drainTimer = null;
      }
    });
  }

  Future<int> _retryablePending() async {
    try {
      final db = await _database();
      return Sqflite.firstIntValue(await db.rawQuery(
              'SELECT COUNT(*) AS count FROM $_table WHERE attempts < ?',
              [_maxAttempts])) ??
          0;
    } catch (_) {
      return 0;
    }
  }
}
