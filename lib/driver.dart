import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sqflite/sqflite.dart' as sql;
import 'dart:developer' as developer;

import 'app_models.dart';
import 'forms.dart';
import 'permission_service.dart';
import 'ride_reader_service.dart';
import 'ride_reader_queue.dart';
import 'location_tracking_service.dart';
import 'widgets.dart';
import 'auth_repository.dart';
import 'foreground_trip_service.dart';

class DriverList extends StatefulWidget {
  const DriverList({super.key});
  @override
  State<DriverList> createState() => _DriverListState();
}

class _RideReaderRow extends StatelessWidget {
  const _RideReaderRow({
    required this.result,
    required this.onConnect,
  });

  final ScanResult result;
  final Future<void> Function() onConnect;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const Icon(Icons.bluetooth),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(rideReaderDisplayName(result),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      softWrap: false),
                  Text('Signal: ${result.rssi} dBm',
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // The app theme gives buttons an infinite minimum width, which
            // breaks layout inside a Row. A fixed size avoids that.
            SizedBox(
              height: 40,
              child: FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size(96, 40)),
                onPressed: onConnect,
                child: const Text('Connect'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DriverListState extends State<DriverList> {
  bool _showAll = false;
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.person_add),
        label: const Text('Add student'),
        onPressed: () async {
          await Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => const AddStudentForm(driverMode: true)));
          if (mounted) setState(() {});
        },
      ),
      body: ListView.separated(
        padding: const EdgeInsets.fromLTRB(8, 12, 8, 96),
        itemCount: 1,
        separatorBuilder: (_, __) => const SizedBox.shrink(),
        itemBuilder: (ctx, _) =>
            FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          future: FirebaseFirestore.instance
              .collection('users')
              .doc(FirebaseAuth.instance.currentUser?.uid)
              .get(),
          builder: (ctx, userSnapshot) {
            final busId = userSnapshot.data?.data()?['busId']?.toString();
            if (busId == null || busId.isEmpty) {
              return const Text('No bus is assigned to this driver.');
            }
            return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: FirebaseFirestore.instance
                  .collection('students')
                  .where('busId', isEqualTo: busId)
                  .orderBy('name')
                  .snapshots(),
              builder: (ctx, snapshot) {
                if (snapshot.hasError)
                  return const Text('Unable to load students. Please retry.');
                if (!snapshot.hasData)
                  return const Center(child: CircularProgressIndicator());
                final students = snapshot.data!.docs;
                return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Students on bus',
                                  style: Theme.of(ctx).textTheme.headlineSmall),
                              Row(
                                children: [
                                  const Expanded(
                                    child: Text(
                                        'Read-only. Drivers can add new students but never edit or delete.'),
                                  ),
                                  TextButton.icon(
                                    style: TextButton.styleFrom(
                                        minimumSize: const Size(0, 40)),
                                    onPressed: () =>
                                        setState(() => _showAll = !_showAll),
                                    icon: const Icon(Icons.sort),
                                    label: Text(_showAll
                                        ? 'Show boarded first'
                                        : 'Show all'),
                                  ),
                                ],
                              ),
                            ]),
                      ),
                      for (final doc in (students.toList()
                        ..sort((a, b) {
                          if (_showAll) {
                            return (a.data()['fullName']?.toString() ??
                                    a.data()['name']?.toString() ??
                                    '')
                                .compareTo(b.data()['fullName']?.toString() ??
                                    b.data()['name']?.toString() ??
                                    '');
                          }
                          final aBoarded =
                              Trip.I.onBoard.contains(a.id) ? 0 : 1;
                          final bBoarded =
                              Trip.I.onBoard.contains(b.id) ? 0 : 1;
                          return aBoarded.compareTo(bBoarded);
                        })))
                        ListTile(
                          leading:
                              const CircleAvatar(child: Icon(Icons.person)),
                          title: Text(doc.data()['fullName']?.toString() ??
                              doc.data()['name']?.toString() ??
                              doc.id),
                          subtitle: Text(
                              '${doc.data()['admissionNumber'] ?? ''}  •  ${doc.data()['grade'] ?? ''}  •  ${doc.data()['pickupStop'] ?? ''}'),
                          trailing:
                              (doc.data()['cardId']?.toString().isEmpty ?? true)
                                  ? Chip2('NO CARD', Colors.orange.shade800)
                                  : null,
                        ),
                    ]);
              },
            );
          },
        ),
      ),
    );
  }
}

class DriverHome extends StatefulWidget {
  const DriverHome({super.key});
  @override
  State<DriverHome> createState() => _DriverHomeState();
}

class _DriverHomeState extends State<DriverHome> {
  final trip = Trip.I;
  final reader = RideReaderService.shared;
  final queue = RideReaderQueue();
  final location = LocationTrackingService(FirebaseFirestore.instance);
  final _boardingStore = BoardingStore.instance;
  // A card that taps again after being on board for longer than this is
  // recorded as ALIGHTING automatically (the driver is warned).
  static const _autoAlightAfter = Duration(minutes: 1);
  String? _prunedTripId;
  List<Map<String, dynamic>> _students = const [];
  Set<String> _tripStudentIds = const {};
  Set<String> _alightedStudentIds = const {};
  String? _tripId;
  String? _busId;
  String? _busLabel;
  String? _moduleLabel;
  String? _assignmentError;
  List<LatLng> _routePoints = const [];
  List<Map<String, dynamic>> _routes = const [];
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _tripSubscription;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _eventSubscription;
  StreamSubscription<RideReaderTap>? _readerSubscription;
  StreamSubscription<RideReaderConnectionState>? _readerStateSubscription;
  Timer? _uploadTimer;
  String? _readerDeviceId;
  int _pendingCount = 0;
  int _rejectedNoTripCount = 0;
  final Map<int, int> _pendingFeedback = {};
  RideReaderFailure? _readerFailure;
  bool _pairingHintShown = false;
  bool _tripBusy = false;
  bool _endTripBusy = false;
  Stream<QuerySnapshot<Map<String, dynamic>>>? _studentsStream;
  String? _studentsStreamBusId;
  late final Future<void> Function() _sessionCleanup = _releaseSessionResources;

