import 'package:flutter_test/flutter_test.dart';

import 'package:rideguard/app_models.dart';

// All records in this file are synthetic test fixtures.

void main() {
  test('on-board state counts each student once and removes alighted students',
      () {
    final state = calculateOnBoardState([
      {'studentId': 'student-1', 'mode': 'boarding'},
      {'studentId': 'student-1', 'mode': 'boarding'},
      {'studentId': 'student-2', 'mode': 'boarding'},
      {'studentId': 'student-1', 'mode': 'alighting'},
    ]);

    expect(state.hasBoarding, isTrue);
    expect(state.studentIds, {'student-2'});
    expect(state.count, 1);
  });

  test('alighting without boarding does not create an on-board student', () {
    final state = calculateOnBoardState([
      {'studentId': 'student-1', 'mode': 'alighting'},
    ]);

    expect(state.hasBoarding, isFalse);
    expect(state.studentIds, isEmpty);
    expect(state.allStudentIds, {'student-1'});
    expect(state.alightedIds, {'student-1'});
  });

  test(
      'trip student state keeps alighted students without leaking other bus students',
      () {
    final state = calculateOnBoardState([
      {'studentId': 'current-1', 'mode': 'boarding', 'tappedAt': 1},
      {'studentId': 'current-1', 'mode': 'alighting', 'tappedAt': 2},
      {'studentId': 'current-2', 'mode': 'boarding', 'tappedAt': 3},
    ]);

    expect(state.allStudentIds, {'current-1', 'current-2'});
    expect(state.alightedIds, {'current-1'});
    expect(state.studentIds, {'current-2'});
  });

  test('trip state requires a selected route to start in the UI model', () {
    final trip = Trip.I;
    trip.clear();
    expect(trip.routeSelected, isFalse);
    trip.selectRoute('route-1');
    expect(trip.routeSelected, isTrue);
    trip.update(
      active: true,
      tripId: 'trip-1',
      routeId: 'route-1',
      busId: 'bus-1',
      capacity: 50,
      onBoard: <String>{},
    );
    expect(trip.active, isTrue);
    trip.clear();
    expect(trip.active, isFalse);
  });
}
