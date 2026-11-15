import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

final routeRepositoryProvider = Provider<RouteRepository>((ref) {
  return RouteRepository(FirebaseFirestore.instance);
});

final routesProvider = StreamProvider<List<BusRoute>>((ref) {
  return ref.watch(routeRepositoryProvider).watchRoutes();
});

bool isActiveRouteData(Map<String, dynamic> data) =>
    data['deleted'] != true && data['enabled'] != false;

class BusStop {
  const BusStop({
    required this.name,
    required this.position,
    required this.order,
    this.isSchool = false,
  });

  final String name;
  final LatLng position;
  final int order;
  final bool isSchool;

  Map<String, dynamic> toMap() => {
        'name': name,
        'lat': position.latitude,
        'lng': position.longitude,
        'order': order,
        'isSchool': isSchool,
      };

  factory BusStop.fromMap(Map<String, dynamic> data) => BusStop(
        name: data['name'] as String? ?? 'Stop',
        position: LatLng(
          (data['lat'] as num).toDouble(),
          (data['lng'] as num).toDouble(),
        ),
        order: (data['order'] as num?)?.toInt() ?? 0,
        isSchool: data['isSchool'] == true,
      );
}

class BusRoute {
  const BusRoute({
    required this.id,
    required this.name,
    required this.stops,
    required this.geometry,
    this.busId,
    this.parentIds = const [],
  });

  final String id;
  final String name;
  final List<BusStop> stops;
  final List<LatLng> geometry;
  final String? busId;
  final List<String> parentIds;

  factory BusRoute.fromDocument(
    DocumentSnapshot<Map<String, dynamic>> document,
  ) {
    final data = document.data() ?? const <String, dynamic>{};
    final rawStops = data['stops'] is List ? data['stops'] as List : const [];
    final rawGeometry =
        data['geometry'] is List ? data['geometry'] as List : const [];
    return BusRoute(
      id: document.id,
      name: data['name'] as String? ?? 'Unnamed route',
      busId: data['busId'] as String?,
      parentIds:
          (data['parentIds'] as List? ?? const []).whereType<String>().toList(),
      stops: rawStops
          .whereType<Map>()
          .map((item) => BusStop.fromMap(Map<String, dynamic>.from(item)))
          .toList()
        ..sort((a, b) => a.order.compareTo(b.order)),
      geometry: rawGeometry
          .whereType<Map>()
          .map((item) => LatLng(
                (item['lat'] as num).toDouble(),
                (item['lng'] as num).toDouble(),
              ))
          .toList(),
    );
  }

}

class RouteRepository {
  RouteRepository(this._firestore);
  final FirebaseFirestore _firestore;

  Stream<List<BusRoute>> watchRoutes() {
    return _firestore.collection('routes').snapshots().map(
          (snapshot) => snapshot.docs
              .where((document) => isActiveRouteData(document.data()))
              .map(BusRoute.fromDocument)
              .toList(),
        );
  }

  Future<void> saveRoute({
    String? routeId,
    required String name,
    required List<BusStop> stops,
    required List<LatLng> geometry,
    String? busId,
  }) async {
    if (name.trim().isEmpty || stops.length < 2 || geometry.length < 2) {
      throw ArgumentError(
          'A route needs a name, two stops, and route geometry.');
    }
    final data = {
      'name': name.trim(),
      'deleted': false,
      'enabled': true,
      'stops': [for (final stop in stops) stop.toMap()],
      'geometry': [
        for (final point in geometry)
          {'lat': point.latitude, 'lng': point.longitude},
      ],
      if (busId != null) 'busId': busId,
      if (routeId == null) 'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    };
    final ref = routeId == null
        ? _firestore.collection('routes').doc()
        : _firestore.collection('routes').doc(routeId);
    await ref.set(data, SetOptions(merge: true));
  }
}