  void _r() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    SessionLifecycle.register(_sessionCleanup);
    trip.addListener(_r);
    _loadBusDetails();
    _refreshPendingCount();
    _refreshRejectedNoTripCount();
    _readerSubscription = reader.taps.listen(_handleReaderTap);
    _readerStateSubscription = reader.connectionStates.listen((state) {
      trip.connect(state == RideReaderConnectionState.connected);
      if (state == RideReaderConnectionState.connected) {
        _flushFeedback();
        _uploadPending();
      }
      if (mounted) setState(() {});
    });
    _uploadTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _uploadPending();
    });
  }

  Future<void> _loadBusDetails() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final user =
        await FirebaseFirestore.instance.collection('users').doc(uid).get();
    final userData = user.data() ?? const <String, dynamic>{};
    var busId = userData['busId']?.toString();
    final assignedRouteId = userData['routeId']?.toString();
    DocumentSnapshot<Map<String, dynamic>>? assignedRoute;
    if (assignedRouteId != null && assignedRouteId.isNotEmpty) {
      try {
        assignedRoute = await FirebaseFirestore.instance
            .collection('routes')
            .doc(assignedRouteId)
            .get();
      } on FirebaseException catch (error) {
        developer.log('Assigned route load failed: ${error.code}',
            name: 'rideguard.driver');
        _assignmentError = 'Unable to load the assigned route. Try again.';
      }
      if ((busId == null || busId.isEmpty) && assignedRoute?.exists == true) {
        final routeBusId = assignedRoute?.data()?['busId']?.toString();
        if (routeBusId != null && routeBusId.isNotEmpty) busId = routeBusId;
      }
    }
    if (!mounted) return;
    if (busId == null || busId.isEmpty) {
      setState(() {
        _busId = null;
        _busLabel = null;
        _routes = assignedRoute?.exists == true
            ? [
                {...assignedRoute!.data()!, 'id': assignedRoute.id}
              ]
            : const [];
      });
      return;
    }
    final bus =
        await FirebaseFirestore.instance.collection('buses').doc(busId).get();
    var readerDeviceId = bus.data()?['deviceId']?.toString();
    if (readerDeviceId == null || readerDeviceId.isEmpty) {
      final devices = await FirebaseFirestore.instance
          .collection('devices')
          .where('busId', isEqualTo: busId)
          .limit(1)
          .get();
      readerDeviceId = devices.docs.isEmpty
          ? null
          : devices.docs.first.data()['deviceId']?.toString();
    }
    final routeData = <Map<String, dynamic>>[];
    try {
      final routes = await FirebaseFirestore.instance
          .collection('routes')
          .where('busId', isEqualTo: busId)
          .get();
      routeData.addAll([
        for (final doc in routes.docs) {...doc.data(), 'id': doc.id},
      ]);
    } on FirebaseException catch (error) {
      developer.log('Route list load failed: ${error.code}',
          name: 'rideguard.driver');
      _assignmentError = 'Unable to load routes. Try again.';
    }
    if (assignedRouteId != null &&
        assignedRouteId.isNotEmpty &&
        !routeData.any((route) => route['id'] == assignedRouteId)) {
      if (assignedRoute?.exists == true) {
        routeData.add({...assignedRoute!.data()!, 'id': assignedRoute.id});
      }
    }
    final selectedRoute = routeData.where((route) {
      return route['id'] == assignedRouteId;
    }).firstOrNull;
    final geometry = (selectedRoute ??
        (routeData.isEmpty ? null : routeData.first))?['geometry'];
    final routePoints = _points(geometry);
    if (!mounted) return;
    setState(() {
      _busId = busId;
      _busLabel = bus.data()?['plate']?.toString().trim().isNotEmpty == true
          ? bus.data()!['plate'].toString().trim()
          : 'assigned bus';
      _readerDeviceId = readerDeviceId;
      trip.capacity = (bus.data()?['capacity'] as num?)?.toInt() ?? 0;
      _routePoints = routePoints;
      _routes = routeData;
    });
    if (selectedRoute != null) {
      trip.selectRoute(selectedRoute['id'].toString());
    }
    _watchActiveTrip();
  }

  List<LatLng> _points(dynamic geometry) => [
        if (geometry is List)
          for (final item in geometry)
            if (item is Map && item['lat'] is num && item['lng'] is num)
              LatLng((item['lat'] as num).toDouble(),
                  (item['lng'] as num).toDouble()),
      ];

  void _watchActiveTrip() {
    final busId = _busId;
    if (busId == null) return;
    _tripSubscription?.cancel();
    _tripSubscription = FirebaseFirestore.instance
        .collection('trips')
        .where('busId', isEqualTo: busId)
        .where('driverId', isEqualTo: FirebaseAuth.instance.currentUser?.uid)
        .where('status', isEqualTo: 'active')
        .limit(1)
        .snapshots()
        .listen((snapshot) {
      final document = snapshot.docs.isEmpty ? null : snapshot.docs.first;
      _eventSubscription?.cancel();
      if (document == null) {
        _tripId = null;
        _tripStudentIds = const {};
        _alightedStudentIds = const {};
        trip.clear();
        return;
      }
      final data = document.data();
      _tripId = document.id;
      trip.update(
        active: true,
        tripId: document.id,
        routeId: data['routeId']?.toString(),
        busId: busId,
        capacity: trip.capacity,
        onBoard: <String>{},
        tripNo: (data['tripNo'] as num?)?.toInt() ?? 0,
      );
      trip.manualMode = data['entryMode'] == 'manual';
      if (!location.isTracking) {
        unawaited(location.start(tripId: document.id));
      }
      _eventSubscription =
          document.reference.collection('events').snapshots().listen(
        (events) {
          final state = calculateOnBoardState(
            events.docs.map((event) => event.data()),
          );
          _tripStudentIds = state.allStudentIds;
          _alightedStudentIds = state.alightedIds;
          trip.update(
            active: true,
            tripId: document.id,
            routeId: data['routeId']?.toString(),
            busId: busId,
            capacity: trip.capacity,
            onBoard: state.studentIds,
            tripNo: (data['tripNo'] as num?)?.toInt() ?? 0,
          );
          _r();
        },
      );
    });
  }

  @override
  void dispose() {
    trip.removeListener(_r);
    SessionLifecycle.unregister(_sessionCleanup);
    _tripSubscription?.cancel();
    _eventSubscription?.cancel();
    _readerSubscription?.cancel();
    _readerStateSubscription?.cancel();
    _uploadTimer?.cancel();
    queue.close();
    location.stop();
    super.dispose();
  }

  Future<void> _releaseSessionResources() async {
    await _tripSubscription?.cancel();
    await _eventSubscription?.cancel();
    await _readerSubscription?.cancel();
    await _readerStateSubscription?.cancel();
    _uploadTimer?.cancel();
    await reader.disconnect();
    if (Platform.isAndroid) await stopForegroundTripService();
    await location.stop();
    await queue.close();
  }

  Future<void> _handleReaderTap(RideReaderTap tap) async {
    // Take the exact tap time and mode first: getting a GPS fix can take a
    // moment and must not change when or how this tap is recorded.
    final tappedAt = DateTime.now().millisecondsSinceEpoch;
    var tapMode = trip.boarding ? 'boarding' : 'alighting';
    final userId = FirebaseAuth.instance.currentUser?.uid;
    if (userId == null || _busId == null) {
      if (mounted)
        snack(context, 'Sign in and use an assigned bus.', warn: true);
      return;
    }
    final tripId = _tripId;
    final deviceId = reader.info?.deviceId ?? _readerDeviceId;
    if (deviceId == null || deviceId.isEmpty) {
      if (mounted)
        snack(context, 'Ride Reader identity is unavailable.', warn: true);
      return;
    }
    final eventId = RideReaderQueue.idempotencyKey(
      deviceId: deviceId,
      sequence: tap.sequence,
      tripId: tripId,
    );

    // Automatic alighting: this card is already on board (saved on the
    // phone) and boarded more than a minute ago -> it is getting off. The
    // BOARDING / ALIGHTING buttons still decide every other tap.
    int? autoAlightMinutes;
    if (tripId != null) {
      try {
        if (_prunedTripId != tripId) {
          _prunedTripId = tripId;
          await _boardingStore.pruneExcept(tripId);
        }
        final boardedAt = await _boardingStore.boardedAt(tripId, tap.cardCode);
        if (boardedAt != null &&
            tappedAt - boardedAt > _autoAlightAfter.inMilliseconds) {
          tapMode = 'alighting';
          autoAlightMinutes =
              ((tappedAt - boardedAt) / Duration.millisecondsPerMinute).floor();
        }
      } catch (error) {
        // Never block a tap because the local record is unavailable.
        developer.log('Boarding record unavailable: $error',
            name: 'rideguard.driver');
      }
    }

    final gps = await _captureTapLocation();
    final payload = <String, dynamic>{
      'eventId': eventId,
      'idempotencyKey': eventId,
      'busId': _busId,
      'cardUid': tap.cardCode,
      'mode': tapMode,
      'tappedAt': tappedAt,
      'driverId': userId,
      'deviceId': deviceId,
      'readerSequence': tap.sequence,
      'readerMillis': tap.uptimeMs,
      ...gps,
    };
    final inserted = await queue.enqueue(
      key: eventId,
      tripId: tripId,
      payload: payload,
    );
    if (tripId == null) {
      await queue.markDone(eventId, 'rejected_no_active_trip');
      await reader.acknowledge(tap.sequence);
      await _sendFeedback(tap.sequence, 1);
      if (mounted) {
        snack(context, 'Start the trip first, this student was not recorded',
            warn: true);
      }

      await _refreshRejectedNoTripCount();
      return;
    }
    if (inserted) {
      try {
        if (tapMode == 'boarding') {
          await _boardingStore.markBoarded(tripId, tap.cardCode, tappedAt);
        } else {
          await _boardingStore.remove(tripId, tap.cardCode);
        }
      } catch (error) {
        developer.log('Boarding record not saved: $error',
            name: 'rideguard.driver');
      }
    }
    if (autoAlightMinutes != null && mounted) {
      HapticFeedback.heavyImpact();
      snack(
          context,
          'This student boarded ${autoAlightMinutes == 0 ? 'under a minute' : '$autoAlightMinutes min'} ago '
          'and is still on board, so this tap was recorded as ALIGHTING.',
          warn: true);
    }
    if (gps.isEmpty && mounted) {
      snack(context,
          'No GPS location: this tap was saved without a location point.',
          warn: true);
    }
    if (inserted || await queue.contains(eventId)) {
      await reader.acknowledge(tap.sequence);
    }
    if (inserted) await _uploadPending();
  }

  Map<String, dynamic> _gpsFieldsFor(Position position) {
    double finite(double value) => value.isFinite ? value : 0;
    return {
      'lat': position.latitude,
      'lng': position.longitude,
      'gpsAccuracy': finite(position.accuracy),
      'gpsSpeed': finite(position.speed),
      'gpsFixAt': position.timestamp.millisecondsSinceEpoch,
      'gpsFixAgeMs':
          DateTime.now().difference(position.timestamp).inMilliseconds,
    };
  }

  /// The location saved with a card tap or a manual entry: the child's
  /// pickup point (boarding) or drop point (alighting).
  ///
  /// The phone only reports a fix when the bus has moved 10 m, so a bus that
  /// is stopped at a stop may hold an old fix. If the newest fix is more than
  /// 10 seconds old, a fresh one is requested (max 4 seconds), and the newest
  /// known fix is the fallback. Returns an empty map only if no location is
  /// available at all.
  Future<Map<String, dynamic>> _captureTapLocation() async {
    var position = location.latestPosition;
    final age =
        position == null ? null : DateTime.now().difference(position.timestamp);
    if (position == null || age! > const Duration(seconds: 10)) {
      try {
        position = await Geolocator.getCurrentPosition()
            .timeout(const Duration(seconds: 4));
      } catch (error) {
        developer.log('Fresh tap location unavailable: $error',
            name: 'rideguard.driver');
      }
    }
    if (position == null) return const {};
    return _gpsFieldsFor(position);
  }

  Future<void> _uploadPending() async {
    final items = await queue.pending();
    final currentUserId = FirebaseAuth.instance.currentUser?.uid;
    for (final item in items) {
      final tripId = item.tripId;
      if (tripId == null) continue;
      if (item.payload['driverId']?.toString() != currentUserId) continue;
      try {
        final ref = FirebaseFirestore.instance
            .collection('trips')
            .doc(tripId)
            .collection('events')
            .doc(item.key);
        await ref.set(item.payload, SetOptions(merge: true));
        final result = await ref
            .snapshots()
            .firstWhere(
              (snapshot) => snapshot.data()?['serverStatus'] != null,
            )
            .timeout(const Duration(seconds: 20));
        final status = result.data()?['serverStatus']?.toString() ?? 'rejected';
        await queue.markDone(item.key, status);
        // A rejected boarding must not stay "on board" on the phone.
        if (item.payload['mode'] == 'boarding' &&
            status != 'processed' &&
            status != 'duplicate_tap') {
          try {
            await _boardingStore.remove(
                tripId, item.payload['cardUid']?.toString() ?? '');
          } catch (_) {}
        }
        _pendingFeedback[item.payload['readerSequence'] as int] =
            _feedbackCode(status);
        await _flushFeedback();
        if (mounted && result.data()?['studentName'] != null) {
          HapticFeedback.mediumImpact();
          snack(context,
              '${result.data()!['studentName']} ${item.payload['mode']}');
        }
      } on TimeoutException {
        await queue.markRetry(item.key);
        break;
      } on FirebaseException {
        await queue.markRetry(item.key);
        break;
      }
    }
    await _refreshPendingCount();
  }

  Future<void> _refreshPendingCount() async {
    final count = await queue.pendingCount();
    if (mounted && count != _pendingCount) {
      setState(() => _pendingCount = count);
    }
  }

  Future<void> _refreshRejectedNoTripCount() async {
    final count = await queue.resultCountToday('rejected_no_active_trip');
    if (mounted) setState(() => _rejectedNoTripCount = count);
  }

  int _feedbackCode(String status) => switch (status) {
        'processed' => 0,
        'unmatched_card' => 2,
        'duplicate_tap' || 'alight_without_board' => 3,
        _ => 1,
      };

  StateError _missingTripServiceError(String functionName) => StateError(
      'Trip service "$functionName" is not deployed for this Firebase project. '
      'Deploy the functions backend, then try again.');

  bool _isMissingCallable(FirebaseFunctionsException error) =>
      error.code == 'not-found' && error.message == 'NOT_FOUND';

  void _showTripActionError(Object error, StackTrace stackTrace, String code) {
    developer.log('Trip action failed',
        name: 'rideguard.trip', error: error, stackTrace: stackTrace);
    if (mounted) {
      final detail = error is FirebaseFunctionsException
          ? '${error.code}: ${error.message ?? 'request failed'}'
          : error is FirebaseException
              ? '${error.code}: ${error.message ?? 'request failed'}'
              : error is StateError
                  ? error.message
                  : 'Unexpected trip service error';
      snack(context, '$detail ($code)', error: true);
    }
  }

  Future<void> _sendFeedback(int sequence, int code) async {
    _pendingFeedback[sequence] = code;
    await _flushFeedback();
  }

  Future<void> _flushFeedback() async {
    if (reader.state != RideReaderConnectionState.connected) return;
    final pending = Map<int, int>.from(_pendingFeedback);
    for (final entry in pending.entries) {
      try {
        await reader.feedback(entry.value);
        _pendingFeedback.remove(entry.key);
      } on StateError {
        return;
      } on FirebaseException {
        return;
      }
    }
  }

  Future<void> _startTrip() async {
    if (_tripBusy || trip.active) return;
    setState(() => _tripBusy = true);
    try {
      final userId = FirebaseAuth.instance.currentUser?.uid;
      if (userId == null) throw StateError('Sign-in is required.');
      final user = await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .get();
      _busId = user.data()?['busId']?.toString();
      if (_busId == null || _busId!.isEmpty) {
        throw StateError('No bus is assigned to this driver.');
      }
      final routeId = trip.routeId;
      if (routeId == null || routeId.isEmpty) {
        throw StateError('Select an assigned route before starting.');
      }
      final manual = reader.state != RideReaderConnectionState.connected;
      if (manual) {
        final idNumber = await showDialog<String>(
          context: context,
          builder: (dialogContext) {
            final controller = TextEditingController();
            return AlertDialog(
              title: const Text('Reader not connected'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                      'Start the trip manually? Enter your ID card number.'),
                  const SizedBox(height: 12),
                  TextField(
                    controller: controller,
                    autofocus: true,
                    textCapitalization: TextCapitalization.characters,
                    decoration:
                        const InputDecoration(labelText: 'ID card number'),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () =>
                      Navigator.pop(dialogContext, controller.text.trim()),
                  child: const Text('Verify and start'),
                ),
              ],
            );
          },
        );
        if (idNumber == null || idNumber.isEmpty) return;
        late final HttpsCallableResult<dynamic> verification;
        try {
          verification = await callWithFreshSession(
              'verifyDriverIdForManualMode', {'idNumber': idNumber});
        } on FirebaseFunctionsException catch (error) {
          if (_isMissingCallable(error)) {
            throw _missingTripServiceError('verifyDriverIdForManualMode');
          }
          rethrow;
        }
        final data = Map<String, dynamic>.from(verification.data as Map);
        if (data['ok'] != true) {
          throw StateError(data['reason'] == 'missing_id'
              ? 'Ask the admin to add your ID card number.'
              : 'The ID card number did not match.');
        }
      }
      late final HttpsCallableResult<dynamic> result;
      try {
        result = await callWithFreshSession('startTrip', {
          'busId': _busId,
          'routeId': routeId,
          'manualEnabled': manual,
          'requestId': '$userId-${DateTime.now().microsecondsSinceEpoch}',
        });
      } on FirebaseFunctionsException catch (error) {
        if (_isMissingCallable(error)) {
          throw _missingTripServiceError('startTrip');
        }
        rethrow;
      }
      _tripId = (result.data as Map)['tripId']?.toString();
      await location.start(tripId: _tripId!);
      if (Platform.isAndroid) await startForegroundTripService();
      _watchActiveTrip();
    } catch (error, stackTrace) {
      _showTripActionError(error, stackTrace, 'E-TRIP-01');
    } finally {
      if (mounted) setState(() => _tripBusy = false);
    }
  }

  Future<void> _manualEntry() async {
    final tripId = _tripId;
    final busId = _busId;
    final userId = FirebaseAuth.instance.currentUser?.uid;
    if (tripId == null || busId == null || userId == null) {
      snack(context, 'Start an active trip before recording a student.',
          warn: true);
      return;
    }
    final number = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final controller = TextEditingController();
        return AlertDialog(
          title: const Text('Manual student entry'),
          content: TextField(
            controller: controller,
            autofocus: true,
            maxLength: 11,
            inputFormatters: [RideGuardCardNumberFormatter()],
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(
                labelText: 'Printed card number',
                helperText: 'Enter the 8-character number. No suggestions.'),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () =>
                    Navigator.pop(ctx, controller.text.trim().toUpperCase()),
                child: const Text('Record')),
          ],
        );
      },
    );
    if (number == null || !isRideGuardCardId(number)) {
      if (number != null) {
        snack(context, 'Card number must contain exactly 8 letters or digits.',
            error: true);
      }
      return;
    }
    // Capture time, mode and location now, before the lookups below.
    final tappedAt = DateTime.now().millisecondsSinceEpoch;
    final entryMode = trip.boarding ? 'boarding' : 'alighting';
    final gps = await _captureTapLocation();
    final cards = await FirebaseFirestore.instance
        .collection('cards')
        .where('cardNumber', isEqualTo: number)
        .where('status', isEqualTo: 'active')
        .limit(1)
        .get();
    if (cards.docs.isEmpty) {
      snack(context, 'No active card matches that number.', error: true);
      return;
    }
    final student = await FirebaseFirestore.instance
        .collection('students')
        .where('cardUid', isEqualTo: cards.docs.first.data()['cardUid'])
        .where('busId', isEqualTo: busId)
        .limit(1)
        .get();
    if (student.docs.isEmpty) {
      snack(context, 'That card is not assigned to a student on this bus.',
          error: true);
      return;
    }
    final eventId = 'manual-${DateTime.now().microsecondsSinceEpoch}';
    await queue.enqueue(
      key: eventId,
      tripId: tripId,
      payload: {
        'eventId': eventId,
        'idempotencyKey': eventId,
        'source': 'manual',
        'studentId': student.docs.first.id,
        'busId': busId,
        'driverId': userId,
        'mode': entryMode,
        'tappedAt': tappedAt,
        ...gps,
      },
    );
    await _uploadPending();
    if (mounted) {
      if (gps.isEmpty) {
        snack(context, 'Student recorded, but without a GPS location point.',
            warn: true);
      } else {
        snack(context, 'Student event recorded.');
      }
    }
  }

  Widget _round(IconData icon, String label, VoidCallback onTap,
      {bool ok = false}) {
    final s = Theme.of(context).colorScheme;
    return Column(children: [
      Material(
        color: ok ? Colors.green.shade700 : s.primaryContainer,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
              width: 68,
              height: 68,
              child: Icon(icon,
                  size: 32, color: ok ? Colors.white : s.onPrimaryContainer)),
        ),
      ),
      const SizedBox(height: 6),
      Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
    ]);
  }

  void _routeSheet() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const ListTile(
              title: Text('Select your route'),
              subtitle: Text('Assigned by the admin')),
          if (_routes.isEmpty)
            const ListTile(title: Text('No route is assigned to this bus.'))
          else
            for (final route in _routes)
              ListTile(
                leading: const Icon(Icons.alt_route),
                title:
                    Text(route['name']?.toString() ?? route['id'].toString()),
                subtitle:
                    Text('${(route['stops'] as List?)?.length ?? 0} stops'),
                trailing: trip.routeId == route['id']
                    ? const Icon(Icons.check_circle, color: Colors.green)
                    : null,
                onTap: () {
                  trip.selectRoute(route['id'].toString());
                  Navigator.pop(ctx);
                },
              ),
        ]),
      ),
    );
  }

  /// Small, fixed-size style so theme-level "full width" button sizes can
  /// never break a ListTile trailing slot or a Row.
  ButtonStyle get _compactTextButton =>
      TextButton.styleFrom(minimumSize: const Size(0, 40));

  void _moduleSheet() {
    // The sheet is its own route, so it must rebuild itself: calling the
    // page's setState does not refresh it. StatefulBuilder fixes that.
    var open = true;
    var started = false;
    var scanning = false;
    var scannedOnce = false;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (ctx, setSheet) {
          void refresh(VoidCallback change) {
            if (open && ctx.mounted) setSheet(change);
          }

          Future<void> scan() async {
            refresh(() {
              _readerFailure = null;
              _pairingHintShown = true;
              scanning = true;
            });
            try {
              await reader.scan();
            } catch (error) {
              refresh(() => _readerFailure = mapRideReaderError(error));
            } finally {
              scannedOnce = true;
              refresh(() => scanning = false);
            }
          }

          // Start scanning automatically the first time the sheet opens.
          if (!started && reader.connectedDevice == null) {
            started = true;
            scheduleMicrotask(scan);
          }

          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: StreamBuilder<List<ScanResult>>(
                stream: reader.discoveredDevices,
                initialData: const [],
                builder: (ctx, snapshot) {
                  final devices = snapshot.data ?? const <ScanResult>[];
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ListTile(
                        leading: Icon(
                          reader.connectedDevice == null
                              ? Icons.bluetooth
                              : Icons.bluetooth_connected,
                          color: reader.connectedDevice == null
                              ? null
                              : Colors.green,
                        ),
                        title: Text(reader.connectedDevice == null
                            ? 'Ride Readers'
                            : 'Ride Reader connected'),
                        subtitle: Text(
                          'Only Ride Reader devices are listed. '
                          'Pending uploads: $_pendingCount',
                        ),
                      ),
                      if (!_pairingHintShown)
                        const ListTile(
                          leading: Icon(Icons.info_outline),
                          title: Text(
                              'Do not pair in Settings. Press Connect here.'),
                        ),
                      if (_readerFailure != null)
                        ListTile(
                          leading: const Icon(Icons.error_outline),
                          title: Text(_readerFailure!.message),
                          trailing: _readerFailure!.kind ==
                                  RideReaderFailureKind.locationOff
                              ? TextButton(
                                  style: _compactTextButton,
                                  onPressed: () async {
                                    await RideGuardPermissionService()
                                        .openLocationSettings();
                                  },
                                  child: const Text('Location settings'),
                                )
                              : _readerFailure!.kind ==
                                      RideReaderFailureKind.bluetoothOff
                                  ? TextButton(
                                      style: _compactTextButton,
                                      onPressed: () async {
                                        // iOS cannot switch Bluetooth on from
                                        // an app; send the driver to Settings.
                                        if (Platform.isAndroid) {
                                          await FlutterBluePlus.turnOn();
                                        } else {
                                          await RideGuardPermissionService()
                                              .openSettings();
                                        }
                                      },
                                      child: const Text('Turn on'),
                                    )
                                  : _readerFailure!.kind ==
                                          RideReaderFailureKind.permissionDenied
                                      ? TextButton(
                                          style: _compactTextButton,
                                          onPressed: () =>
                                              RideGuardPermissionService()
                                                  .openSettings(),
                                          child: const Text('App settings'),
                                        )
                                      : null,
                        ),
                      if (reader.connectedDevice != null)
                        OutlinedButton(
                          onPressed: () async {
                            await reader.disconnect();
                            trip.connect(false);
                            refresh(() {});
                            if (mounted) setState(() {});
                          },
                          child: const Text('Disconnect'),
                        )
                      else ...[
                        FilledButton.icon(
                          onPressed: scanning ? null : scan,
                          icon: scanning
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.search),
                          label: Text(scanning
                              ? 'Scanning...'
                              : 'Scan for Ride Readers'),
                        ),
                        if (devices.isEmpty &&
                            !scanning &&
                            scannedOnce &&
                            _readerFailure == null)
                          const ListTile(
                            leading: Icon(Icons.bluetooth_searching),
                            title: Text('No Ride Reader found'),
                            subtitle: Text(
                                'Power the reader, keep it close to the phone, '
                                'and make sure Bluetooth and Location are on. '
                                'Then scan again.'),
                          ),
                        for (final result in devices)
                          _RideReaderRow(
                            result: result,
                            onConnect: () async {
                              try {
                                final deviceId = _readerDeviceId;
                                if (deviceId == null || deviceId.isEmpty) {
                                  throw StateError(
                                    'No Ride Reader is registered to this bus.',
                                  );
                                }
                                await reader.connect(
                                  result.device,
                                  expectedDeviceId: deviceId,
                                );
                                _moduleLabel = rideReaderDisplayName(result);
                                await _loadBusDetails();
                                trip.connect(true);
                                refresh(() => _readerFailure = null);
                                if (mounted) setState(() {});
                              } catch (error) {
                                refresh(() =>
                                    _readerFailure = mapRideReaderError(error));
                              }
                            },
                          ),
                      ],
                    ],
                  );
                },
              ),
            ),
          );
        },
      ),
    ).whenComplete(() {
      open = false;
    });
  }

  void _settingsSheet() {
    final permissions = RideGuardPermissionService();
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: FutureBuilder<List<String>>(
          future: _permissionLabels(permissions),
          builder: (ctx, snapshot) {
            final values = snapshot.data ??
                const ['CHECKING', 'CHECKING', 'CHECKING', 'CHECKING'];
            return Column(mainAxisSize: MainAxisSize.min, children: [
              const ListTile(title: Text('Settings')),
              _permissionTile(Icons.location_on, 'Precise location', values[0]),
              _permissionTile(
                  Icons.my_location, 'Background location', values[1]),
              _permissionTile(Icons.bluetooth, 'Bluetooth', values[2]),
              _permissionTile(Icons.notifications, 'Notifications', values[3]),
              TextButton.icon(
                onPressed: () async {
                  await permissions.openSettings();
                  if (ctx.mounted) Navigator.pop(ctx);
                },
                icon: const Icon(Icons.settings),
                label: const Text('Open app settings'),
              ),
              if (Platform.isAndroid)
                TextButton.icon(
                  onPressed: permissions.openBatteryOptimizationSettings,
                  icon: const Icon(Icons.battery_saver),
                  label: const Text('Disable battery optimization'),
                ),
            ]);
          },
        ),
      ),
    );
  }

  Future<List<String>> _permissionLabels(
      RideGuardPermissionService service) async {
    final location = await service.foregroundLocationStatus();
    final background = await service.backgroundLocationStatus();
    final scan = await service.bluetoothScanStatus();
    final connect = await service.bluetoothConnectStatus();
    final bluetooth = scan.isGranted && connect.isGranted
        ? 'GRANTED'
        : scan.isPermanentlyDenied || connect.isPermanentlyDenied
            ? 'SETTINGS'
            : 'DENIED';
    final notifications =
        (await service.notificationStatus()).isGranted ? 'GRANTED' : 'DENIED';
    return [
      location.isGranted
          ? 'GRANTED'
          : location.isPermanentlyDenied
              ? 'SETTINGS'
              : 'DENIED',
      background.isGranted
          ? 'GRANTED'
          : background.isPermanentlyDenied
              ? 'SETTINGS'
              : 'DENIED',
      bluetooth,
      notifications,
    ];
  }

  Widget _permissionTile(IconData icon, String title, String value) {
    final color = value == 'GRANTED'
        ? Colors.green
        : value == 'CHECKING'
            ? Colors.blueGrey
            : Colors.orange.shade800;
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      trailing: Chip2(value, color),
    );
  }

  Future<void> _endTrip() async {
    if (_endTripBusy || !trip.active) return;
    final remaining = <Map<String, dynamic>>[];
    for (final studentId in trip.onBoard) {
      for (final student in _students) {
        if (student['id']?.toString() == studentId) {
          remaining.add(student);
          break;
        }
      }
    }
    if (remaining.isNotEmpty) {
      final names = remaining
          .map((student) =>
              student['fullName']?.toString() ??
              student['name']?.toString() ??
              student['id'].toString())
          .join('\n');
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('${trip.onBoard.length} student(s) still on board'),
          content: Text(
              'End the trip anyway? This list is sent in the trip-ended record:\n\n$names'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Keep trip')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('End trip')),
          ],
        ),
      );
      if (ok != true) return;
    }
    if (!mounted) return;
    setState(() => _endTripBusy = true);
    try {
      if (_tripId != null) {
        final userId = FirebaseAuth.instance.currentUser?.uid;
        if (userId == null) throw StateError('Sign-in is required.');
        await callWithFreshSession('endTrip', {
          'tripId': _tripId,
          'requestId': '$userId-${DateTime.now().microsecondsSinceEpoch}',
          'remainingStudentIds':
              remaining.map((student) => student['id']).toList(),
        });
      }
      await location.stop();
      if (Platform.isAndroid) await stopForegroundTripService();
      trip.clear();
    } catch (error, stackTrace) {
      _showTripActionError(error, stackTrace, 'E-TRIP-02');
    } finally {
      if (mounted) setState(() => _endTripBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // The students stream is created once per bus. Creating it inside build
    // would re-subscribe on every rebuild and re-read every student each time.
    final busId = _busId;
    if (_studentsStream == null || _studentsStreamBusId != busId) {
      _studentsStreamBusId = busId;
      _studentsStream = busId == null || busId.isEmpty
          ? const Stream<QuerySnapshot<Map<String, dynamic>>>.empty()
          : FirebaseFirestore.instance
              .collection('students')
              .where('busId', isEqualTo: busId)
              .orderBy('name')
              .snapshots();
    }
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _studentsStream,
      builder: (context, snapshot) {
        _students = snapshot.data?.docs
                .map((doc) => {...doc.data(), 'id': doc.id})
                .toList() ??
            const [];
        if (snapshot.hasError) {
          return Center(
              child: const Text('Unable to load students. Please retry.'));
        }
        return _buildWithStudents(context);
      },
    );
  }

  Widget _buildWithStudents(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final capacity = trip.capacity;
    final pct = capacity == 0 ? 0.0 : trip.onBoard.length / capacity;

    return ListView(padding: const EdgeInsets.all(16), children: [
      if (_assignmentError != null)
        Card(
          color: Theme.of(context).colorScheme.errorContainer,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Text(_assignmentError!),
          ),
        ),
      Text('Bus ${_busLabel ?? 'not assigned'}',
          style: Theme.of(context).textTheme.titleMedium),
      Text('Module ${_moduleLabel ?? 'not connected'}',
          style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 16),
      Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
        _round(Icons.alt_route, 'Route', _routeSheet, ok: trip.routeSelected),
        _round(
            trip.moduleConnected ? Icons.bluetooth_connected : Icons.bluetooth,
            'Module',
            _moduleSheet,
            ok: trip.moduleConnected),
        _round(Icons.settings, 'Settings', _settingsSheet),
      ]),
      const SizedBox(height: 20),
      if (!trip.active)
        FilledButton.icon(
          onPressed: _tripBusy || !trip.routeSelected
              ? null
              : () async {
                  try {
                    await _startTrip();
                  } catch (error, stackTrace) {
                    _showTripActionError(error, stackTrace, 'E-TRIP-01');
                  }
                },
          icon: const Icon(Icons.play_arrow),
          label: Text(trip.tripNo == 0 ? 'Start trip' : 'Start new trip'),
        )
      else
        OutlinedButton.icon(
            onPressed: _endTripBusy ? null : _endTrip,
            icon: const Icon(Icons.stop_circle_outlined),
            label: _endTripBusy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text('End trip #${trip.tripNo}')),
      if (!trip.routeSelected)
        const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text('Select your route first (tap Route).',
                textAlign: TextAlign.center)),
      const SizedBox(height: 16),
      Row(children: [
        Expanded(
          child: SizedBox(
            height: 76,
            child: trip.boarding
                ? FilledButton(
                    onPressed: () => trip.setMode(true),
                    child: const Text('BOARDING'))
                : OutlinedButton(
                    onPressed: () => trip.setMode(true),
                    child: const Text('BOARDING')),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: SizedBox(
            height: 76,
            child: !trip.boarding
                ? FilledButton(
                    style: FilledButton.styleFrom(
                        backgroundColor: Colors.deepOrange.shade700,
                        foregroundColor: Colors.white),
                    onPressed: () => trip.setMode(false),
                    child: const Text('ALIGHTING'))
                : OutlinedButton(
                    onPressed: () => trip.setMode(false),
                    child: const Text('ALIGHTING')),
          ),
        ),
      ]),
      if (trip.active)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: OutlinedButton.icon(
            onPressed: _manualEntry,
            icon: const Icon(Icons.keyboard),
            label: const Text('Enter printed card number manually'),
          ),
        ),
      const SizedBox(height: 16),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${trip.onBoard.length}/${trip.capacity}',
                        style: Theme.of(context)
                            .textTheme
                            .displaySmall
                            ?.copyWith(fontWeight: FontWeight.w800)),
                    const Text('students on board'),
                    const SizedBox(height: 8),
                    Text('${(pct * 100).round()}% full',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    Chip2(
                        trip.active
                            ? (trip.boarding
                                ? 'BOARDING  •  Trip #${trip.tripNo}'
                                : 'ALIGHTING  •  Trip #${trip.tripNo}')
                            : 'NO TRIP RUNNING',
                        trip.active ? Colors.green.shade700 : Colors.blueGrey),
                  ]),
            ),
            Container(
              width: 26,
              height: 130,
              decoration: BoxDecoration(
                  border: Border.all(color: s.outline),
                  borderRadius: BorderRadius.circular(13)),
              clipBehavior: Clip.antiAlias,
              child: Align(
                alignment: Alignment.bottomCenter,
                child: FractionallySizedBox(
                    heightFactor: pct.clamp(0.0, 1.0),
                    widthFactor: 1,
                    child: Container(color: s.primary)),
              ),
            ),
          ]),
        ),
      ),
      const SizedBox(height: 16),
      _DriverMap(
        busId: _busId,
        routePoints: _routePoints,
        color: s.primary,
      ),
      const SizedBox(height: 8),
      ListTile(
        leading: const Icon(Icons.schedule),
        title: Text(trip.active
            ? 'Live location tracking active'
            : 'Start a trip to begin location tracking'),
        subtitle: const Text('Location is provided by this phone.'),
      ),
      ValueListenableBuilder<String>(
        valueListenable: location.status,
        builder: (context, message, _) => ListTile(
          leading: const Icon(Icons.gps_fixed),
          title: const Text('GPS status'),
          subtitle: Text(message),
        ),
      ),
      ValueListenableBuilder<int>(
        valueListenable: location.uploaded,
        builder: (context, uploaded, _) => ValueListenableBuilder<int>(
          valueListenable: location.pending,
          builder: (context, pending, _) => ListTile(
            leading: const Icon(Icons.pin_drop_outlined),
            title: Text('Location points saved: $uploaded'),
            subtitle: Text('Waiting to upload: $pending'),
          ),
        ),
      ),
      ListTile(
        leading: const Icon(Icons.block),
        title: const Text('Rejected taps today'),
        subtitle: Text('No active trip: $_rejectedNoTripCount'),
      ),
      const Divider(),
      Text('Students on board', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 8),
      if (trip.onBoard.isEmpty)
        const Padding(
            padding: EdgeInsets.all(16),
            child: Text('No students are currently marked on board.')),
      for (final student in _students)
        if (_tripStudentIds.contains(student['id']?.toString()))
          ListTile(
            leading: const CircleAvatar(child: Icon(Icons.person)),
            title: Text(student['fullName']?.toString() ??
                student['name']?.toString() ??
                student['id'].toString()),
            subtitle: Text(
                student['pickupStop']?.toString() ?? 'Pickup stop not set'),
            trailing: _alightedStudentIds.contains(student['id']?.toString())
                ? const Chip2('ALIGHTED', Colors.blueGrey)
                : null,
          ),
    ]);
  }
}

