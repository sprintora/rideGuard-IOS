import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:latlong2/latlong.dart';
import 'dart:developer' as developer;
import 'dart:async';

import 'app_models.dart';
import 'auth_repository.dart';
import 'widgets.dart';

class _ParentStudent {
  const _ParentStudent(this.id, this.data);

  final String id;
  final Map<String, dynamic> data;
}

/// Turns any error into a short, friendly message (no raw exceptions or
/// stack traces are ever shown to the parent).
String _friendly(Object error) {
  if (error is TimeoutException) {
    return 'The server took too long to respond. Check your connection and try again.';
  }
  final text = error.toString().toLowerCase();
  if (text.contains('unauthenticated')) {
    return 'Your session has expired. Please log out and sign in again.';
  }
  if (text.contains('permission-denied')) {
    return 'You do not have permission to view this.';
  }
  if (text.contains('unavailable') ||
      text.contains('network') ||
      text.contains('socket')) {
    return 'No connection. Check your internet and try again.';
  }
  return 'Something went wrong. Please try again.';
}

/// Cloud Functions return plain JSON, so timestamps can arrive as a
/// Timestamp, a {_seconds: ..} map, milliseconds, seconds or an ISO string.
DateTime? _parseTime(dynamic value) {
  if (value is Timestamp) return value.toDate();
  if (value is DateTime) return value;
  if (value is int) {
    return DateTime.fromMillisecondsSinceEpoch(
        value > 100000000000 ? value : value * 1000);
  }
  if (value is String) return DateTime.tryParse(value);
  if (value is Map) {
    final seconds = value['_seconds'] ?? value['seconds'];
    if (seconds is num) {
      return DateTime.fromMillisecondsSinceEpoch(seconds.toInt() * 1000);
    }
  }
  return null;
}

double? _num(dynamic v) =>
    v is num ? v.toDouble() : (v is String ? double.tryParse(v) : null);

LatLng? _coordinate(dynamic lat, dynamic lng) {
  final a = _num(lat), b = _num(lng);
  if (a == null || b == null || (a == 0 && b == 0)) return null;
  return LatLng(a, b);
}

/// Centre of everything that must be visible on the map.
LatLng? _boundsCenter(Iterable<LatLng> pts) {
  if (pts.isEmpty) return null;
  var minLat = pts.first.latitude, maxLat = minLat;
  var minLng = pts.first.longitude, maxLng = minLng;
  for (final p in pts) {
    if (p.latitude < minLat) minLat = p.latitude;
    if (p.latitude > maxLat) maxLat = p.latitude;
    if (p.longitude < minLng) minLng = p.longitude;
    if (p.longitude > maxLng) maxLng = p.longitude;
  }
  return LatLng((minLat + maxLat) / 2, (minLng + maxLng) / 2);
}

class ParentHome extends StatefulWidget {
  const ParentHome({super.key});
  @override
  State<ParentHome> createState() => _ParentDashboardState();
}

class _ParentDashboardState extends State<ParentHome> {
  int sel = 0;
  DateTime _selectedDate = DateUtils.dateOnly(DateTime.now());
  String? _loadedFor;
  Future<List<_ParentStudent>>? _childrenFuture;

  /// Reloads the children automatically when a different account signs in,
  /// so a previous user's (or an empty) result is never reused.
  Future<List<_ParentStudent>> _futureFor(String uid) {
    if (_loadedFor != uid || _childrenFuture == null) {
      _loadedFor = uid;
      sel = 0;
      _childrenFuture = _loadChildren();
    }
    return _childrenFuture!;
  }

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      return const _ParentMessage(message: 'Sign in to view your children.');
    }
    return FutureBuilder<List<_ParentStudent>>(
      future: _futureFor(uid),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          developer.log('Parent children load failed: ${snapshot.error}',
              name: 'rideguard.parent');
          return _ParentMessage(
            message: 'Unable to load your children.',
            detail: _friendly(snapshot.error!),
            action: 'Retry',
            onPressed: () => setState(() {
              _childrenFuture = _loadChildren();
            }),
          );
        }
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final kids = snapshot.data ?? const <_ParentStudent>[];
        if (kids.isEmpty) {
          return const _ParentMessage(
            message: 'No children are linked to this account.',
            detail: 'Ask your school administrator to link a student account.',
          );
        }
        final index = sel.clamp(0, kids.length - 1);
        return _ParentChildPage(
          kids: kids,
          selectedIndex: index,
          selectedDate: _selectedDate,
          onChildChanged: (value) => setState(() => sel = value),
          onDateChanged: (value) => setState(() => _selectedDate = value),
        );
      },
    );
  }

  Future<List<_ParentStudent>> _loadChildren() async {
    final result = await callWithFreshSession('getParentStudents')
        .timeout(const Duration(seconds: 25));
    final data = result.data;
    final rawStudents = data is Map ? data['students'] : null;
    if (rawStudents is! List) {
      throw StateError('Parent student response is invalid.');
    }
    developer.log('Parent children loaded: ${rawStudents.length}',
        name: 'rideguard.parent');
    return [
      for (final raw in rawStudents)
        if (raw is Map && raw['id'] != null)
          _ParentStudent(
            raw['id'].toString(),
            {
              for (final entry in raw.entries)
                if (entry.key != 'id') entry.key.toString(): entry.value,
            },
          ),
    ];
  }
}

