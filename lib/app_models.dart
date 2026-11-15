import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

enum Role { admin, driver, parent }

String roleName(Role role) => switch (role) {
      Role.admin => 'Administrator',
      Role.driver => 'Driver',
      Role.parent => 'Parent',
    };

String nowText([DateTime? value]) {
  final date = value ?? DateTime.now();
  final hour = date.hour % 12 == 0 ? 12 : date.hour % 12;
  return '$hour:${date.minute.toString().padLeft(2, '0')} '
      '${date.hour >= 12 ? 'PM' : 'AM'}';
}

class Student {
  Student(
    this.name,
    this.admission,
    this.grade,
    this.stop,
    this.card,
    this.parent, {
    this.drop = '',
  });

  final String name;
  final String admission;
  final String grade;
  final String stop;
  final String parent;
  final String drop;
  String card;
}

class TripEventState {
  const TripEventState({
    required this.studentIds,
    required this.allStudentIds,
    required this.alightedIds,
    required this.hasBoarding,
  });

  final Set<String> studentIds;
  final Set<String> allStudentIds;
  final Set<String> alightedIds;
  final bool hasBoarding;

  int get count => studentIds.length;
}

TripEventState calculateOnBoardState(Iterable<Map<String, dynamic>> events) {
  final sorted = events.toList()
    ..sort((a, b) {
      final time = _eventTime(a).compareTo(_eventTime(b));
      if (time != 0) return time;
      return _eventSequence(a).compareTo(_eventSequence(b));
    });
  final boarded = <String>{};
  final allStudents = <String>{};
  final alighted = <String>{};
  var hasBoarding = false;
  for (final event in sorted) {
    final studentId = event['studentId']?.toString();
    if (studentId == null || studentId.isEmpty) continue;
    allStudents.add(studentId);
    final mode = event['mode']?.toString().toLowerCase();
    if (mode == 'boarding' || mode == 'board') {
      hasBoarding = true;
      boarded.add(studentId);
    } else if (mode == 'alighting' || mode == 'alight') {
      boarded.remove(studentId);
      alighted.add(studentId);
    }
  }
  return TripEventState(
    studentIds: boarded,
    allStudentIds: allStudents,
    alightedIds: alighted,
    hasBoarding: hasBoarding,
  );
}

int _eventTime(Map<String, dynamic> event) {
  final value = event['tappedAt'];
  if (value is DateTime) return value.millisecondsSinceEpoch;
  if (value is Timestamp) return value.millisecondsSinceEpoch;
  if (value is num) return value.toInt();
  return 0;
}

int _eventSequence(Map<String, dynamic> event) =>
    (event['readerSequence'] as num?)?.toInt() ?? 0;

class Trip extends ChangeNotifier {
  Trip._();
  static final Trip I = Trip._();

  bool active = false;
  bool boarding = true;
  bool routeSelected = false;
  bool moduleConnected = false;
  bool manualMode = false;
  String? tripId;
  String? routeId;
  String? busId;
  int capacity = 0;
  int _tripNo = 0;
  Set<String> onBoard = <String>{};

  int get tripNo => _tripNo;

  void update({
    required bool active,
    required String? tripId,
    required String? routeId,
    required String? busId,
    required int capacity,
    required Set<String> onBoard,
    int tripNo = 0,
  }) {
    this.active = active;
    this.tripId = tripId;
    this.routeId = routeId;
    this.busId = busId;
    this.capacity = capacity;
    this.onBoard = onBoard;
    _tripNo = tripNo;
    routeSelected = routeId != null && routeId.isNotEmpty;
    notifyListeners();
  }

  void selectRoute(String id) {
    routeId = id;
    routeSelected = true;
    notifyListeners();
  }

  void setMode(bool isBoarding) {
    boarding = isBoarding;
    notifyListeners();
  }

  void connect(bool value) {
    moduleConnected = value;
    notifyListeners();
  }

  void clear() {
    manualMode = false;
    update(
      active: false,
      tripId: null,
      routeId: routeId,
      busId: busId,
      capacity: capacity,
      onBoard: <String>{},
    );
  }
}