class _DriverMap extends StatefulWidget {
  const _DriverMap({
    required this.busId,
    required this.routePoints,
    required this.color,
  });
  final String? busId;
  final List<LatLng> routePoints;
  final Color color;

  @override
  State<_DriverMap> createState() => _DriverMapState();
}

class _DriverMapState extends State<_DriverMap> with WidgetsBindingObserver {
  StreamSubscription<Position>? _phoneSubscription;
  Position? _phonePosition;
  Stream<DocumentSnapshot<Map<String, dynamic>>>? _liveStream;
  String? _liveStreamBusId;
  Stream<QuerySnapshot<Map<String, dynamic>>>? _historyStream;
  String? _historyStreamTripId;

  // Streams must not be created inside build: every phone position update
  // rebuilds this widget, which would otherwise re-subscribe and re-read the
  // whole trip history from Firestore each time.
  Stream<DocumentSnapshot<Map<String, dynamic>>> _liveStreamFor(String busId) {
    if (_liveStream == null || _liveStreamBusId != busId) {
      _liveStreamBusId = busId;
      _liveStream = FirebaseFirestore.instance
          .collection('liveLocations')
          .doc(busId)
          .snapshots();
    }
    return _liveStream!;
  }

  Stream<QuerySnapshot<Map<String, dynamic>>>? _historyStreamFor(
      String? tripId) {
    if (tripId == null) {
      _historyStream = null;
      _historyStreamTripId = null;
      return null;
    }
    if (_historyStream == null || _historyStreamTripId != tripId) {
      _historyStreamTripId = tripId;
      _historyStream = FirebaseFirestore.instance
          .collection('trips')
          .doc(tripId)
          .collection('locations')
          .orderBy('updatedAt')
          .snapshots();
    }
    return _historyStream;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startPhoneLocation();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _startPhoneLocation();
    } else if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _stopPhoneLocation();
    }
  }

  Future<void> _startPhoneLocation() async {
    if (_phoneSubscription != null ||
        !await Geolocator.isLocationServiceEnabled()) {
      return;
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return;
    }
    try {
      final current = await Geolocator.getCurrentPosition();
      if (mounted) setState(() => _phonePosition = current);
      _phoneSubscription = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 10,
        ),
      ).listen((position) {
        if (mounted) setState(() => _phonePosition = position);
      }, onError: (Object error, StackTrace stackTrace) {
        developer.log('Dashboard location stream failed',
            name: 'rideguard.location', error: error, stackTrace: stackTrace);
        _phoneSubscription = null;
      });
    } catch (error, stackTrace) {
      developer.log('Dashboard location unavailable',
          name: 'rideguard.location', error: error, stackTrace: stackTrace);
    }
  }

  Future<void> _stopPhoneLocation() async {
    await _phoneSubscription?.cancel();
    _phoneSubscription = null;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopPhoneLocation();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final busId = widget.busId;
    final routePoints = widget.routePoints;
    final color = widget.color;
    if (busId == null) {
      return const SizedBox(
          height: 140, child: Center(child: Text('No bus assigned.')));
    }
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: _liveStreamFor(busId),
      builder: (context, snapshot) {
        final data = snapshot.data?.data();
        final tripId = data?['tripId']?.toString();
        final position = data?['lat'] is num && data?['lng'] is num
            ? LatLng((data!['lat'] as num).toDouble(),
                (data['lng'] as num).toDouble())
            : null;
        final updated = data?['updatedAt'];
        final updatedAt = updated is Timestamp ? updated.toDate() : null;
        final stale = tripId != null &&
            (updatedAt == null ||
                DateTime.now().difference(updatedAt).inMinutes >= 2);
        final accuracy = (data?['accuracy'] as num?)?.toDouble();
        if (position == null && _phonePosition == null && routePoints.isEmpty) {
          return const SizedBox(
              height: 140,
              child: Center(
                  child: Text('Start a trip to publish your GPS location.')));
        }
        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: _historyStreamFor(tripId),
          builder: (context, historySnapshot) {
            final history = <LatLng>[
              for (final point in historySnapshot.data?.docs ?? const [])
                if (point.data()['lat'] is num && point.data()['lng'] is num)
                  LatLng(
                    (point.data()['lat'] as num).toDouble(),
                    (point.data()['lng'] as num).toDouble(),
                  ),
            ];
            return Column(children: [
              if (stale)
                const ListTile(
                  leading: Icon(Icons.warning_amber),
                  title: Text('Location delayed'),
                  subtitle:
                      Text('The last GPS update is older than 2 minutes.'),
                ),
              if (accuracy != null && accuracy > 80)
                ListTile(
                  leading: const Icon(Icons.gps_not_fixed),
                  title: const Text('Weak GPS accuracy'),
                  subtitle:
                      Text('Accuracy is ${accuracy.toStringAsFixed(0)} m.'),
                ),
              Stack(children: [
                RealMap(
                  height: 380,
                  initialCenter: position ??
                      (_phonePosition == null
                          ? null
                          : LatLng(_phonePosition!.latitude,
                              _phonePosition!.longitude)),
                  followPosition: position,
                  follow: tripId != null,
                  paths: [
                    if (history.isNotEmpty) MapPath(history, color),
                    if (history.isEmpty && routePoints.isNotEmpty)
                      MapPath(routePoints, color),
                  ],
                  markers: [
                    if (_phonePosition != null)
                      MapMarker(
                        LatLng(_phonePosition!.latitude,
                            _phonePosition!.longitude),
                        Colors.blue,
                        Icons.my_location,
                        label: 'Phone',
                      ),
                    if (position != null)
                      MapMarker(position, Colors.green, Icons.directions_bus,
                          label: 'Bus'),
                    if (routePoints.isNotEmpty)
                      MapMarker(routePoints.last, Colors.red, Icons.school,
                          label: 'School'),
                  ],
                ),
                if (updatedAt != null)
                  Positioned(
                    top: 8,
                    right: 112,
                    child: GpsSavedBadge(
                      key: ValueKey(updatedAt),
                      updatedAt: updatedAt,
                    ),
                  ),
              ]),
              if (updatedAt != null)
                ListTile(
                  leading: const Icon(Icons.update),
                  title: Text('Last GPS update: $updatedAt'),
                ),
            ]);
          },
        );
      },
    );
  }
}