class _ParentMessage extends StatelessWidget {
  const _ParentMessage({
    required this.message,
    this.detail,
    this.action,
    this.onPressed,
  });
  final String message;
  final String? detail;
  final String? action;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(message, textAlign: TextAlign.center),
              if (detail != null) ...[
                const SizedBox(height: 8),
                Text(detail!,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall),
              ],
              if (action != null && onPressed != null) ...[
                const SizedBox(height: 16),
                SizedBox(
                    width: 140,
                    height: 44,
                    child: FilledButton(
                        style: FilledButton.styleFrom(
                            minimumSize: const Size(0, 44)),
                        onPressed: onPressed,
                        child: Text(action!))),
              ],
            ]),
          ),
        ),
      );
}

class _ParentChildPage extends StatelessWidget {
  const _ParentChildPage({
    required this.kids,
    required this.selectedIndex,
    required this.selectedDate,
    required this.onChildChanged,
    required this.onDateChanged,
  });
  final List<_ParentStudent> kids;
  final int selectedIndex;
  final DateTime selectedDate;
  final ValueChanged<int> onChildChanged;
  final ValueChanged<DateTime> onDateChanged;

  @override
  Widget build(BuildContext context) {
    final child = kids[selectedIndex];
    final name = child.data['name']?.toString() ?? 'Child';
    final busId = child.data['busId']?.toString();
    // Show the bus number plate, never the internal bus ID.
    final busLabel =
        (child.data['busPlate'] ?? child.data['busNumber'])?.toString().trim();
    final hasBus = busId != null && busId.isNotEmpty;
    return LayoutBuilder(
      builder: (context, constraints) {
        // shrinkWrap keeps the page visible even if the parent widget gives
        // this screen unbounded height (a common cause of a blank page).
        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: ListView(
              shrinkWrap: !constraints.hasBoundedHeight,
              padding: const EdgeInsets.all(16),
              children: [
                Text('My children',
                    style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 12),
                DropdownButtonFormField<int>(
                  key: ValueKey('child-$selectedIndex'),
                  initialValue: selectedIndex,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Select child'),
                  items: [
                    for (var i = 0; i < kids.length; i++)
                      DropdownMenuItem(
                          value: i,
                          child: Text(
                            kids[i].data['name']?.toString() ??
                                'Child ${i + 1}',
                            overflow: TextOverflow.ellipsis,
                          )),
                  ],
                  onChanged: (value) {
                    if (value != null) onChildChanged(value);
                  },
                ),
                const SizedBox(height: 12),
                Card(
                    child: ListTile(
                  leading: const Icon(Icons.child_care),
                  title: Text(name, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                      busLabel != null && busLabel.isNotEmpty
                          ? 'Bus: $busLabel'
                          : (hasBus ? 'Bus assigned' : 'No bus assigned'),
                      overflow: TextOverflow.ellipsis),
                )),
                const SizedBox(height: 12),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.calendar_today_outlined),
                    title: Text(
                        '${selectedDate.day}/${selectedDate.month}/${selectedDate.year}'),
                    subtitle: const Text('Tap to change the date'),
                    trailing: const Icon(Icons.edit_calendar_outlined),
                    onTap: () async {
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: selectedDate,
                        firstDate: DateTime(2020),
                        lastDate: DateUtils.dateOnly(DateTime.now()),
                      );
                      if (picked != null) onDateChanged(picked);
                    },
                  ),
                ),
                const SizedBox(height: 12),
                _ParentMapPanel(
                  key: ValueKey(
                      'map-${child.id}-${selectedDate.year}-${selectedDate.month}-${selectedDate.day}'),
                  busId: busId,
                  childName: name,
                  date: selectedDate,
                  pickup: _coordinate(
                      child.data['pickupLat'], child.data['pickupLng']),
                  drop:
                      _coordinate(child.data['dropLat'], child.data['dropLng']),
                  studentId: child.id,
                  routePoints: _historyPoints(child.data['routeGeometry']),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// One boarding or alighting card tap of the child (with the bus GPS point).
class _ChildTap {
  const _ChildTap(
      {required this.boarding, required this.position, required this.time});
  final bool boarding;
  final LatLng? position;
  final DateTime? time;
}

class _TripInfo {
  const _TripInfo(
      this.id, this.startedAt, this.endedAt, this.status, this.tripNo);
  final String id;
  final DateTime startedAt;
  final DateTime? endedAt;
  final String status;
  final int? tripNo;
}

String _hm(DateTime time) {
  final local = time.toLocal();
  return '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
}

List<LatLng> _historyPoints(dynamic raw) {
  final out = <LatLng>[];
  if (raw is List) {
    for (final item in raw) {
      if (item is Map) {
        final p = _coordinate(item['lat'], item['lng']);
        if (p != null) out.add(p);
      }
    }
  }
  return out;
}

/// The map a parent sees for one child and one day.
///
/// Always shows the child's pickup and drop points. Then:
///  * today and the bus is on a trip: the live bus position and the path
///    driven so far (refreshed every 30 seconds);
///  * otherwise: the road the bus drove on the finished trip.
class _ParentMapPanel extends StatefulWidget {
  const _ParentMapPanel({
    super.key,
    required this.busId,
    required this.childName,
    required this.date,
    required this.pickup,
    required this.drop,
    required this.studentId,
    required this.routePoints,
  });
  final String? busId;
  final String childName;
  final DateTime date;
  final LatLng? pickup;
  final LatLng? drop;
  final String studentId;
  final List<LatLng> routePoints; // planned road of the bus

  @override
  State<_ParentMapPanel> createState() => _ParentMapPanelState();
}

class _ParentMapPanelState extends State<_ParentMapPanel> {
  // Live bus (today only).
  Map<String, dynamic>? _location;
  Object? _liveError;
  bool _liveLoading = true;
  bool _liveBusy = false;
  Timer? _timer;

  // Where the child actually boarded / got off (card taps of the day).
  List<_ChildTap> _taps = const [];
  bool _tapsBusy = false;
  int _tapTick = 0;

  // Finished trips.
  List<_TripInfo> _trips = const [];
  bool _tripsLoaded = false;
  bool _tripsLoading = false;
  Object? _tripsError;
  String? _selectedTripId;
  final Map<String, List<LatLng>> _paths = {};
  bool _pathLoading = false;
  Object? _pathError;

  // Trip state (used to tell "GPS delayed" apart from "trip finished").
  bool _hasActiveTrip = false;
  bool _tripEnded = false;

  bool get _isToday => DateUtils.isSameDay(widget.date, DateTime.now());

  _TripInfo? get _selectedTrip {
    for (final trip in _trips) {
      if (trip.id == _selectedTripId) return trip;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    if (_isToday) {
      _refreshLive();
      _timer = Timer.periodic(const Duration(seconds: 30), (_) {
        _refreshLive();
        // Taps change rarely: reload them every 2 minutes (saves reads).
        if (++_tapTick % 4 == 0) _loadTaps();
      });
    } else {
      _liveLoading = false;
      _loadTrips();
    }
    _loadTaps();
  }

  Future<void> _loadTaps() async {
    final studentId = widget.studentId;
    if (studentId.isEmpty || _tapsBusy) return;
    _tapsBusy = true;
    try {
      final d = widget.date;
      final dateText = '${d.year.toString().padLeft(4, '0')}-'
          '${d.month.toString().padLeft(2, '0')}-'
          '${d.day.toString().padLeft(2, '0')}';
      final result = await callWithFreshSession(
              'getParentChildTaps', {'studentId': studentId, 'date': dateText})
          .timeout(const Duration(seconds: 20));
      final data = result.data;
      final raw = data is Map ? data['taps'] : null;
      final taps = <_ChildTap>[];
      if (raw is List) {
        for (final item in raw) {
          if (item is! Map) continue;
          taps.add(_ChildTap(
            boarding: item['mode'] != 'alighting',
            position: _coordinate(item['lat'], item['lng']),
            time: _parseTime(item['tappedAt']),
          ));
        }
      }
      if (!mounted) return;
      setState(() => _taps = taps);
    } catch (error, stackTrace) {
      developer.log('Parent child taps failed',
          name: 'rideguard.parent', error: error, stackTrace: stackTrace);
    } finally {
      _tapsBusy = false;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  // ------------------------------------------------------------- live

  bool _isStale(Map<String, dynamic> loc) {
    final t = _parseTime(loc['updatedAt']);
    return t == null || DateTime.now().difference(t).inMinutes >= 2;
  }

  Future<void> _refreshLive() async {
    final busId = widget.busId;
    if (busId == null || busId.isEmpty) {
      if (mounted) setState(() => _liveLoading = false);
      return;
    }
    if (_liveBusy) return; // never overlap two calls (saves reads)
    _liveBusy = true;
    try {
      final result =
          await callWithFreshSession('getParentLiveLocation', {'busId': busId})
              .timeout(const Duration(seconds: 20));
      final data = result.data;
      final raw = data is Map ? data['location'] : null;
      Map<String, dynamic>? location = raw is Map
          ? {for (final entry in raw.entries) entry.key.toString(): entry.value}
          : null;
      if (!mounted) return;

      // Old GPS fix: check whether the trip has really finished.
      var tripsFresh = false;
      if (location != null && _isStale(location)) {
        if (!_tripsLoaded || !_tripEnded) {
          tripsFresh = true;
          await _loadTrips();
          if (!mounted) return;
        }
        _tripEnded = !_hasActiveTrip && _trips.isNotEmpty;
        if (_tripEnded) location = null; // trip stopped -> show its route
      } else {
        _tripEnded = false;
      }

      final hadLive = _location != null;
      setState(() {
        _location = location;
        _liveError = null;
        _liveLoading = false;
      });
      // No active trip: show the finished trip's route instead. Reload it
      // once when a trip has just ended.
      if (location == null && !tripsFresh && (hadLive || !_tripsLoaded)) {
        _tripsLoaded = false;
        _selectedTripId = null;
        unawaited(_loadTrips());
      }
    } catch (error, stackTrace) {
      developer.log('Parent live location failed',
          name: 'rideguard.parent', error: error, stackTrace: stackTrace);
      if (mounted) {
        setState(() {
          _liveError = error;
          _liveLoading = false;
        });
      }
      if (!_tripsLoaded) unawaited(_loadTrips());
    } finally {
      _liveBusy = false;
    }
  }

  // ---------------------------------------------------- finished trips

  Future<QuerySnapshot<Map<String, dynamic>>> _queryTrips(
      String uid, String busId) async {
    final base = FirebaseFirestore.instance
        .collection('trips')
        .where('parentIds', arrayContains: uid)
        .where('busId', isEqualTo: busId);
    final dayStart =
        DateTime(widget.date.year, widget.date.month, widget.date.day);
    final dayEnd = dayStart.add(const Duration(days: 1));
    try {
      return await base
          .where('startedAt',
              isGreaterThanOrEqualTo: Timestamp.fromDate(dayStart))
          .where('startedAt', isLessThan: Timestamp.fromDate(dayEnd))
          .get();
    } on FirebaseException catch (error) {
      if (error.code != 'failed-precondition') rethrow;
      // The day index is not deployed yet: use the wider query and filter
      // on the phone. Works, but reads more documents.
      developer.log('Trips day index missing; using wider query',
          name: 'rideguard.parent');
      return base.get();
    }
  }

  Future<void> _loadTrips() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    final busId = widget.busId;
    if (uid == null || busId == null || busId.isEmpty) {
      if (mounted) setState(() => _tripsLoaded = true);
      return;
    }
    if (_tripsLoading) return;
    if (mounted) {
      setState(() {
        _tripsLoading = true;
        _tripsError = null;
      });
    }
    try {
      final snapshot =
          await _queryTrips(uid, busId).timeout(const Duration(seconds: 25));
      final trips = <_TripInfo>[];
      var hasActive = false;
      for (final doc in snapshot.docs) {
        final data = doc.data();
        final started = _parseTime(data['startedAt']);
        if (started == null ||
            !DateUtils.isSameDay(started.toLocal(), widget.date)) {
          continue;
        }
        final status = data['status']?.toString() ?? '';
        if (status == 'active') {
          // shown live, not as a route
          hasActive = true;
          continue;
        }
        trips.add(_TripInfo(
          doc.id,
          started,
          _parseTime(data['endedAt']),
          status,
          (data['tripNo'] as num?)?.toInt(),
        ));
      }
      trips.sort((a, b) => a.startedAt.compareTo(b.startedAt));
      if (!mounted) return;
      setState(() {
        _hasActiveTrip = hasActive;
        _trips = trips;
        _tripsLoaded = true;
        _tripsLoading = false;
        _selectedTripId = trips.isEmpty ? null : trips.last.id;
      });
      final selected = _selectedTripId;
      if (selected != null) unawaited(_loadPath(selected));
    } catch (error, stackTrace) {
      developer.log('Parent trips load failed',
          name: 'rideguard.parent', error: error, stackTrace: stackTrace);
      if (mounted) {
        setState(() {
          _tripsError = error;
          _tripsLoaded = true;
          _tripsLoading = false;
        });
      }
    }
  }

  Future<void> _loadPath(String tripId) async {
    if (_paths.containsKey(tripId)) {
      if (mounted) setState(() => _pathError = null);
      return;
    }
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    if (mounted) {
      setState(() {
        _pathLoading = true;
        _pathError = null;
      });
    }
    try {
      // The parentIds filter is what lets the security rules allow this read.
      final snapshot = await FirebaseFirestore.instance
          .collection('trips')
          .doc(tripId)
          .collection('locations')
          .where('parentIds', arrayContains: uid)
          .get()
          .timeout(const Duration(seconds: 25));
      final docs = snapshot.docs.toList()
        ..sort((a, b) {
          final left = _parseTime(a.data()['updatedAt']);
          final right = _parseTime(b.data()['updatedAt']);
          if (left != null && right != null) {
            final byTime = left.compareTo(right);
            if (byTime != 0) return byTime;
          }
          return a.id.compareTo(b.id); // ids end with the capture time
        });
      final points = [
        for (final doc in docs)
          if (doc.data()['lat'] is num && doc.data()['lng'] is num)
            LatLng((doc.data()['lat'] as num).toDouble(),
                (doc.data()['lng'] as num).toDouble()),
      ];
      if (!mounted) return;
      setState(() {
        _paths[tripId] = points;
        _pathLoading = false;
      });
    } catch (error, stackTrace) {
      developer.log('Parent trip path failed',
          name: 'rideguard.parent', error: error, stackTrace: stackTrace);
      if (mounted) {
        setState(() {
          _pathError = error;
          _pathLoading = false;
        });
      }
    }
  }

  void _retry() {
    setState(() {
      _liveError = null;
      _tripsError = null;
      _pathError = null;
      _tripsLoaded = false;
    });
    if (_isToday) {
      setState(() => _liveLoading = true);
      _refreshLive();
    } else {
      _loadTrips();
    }
  }

  // ------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final busId = widget.busId;
    final hasBus = busId != null && busId.isNotEmpty;
    final live = _isToday ? _location : null;
    final selected = _selectedTrip;
    final path = selected == null ? null : _paths[selected.id];

    // ---- what to draw ----
    final paths = <MapPath>[];
    final markers = <MapMarker>[];
    final allPoints = <LatLng>[]; // everything that must be visible
    var note = '';
    var endedRoute = false;

    // The planned road of the bus (drawn first so the driven path is on top).
    if (widget.routePoints.length > 1) {
      paths.add(MapPath(widget.routePoints, Colors.indigo.shade300));
      allPoints.addAll(widget.routePoints);
      markers.add(MapMarker(widget.routePoints.last, Colors.red, Icons.school,
          label: 'School'));
    }

    if (live != null) {
      final position = _coordinate(live['lat'], live['lng']);
      final history = _historyPoints(live['history']);
      if (history.isNotEmpty) {
        paths.add(MapPath(history, Colors.blue));
        allPoints.addAll(history);
      }
      if (position != null) {
        markers.add(MapMarker(position, Colors.green, Icons.directions_bus,
            label: 'Bus'));
        allPoints.add(position);
      }
      note = history.isEmpty
          ? 'No GPS points saved yet for this trip.'
          : '${history.length} saved GPS points displayed.';
    } else if (selected != null && path != null && path.isNotEmpty) {
      endedRoute = true;
      final pathColor = selected.startedAt.toLocal().hour < 12
          ? Colors.blue
          : Colors.orange.shade800;
      paths.add(MapPath(path, pathColor));
      markers.add(MapMarker(path.first, Colors.green, Icons.play_circle_fill,
          label: 'Start'));
      markers.add(
          MapMarker(path.last, Colors.red, Icons.stop_circle, label: 'End'));
      allPoints.addAll(path);
      note = '${path.length} GPS points on this route.';
    }
    if (widget.pickup != null) {
      markers.add(MapMarker(widget.pickup!, Colors.blue, Icons.trip_origin,
          label: 'Pickup'));
      allPoints.add(widget.pickup!);
    }
    if (widget.drop != null) {
      markers.add(MapMarker(widget.drop!, Colors.deepOrange, Icons.flag,
          label: 'Drop'));
      allPoints.add(widget.drop!);
    }
    // Where the child really boarded / got off (from the card taps).
    for (final tap in _taps) {
      final point = tap.position;
      if (point == null) continue;
      final time = tap.time == null ? '' : ' ${_hm(tap.time!)}';
      markers.add(MapMarker(point, tap.boarding ? Colors.green : Colors.red,
          tap.boarding ? Icons.login : Icons.logout,
          label: tap.boarding ? 'Boarded$time' : 'Got off$time'));
      allPoints.add(point);
    }
    // Centre on the route and the pickup/drop points together.
    final LatLng? center = _boundsCenter(allPoints);

    // ---- status card ----
    IconData icon = Icons.info_outline;
    Color? color;
    String title;
    String subtitle;
    Widget? trailing;

    if (!hasBus) {
      title = '${widget.childName} has no assigned bus';
      subtitle = 'Pickup and drop points are shown below.';
    } else if (_isToday && _liveLoading) {
      icon = Icons.hourglass_empty;
      title = 'Checking the bus...';
      subtitle = 'Looking for the live location.';
    } else if (live != null) {
      final updatedAt = _parseTime(live['updatedAt']);
      final stale = updatedAt == null ||
          DateTime.now().difference(updatedAt).inMinutes >= 2;
      icon = stale ? Icons.warning_amber : Icons.gps_fixed;
      color = stale ? Colors.orange : Colors.green;
      title = stale ? 'GPS update delayed' : 'Bus is on its trip';
      subtitle = updatedAt == null
          ? 'Waiting for a saved GPS timestamp'
          : 'Last update: ${nowText(updatedAt)}';
    } else if (_isToday && _liveError != null && !_tripsLoaded) {
      icon = Icons.error_outline;
      title = 'Unable to load live GPS';
      subtitle = _friendly(_liveError!);
      trailing = IconButton(
          onPressed: _retry, icon: const Icon(Icons.refresh), tooltip: 'Retry');
    } else if (_tripsLoading || !_tripsLoaded) {
      icon = Icons.hourglass_empty;
      title = 'Loading the trip route...';
      subtitle = 'Please wait.';
    } else if (_tripsError != null) {
      icon = Icons.error_outline;
      title = 'Unable to load the trip route';
      subtitle = _friendly(_tripsError!);
      trailing = IconButton(
          onPressed: _retry, icon: const Icon(Icons.refresh), tooltip: 'Retry');
    } else if (selected == null) {
      title = _isToday ? 'Bus is not on a trip' : 'No trip on this day';
      subtitle = _isToday
          ? 'The live location appears here when the trip starts.'
          : 'No trip was recorded for this day.';
    } else {
      icon = Icons.check_circle_outline;
      color = Colors.blueGrey;
      title = 'Trip ended';
      final ended = selected.endedAt;
      subtitle = 'Started ${_hm(selected.startedAt)}'
          '${ended == null ? '' : '  •  Ended ${_hm(ended)}'}';
      if (_pathLoading) {
        subtitle = '$subtitle\nLoading the route...';
      } else if (_pathError != null) {
        subtitle = '$subtitle\nThe route path is not available.';
      } else if (path != null && path.isEmpty) {
        subtitle = '$subtitle\nNo GPS points were saved for this trip.';
      }
    }

    final hasMap = center != null || markers.isNotEmpty || paths.isNotEmpty;
    final mapKey =
        '${live != null ? 'live' : 'trip-${_selectedTripId ?? 'none'}-${path?.length ?? 0}'}'
        '-t${_taps.length}';

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Card(
        child: ListTile(
          leading: Icon(icon, color: color),
          title: Text(title),
          subtitle: Text(subtitle),
          isThreeLine: subtitle.contains('\n'),
          trailing: trailing,
        ),
      ),
      if (live == null && _trips.length > 1)
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 4),
          child: Wrap(spacing: 8, runSpacing: 4, children: [
            for (var i = 0; i < _trips.length; i++)
              ChoiceChip(
                label: Text(
                    'Trip ${_trips[i].tripNo ?? i + 1} · ${_hm(_trips[i].startedAt)}'),
                selected: _trips[i].id == _selectedTripId,
                onSelected: (_) {
                  setState(() => _selectedTripId = _trips[i].id);
                  _loadPath(_trips[i].id);
                },
              ),
          ]),
        ),
      const SizedBox(height: 8),
      if (hasMap)
        KeyedSubtree(
          key: ValueKey(mapKey),
          child: RealMap(
            height: 340,
            initialCenter: center,
            paths: paths,
            markers: markers,
          ),
        )
      else
        const SizedBox(
            height: 120,
            child: Center(child: Text('No location is available yet.'))),
      const SizedBox(height: 8),
      if (note.isNotEmpty) Text(note),
      if (endedRoute)
        const Text('Blue: morning trip  •  Orange: afternoon trip',
            style: TextStyle(fontSize: 12)),
      if (widget.routePoints.length > 1)
        const Text('Light indigo line: planned bus route',
            style: TextStyle(fontSize: 12)),
    ]);
  }
}

