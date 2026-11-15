import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rideguard/admin.dart';
import 'package:rideguard/firestore_repository.dart';
import 'package:rideguard/main.dart';
import 'package:rideguard/widgets.dart';
import 'package:latlong2/latlong.dart';
import 'package:rideguard/location_models.dart';
import 'package:rideguard/route_repository.dart';
import 'package:rideguard/forms.dart';

void main() {
  testWidgets('login screen shows', (tester) async {
    await tester.pumpWidget(const RideGuardUi());
    expect(find.text('Log in'), findsOneWidget);
  });

  testWidgets('list displays the Firestore name', (tester) async {
    final stream = Stream<List<FirestoreRecord>>.fromIterable([
      [
        const FirestoreRecord('school-1', {'name': 'Central School'})
      ],
    ]);
    await tester.pumpWidget(_list(stream));
    await tester.pump();
    await tester.pump();
    expect(find.text('Central School'), findsOneWidget);
  });

  testWidgets('list uses an entity fallback when the name is missing',
      (tester) async {
    final stream = Stream<List<FirestoreRecord>>.fromIterable([
      [const FirestoreRecord('school-1', {})],
    ]);
    await tester.pumpWidget(_list(stream));
    await tester.pump();
    await tester.pump();
    expect(find.text('Unnamed school'), findsOneWidget);
    expect(find.text('school-1'), findsNothing);
  });

  testWidgets('list shows a friendly stream error', (tester) async {
    final stream = Stream<List<FirestoreRecord>>.error(
        StateError('permission-denied: schools'));
    await tester.pumpWidget(_list(stream));
    await tester.pump();
    expect(find.text('Unable to load records'), findsOneWidget);
  });

  testWidgets('list updates when a new snapshot arrives', (tester) async {
    final controller = StreamController<List<FirestoreRecord>>();
    addTearDown(controller.close);
    await tester.pumpWidget(_list(controller.stream));
    controller.add([
      const FirestoreRecord('school-1', {'name': 'First School'}),
    ]);
    await tester.pump();
    await tester.pump();
    expect(find.text('First School'), findsOneWidget);
    controller.add([
      const FirestoreRecord('school-2', {'name': 'Second School'}),
    ]);
    await tester.pump();
    await tester.pump();
    expect(find.text('Second School'), findsOneWidget);
    expect(find.text('First School'), findsNothing);
  });

  testWidgets('real map renders a live-coordinate marker', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: RealMap(
          initialCenter: LatLng(7.2513, 80.3464),
          markers: [
            MapMarker(
              LatLng(7.2513, 80.3464),
              Colors.green,
              Icons.directions_bus,
              label: 'Bus 1',
            ),
          ],
        ),
      ),
    ));
    expect(find.byType(RealMap), findsOneWidget);
    expect(find.text('Bus 1'), findsOneWidget);
  });

  testWidgets('route point naming closes without layout or disposal errors',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: RoutesPage(routeStream: Stream.value(const <BusRoute>[])),
    ));
    await tester.tap(find.text('Add route'));
    await tester.pumpAndSettle();
    expect(find.text('Tap the map to add a named start, end, or destination.'),
        findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: RoutePointNameDialog(stopNumber: 1),
      ),
    ));
    await tester.enterText(find.byType(TextField), 'School gate');
    await tester.tap(find.text('Add point'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('route point form fits a narrow 320 pixel width', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: RoutesPage(routeStream: Stream.value(const <BusRoute>[])),
    ));
    await tester.tap(find.text('Add route'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  test('school search results and required location validation', () {
    final result = parseSchoolSearchResult({
      'display_name': 'Central School, Kegalle',
      'lat': '7.2513',
      'lon': '80.3464',
    });
    expect(result?.name, 'Central School, Kegalle');
    expect(result?.location, const LatLng(7.2513, 80.3464));
    expect(
        hasRequiredSchoolLocation('Central School', result?.location), isTrue);
    expect(hasRequiredSchoolLocation('Central School', null), isFalse);
    expect(hasRequiredSchoolLocation('', result?.location), isFalse);
  });

  test('live map state covers live, stale, not-on-trip, and errors', () {
    final now = DateTime(2026, 11, 8, 12);
    expect(
      classifyLiveLocation(
        loading: false,
        tripId: 'trip-1',
        updatedAt: now,
        now: now,
      ),
      LiveLocationState.live,
    );
    expect(
      classifyLiveLocation(
        loading: false,
        tripId: 'trip-1',
        updatedAt: now.subtract(const Duration(minutes: 2)),
        now: now,
      ),
      LiveLocationState.stale,
    );
    expect(
      classifyLiveLocation(
        loading: false,
        tripId: null,
        updatedAt: null,
        now: now,
      ),
      LiveLocationState.notOnTrip,
    );
    expect(
      classifyLiveLocation(
        loading: false,
        error: StateError('permission-denied'),
        tripId: null,
        updatedAt: null,
        now: now,
      ),
      LiveLocationState.error,
    );
  });

  test('notification unread state is based on the signed-in parent', () {
    const unread = FirestoreRecord('n1', {'title': 'Boarded'});
    const read = FirestoreRecord('n2', {
      'title': 'Boarded',
      'readBy': {'parent-1': 'server-time'},
    });

    expect(isNotificationUnread(unread, 'parent-1'), isTrue);
    expect(isNotificationUnread(read, 'parent-1'), isFalse);
    expect(isNotificationUnread(read, 'other-parent'), isTrue);
  });

  test('student card assignment keeps the printed eight-character number', () {
    expect(formatRideGuardCardNumber('ab12cd34'), 'AB-12-CD-34');
    expect(isRideGuardCardId('AB-12-CD-34'), isTrue);
    expect(isRideGuardCardId('ABCD2345EFGH6789'), isFalse);
  });

  test('deleted routes are excluded from selectable route data', () {
    expect(isActiveRouteData({'name': 'Morning'}), isTrue);
    expect(isActiveRouteData({'deleted': true}), isFalse);
    expect(isActiveRouteData({'enabled': false}), isFalse);
  });
}

Widget _list(Stream<List<FirestoreRecord>> stream) {
  return ProviderScope(
    overrides: [collectionProvider('schools').overrideWith((_) => stream)],
    child: MaterialApp(
      home: ListPage(title: 'Schools', collection: 'schools', rows: const []),
    ),
  );
}