/// Remembers, on the phone, when each card boarded the current trip.
///
/// Used by the driver screen to notice a second tap of a card that is
/// already on board (see `_handleReaderTap`). It is saved in a small local
/// database, so it works offline and survives an app restart.
class BoardingStore {
  BoardingStore._();
  static final BoardingStore instance = BoardingStore._();

  sql.Database? _db;

  Future<sql.Database> _open() async {
    final existing = _db;
    if (existing != null) return existing;
    final dir = await sql.getDatabasesPath();
    final db = await sql.openDatabase(
      '$dir/boarding_records.db',
      version: 1,
      onCreate: (db, version) => db.execute(
        'CREATE TABLE boardings ('
        'trip_id TEXT NOT NULL, '
        'card_code TEXT NOT NULL, '
        'boarded_at INTEGER NOT NULL, '
        'PRIMARY KEY (trip_id, card_code))',
      ),
    );
    _db = db;
    return db;
  }

  /// Saves the boarding time. The first boarding time is kept if the card
  /// is already recorded.
  Future<void> markBoarded(
      String tripId, String cardCode, int boardedAt) async {
    final db = await _open();
    await db.insert(
      'boardings',
      {'trip_id': tripId, 'card_code': cardCode, 'boarded_at': boardedAt},
      conflictAlgorithm: sql.ConflictAlgorithm.ignore,
    );
  }

  /// Forgets the card (it got off, or its boarding was rejected).
  Future<void> remove(String tripId, String cardCode) async {
    final db = await _open();
    await db.delete(
      'boardings',
      where: 'trip_id = ? AND card_code = ?',
      whereArgs: [tripId, cardCode],
    );
  }

  /// When the card boarded this trip, or null if it is not on board.
  Future<int?> boardedAt(String tripId, String cardCode) async {
    final db = await _open();
    final rows = await db.query(
      'boardings',
      columns: ['boarded_at'],
      where: 'trip_id = ? AND card_code = ?',
      whereArgs: [tripId, cardCode],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final value = rows.first['boarded_at'];
    return value is int ? value : (value as num?)?.toInt();
  }

  /// Deletes the records of every other (older) trip.
  Future<void> pruneExcept(String tripId) async {
    final db = await _open();
    await db.delete('boardings', where: 'trip_id != ?', whereArgs: [tripId]);
  }
}