class CalendarPage extends StatelessWidget {
  const CalendarPage({super.key});

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null)
      return const Center(child: Text('Sign in to view trip history.'));
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('trips')
          .where('parentIds', arrayContains: uid)
          .snapshots(),
      builder: (context, snapshot) {
        final tripDays = <String>{};
        for (final document in snapshot.data?.docs ?? const []) {
          final value = document.data()['startedAt'];
          if (value is Timestamp) {
            final date = value.toDate();
            tripDays.add('${date.year}-${date.month}-${date.day}');
          }
        }
        return _calendar(context, tripDays);
      },
    );
  }

  Widget _calendar(BuildContext context, Set<String> tripDays) {
    final now = DateTime.now();
    final first = DateTime(now.year, now.month, 1);
    final days = DateUtils.getDaysInMonth(now.year, now.month);
    final offset = first.weekday % 7; // Sunday first
    const names = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December'
    ];
    final s = Theme.of(context).colorScheme;
    bool hasTrip(int d) {
      return tripDays.contains('${now.year}-${now.month}-$d');
    }

    return ListView(padding: const EdgeInsets.all(16), children: [
      Text('${names[now.month - 1]} ${now.year}',
          style: Theme.of(context).textTheme.headlineSmall),
      const Text('Days with trips are highlighted. Tap a day for details.'),
      const SizedBox(height: 12),
      Row(children: [
        for (final d in ['S', 'M', 'T', 'W', 'T', 'F', 'S'])
          Expanded(
              child: Center(
                  child: Text(d,
                      style: const TextStyle(fontWeight: FontWeight.w700))))
      ]),
      const SizedBox(height: 4),
      GridView.count(
        crossAxisCount: 7,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        children: [
          for (var i = 0; i < offset; i++) const SizedBox.shrink(),
          for (var d = 1; d <= days; d++)
            Padding(
              padding: const EdgeInsets.all(3),
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: hasTrip(d)
                    ? () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) =>
                            DayScreen(date: DateTime(now.year, now.month, d))))
                    : null,
                child: Container(
                  decoration: BoxDecoration(
                    color: hasTrip(d) ? s.primaryContainer : null,
                    borderRadius: BorderRadius.circular(10),
                    border: d == now.day
                        ? Border.all(color: s.primary, width: 2)
                        : null,
                  ),
                  child: Center(
                    child: Text('$d',
                        style: TextStyle(
                            fontWeight:
                                hasTrip(d) ? FontWeight.w700 : FontWeight.w400,
                            color: hasTrip(d)
                                ? s.onPrimaryContainer
                                : s.onSurface.withAlpha(120))),
                  ),
                ),
              ),
            ),
        ],
      ),
    ]);
  }
}

