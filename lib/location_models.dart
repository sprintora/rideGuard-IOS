import 'package:latlong2/latlong.dart';

class SchoolSearchResult {
  const SchoolSearchResult({
    required this.name,
    required this.location,
  });

  final String name;
  final LatLng location;
}

SchoolSearchResult? parseSchoolSearchResult(Map<String, dynamic> data) {
  final lat = double.tryParse(data['lat']?.toString() ?? '');
  final lng = double.tryParse(data['lon']?.toString() ?? '');
  if (lat == null || lng == null) return null;
  return SchoolSearchResult(
    name: data['display_name']?.toString() ?? 'Unnamed result',
    location: LatLng(lat, lng),
  );
}

bool hasRequiredSchoolLocation(String name, LatLng? location) =>
    name.trim().isNotEmpty && location != null;

enum LiveLocationState { loading, error, notOnTrip, stale, live }

LiveLocationState classifyLiveLocation({
  required bool loading,
  Object? error,
  required String? tripId,
  required DateTime? updatedAt,
  DateTime? now,
}) {
  if (loading) return LiveLocationState.loading;
  if (error != null) return LiveLocationState.error;
  if (tripId == null || tripId.isEmpty) return LiveLocationState.notOnTrip;
  final timestamp = updatedAt;
  if (timestamp == null ||
      (now ?? DateTime.now()).difference(timestamp).inMinutes >= 2) {
    return LiveLocationState.stale;
  }
  return LiveLocationState.live;
}