class DayScreen extends StatelessWidget {
  const DayScreen({super.key, required this.date});
  final DateTime date;

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      return const Scaffold(
          body: Center(child: Text('Sign in to view trip history.')));
    }
    final morning = Colors.blue.shade700;
    final afternoon = Colors.orange.shade800;
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('trips')
          .where('parentIds', arrayContains: uid)
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Scaffold(
              body: Center(
                  child: const Text('Unable to load trips. Please retry.')));
        }
        if (!snapshot.hasData) {
          return const Scaffold(
              body: Center(child: CircularProgressIndicator()));
        }
        final trips = snapshot.data!.docs.where((trip) {
          final started = trip.data()['startedAt'];
          return started is Timestamp &&
              started.toDate().year == date.year &&
              started.toDate().month == date.month &&
              started.toDate().day == date.day;
        }).toList()
          ..sort((a, b) {
            final left = (a.data()['startedAt'] as Timestamp).toDate();
            final right = (b.data()['startedAt'] as Timestamp).toDate();
            return left.compareTo(right);
          });
        return Scaffold(
          appBar: AppBar(title: Text('${date.day}/${date.month}/${date.year}')),
          body: ListView(padding: const EdgeInsets.all(16), children: [
            if (trips.isEmpty)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('No trips were recorded for this day.'),
                ),
              ),
            for (final trip in trips)
              Card(
                child: Column(children: [
                  ListTile(
                      leading: Icon(Icons.wb_sunny, color: morning),
                      title: Text('Trip ${trip.id}'),
                      subtitle:
                          Text('Started ${_time(trip.data()['startedAt'])}\n'
                              'Status: ${trip.data()['status'] ?? 'unknown'}'),
                      isThreeLine: true),
                ]),
              ),
            const SizedBox(height: 12),
            const SizedBox(
              height: 140,
              child: Center(
                  child: Text(
                      'Trip map is available when GPS trip history is recorded.')),
            ),
            const SizedBox(height: 8),
            Row(children: [
              Container(width: 22, height: 6, color: morning),
              const SizedBox(width: 8),
              const Text('To school'),
              const SizedBox(width: 24),
              Container(width: 22, height: 6, color: afternoon),
              const SizedBox(width: 8),
              const Text('Back home'),
            ]),
            const SizedBox(height: 4),
            const Text(
                'Different colours show the same road used in each direction.'),
          ]),
        );
      },
    );
  }

  String _time(dynamic value) =>
      value is Timestamp ? nowText(value.toDate()) : 'time unavailable';
}

class NotifSettingsPage extends StatefulWidget {
  const NotifSettingsPage({super.key});
  @override
  State<NotifSettingsPage> createState() => _NotifSettingsPageState();
}

class _NotifSettingsPageState extends State<NotifSettingsPage> {
  final Map<String, bool> on = {
    'Trip started': true,
    'Child boarded': true,
    'Child got off': true,
    'Trip ended': true,
    'Delay': true,
  };

  @override
  Widget build(BuildContext context) {
    return ListView(padding: const EdgeInsets.all(16), children: [
      Text('Notification settings',
          style: Theme.of(context).textTheme.headlineSmall),
      const Text('Mute the types you do not want.'),
      const SizedBox(height: 8),
      for (final e in on.entries)
        SwitchListTile(
          title: Text(e.key),
          value: e.value,
          onChanged: (v) async {
            setState(() => on[e.key] = v);
            final uid = FirebaseAuth.instance.currentUser?.uid;
            if (uid == null) return;
            await FirebaseFirestore.instance.collection('users').doc(uid).set({
              'notificationPreferences': {
                e.key.toLowerCase().replaceAll(' ', '_'): v,
              },
            }, SetOptions(merge: true));
          },
        ),
    ]);
  }
}
