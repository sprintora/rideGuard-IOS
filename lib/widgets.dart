import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:async';
import 'dart:developer' as developer;
import 'package:flutter_map/flutter_map.dart' as map;
import 'package:latlong2/latlong.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'ui_theme.dart';
import 'core/input_rules.dart';
import 'cache_service.dart';
import 'auth_repository.dart';

final ValueNotifier<ThemeMode> themeMode = ValueNotifier(ThemeMode.system);
const _themePreferenceKey = 'rideguard.themeMode';

Future<void> loadThemeMode() async {
  final preferences = await SharedPreferences.getInstance();
  themeMode.value = switch (preferences.getString(_themePreferenceKey)) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };
}

Future<void> setThemeMode(ThemeMode mode) async {
  themeMode.value = mode;
  final preferences = await SharedPreferences.getInstance();
  await preferences.setString(
      _themePreferenceKey,
      switch (mode) {
        ThemeMode.light => 'light',
        ThemeMode.dark => 'dark',
        ThemeMode.system => 'system',
      });
}

ThemeData buildTheme(Brightness b) {
  return b == Brightness.dark ? RideTheme.darkTheme() : RideTheme.light();
}

void snack(BuildContext c, String m, {bool error = false, bool warn = false}) {
  final s = Theme.of(c).colorScheme;
  ScaffoldMessenger.of(c)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(m,
          style: TextStyle(
              color: error
                  ? s.onError
                  : (warn ? s.onSurface : s.onInverseSurface))),
      backgroundColor:
          error ? s.error : (warn ? Colors.amber : s.inverseSurface),
      behavior: SnackBarBehavior.floating,
    ));
}

String friendlyErrorMessage(Object error) {
  if (error is FirebaseFunctionsException) {
    return switch (error.code) {
      'unauthenticated' => 'Unable to verify your sign-in. Please try again.',
      'permission-denied' => "You don't have permission to do this.",
      'invalid-argument' => 'The information entered is invalid.',
      'unavailable' ||
      'deadline-exceeded' =>
        'No connection. Please try again.',
      _ => 'Unable to complete that action. Please try again.',
    };
  }
  if (error is FirebaseAuthException) {
    return switch (error.code) {
      'network-request-failed' => 'No connection. Please try again.',
      'invalid-credential' ||
      'wrong-password' ||
      'user-not-found' =>
        'Wrong phone number or NIC number / password.',
      'user-disabled' => 'This account is disabled.',
      _ => 'Unable to complete sign-in. Please try again.',
    };
  }
  if (error is FirebaseException) {
    return switch (error.code) {
      'permission-denied' => "You don't have permission to do this.",
      'profile-missing' =>
        'Your account is not fully set up. Contact your admin.',
      'unavailable' ||
      'deadline-exceeded' =>
        'No connection. Please try again.',
      _ => 'Unable to complete that action. Please try again.',
    };
  }
  final text = error.toString().toLowerCase();
  return text.contains('timeout') ||
          text.contains('network') ||
          text.contains('socketexception')
      ? 'No connection. Please try again.'
      : 'Unable to complete that action. Please try again.';
}

void snackError(BuildContext context, Object error, {String? prefix}) {
  developer.log(prefix ?? 'RideGuard operation failed',
      name: 'rideguard.ui', error: error);
  snack(context,
      '${prefix == null ? '' : '$prefix: '}${friendlyErrorMessage(error)}',
      error: true);
}

class RideGuardPasswordField extends StatefulWidget {
  const RideGuardPasswordField({
    super.key,
    required this.controller,
    this.decoration,
    this.validator,
    this.inputFormatters,
  });

  final TextEditingController controller;
  final InputDecoration? decoration;
  final String? Function(String?)? validator;
  final List<TextInputFormatter>? inputFormatters;

  @override
  State<RideGuardPasswordField> createState() => _RideGuardPasswordFieldState();
}

class _RideGuardPasswordFieldState extends State<RideGuardPasswordField> {
  bool _obscure = true;

  @override
  Widget build(BuildContext context) => TextFormField(
        controller: widget.controller,
        obscureText: _obscure,
        autocorrect: false,
        enableSuggestions: false,
        inputFormatters: widget.inputFormatters ?? const [],
        validator: widget.validator,
        decoration: (widget.decoration ?? const InputDecoration()).copyWith(
          suffixIcon: IconButton(
            tooltip: _obscure ? 'Show password' : 'Hide password',
            icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
            onPressed: () => setState(() => _obscure = !_obscure),
          ),
        ),
      );
}

Future<void> simpleForm(BuildContext c, String title, List<String> fields) {
  final ctrls = [for (final _ in fields) TextEditingController()];
  return showDialog<void>(
    context: c,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (var i = 0; i < fields.length; i++)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: TextField(
                controller: ctrls[i],
                inputFormatters: fields[i] == 'NIC number'
                    ? [NicInputFormatter()]
                    : null,
                decoration: InputDecoration(labelText: fields[i]),
              ),
            ),
        ]),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(
          onPressed: () async {
            final values = {
              for (var i = 0; i < fields.length; i++)
                fields[i]: sanitizeText(ctrls[i].text,
                    collapseSpaces: true),
            };
            final confirmed = await confirmAction(
              c,
              title: 'Confirm ${title.toLowerCase()}',
              message: 'Save these changes now?',
            );
            if (!confirmed || !ctx.mounted) return;
            Navigator.pop(ctx);
            final collection = switch (title) {
              'Add school' => 'schools',
              'Add bus' => 'buses',
              'Add driver' => 'users',
              'Add parent' => 'parents',
              _ => null,
            };
            if (collection == null) {
              snack(c, '$title is not supported.', error: true);
              return;
            }
            try {
              final normalized = <String, dynamic>{...values};
              if (collection == 'schools') {
                normalized['name'] = normalized.remove('School name');
                normalized['address'] = normalized.remove('Address');
                normalized['contactPhone'] = normalized.remove('Contact phone');
              } else if (collection == 'buses') {
                normalized['plate'] = normalized.remove('Number plate');
                final capacity = int.tryParse(
                    normalized.remove('Capacity')?.toString() ?? '');
                if (capacity != null) normalized['capacity'] = capacity;
              }
              if (collection == 'parents') {
                final name = sanitizeText(
                    normalized['Full name']?.toString() ?? '',
                    collapseSpaces: true);
                final phone = canonicalPhone(
                    normalized['Phone (login)']?.toString() ?? '');
                final nic = normalizeNic(
                    normalized['NIC number']?.toString() ?? '');
                if (fullNameError(name) != null ||
                    phone == null ||
                    nic == null) {
                  snack(c, nicError(normalized['NIC number']?.toString() ?? '') ??
                      'Enter a valid name, phone, and NIC number.',
                      error: true);
                  return;
                }
                await callWithFreshSession('createParentAccount', {
                  'fullName': name,
                  'phone': phone,
                  if ((normalized['Email (optional)'] as String).isNotEmpty)
                    'email':
                        sanitizeText(normalized['Email (optional)'] as String)
                            .toLowerCase(),
                  'nic': nic,
                });
              } else {
                await FirebaseFirestore.instance.collection(collection).add({
                  ...normalized,
                  if (collection == 'users') 'roles': ['driver'],
                  'enabled': true,
                  'createdAt': FieldValue.serverTimestamp(),
                  'updatedAt': FieldValue.serverTimestamp(),
                });
              }
              if (c.mounted) snack(c, '$title saved');
            } catch (error) {
              if (c.mounted)
                snackError(c, error, prefix: 'Unable to save $title');
            }
          },
          child: const Text('Save'),
        ),
      ],
    ),
  );
}

Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String message,
}) async {
  return await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(dialogContext).colorScheme.error,
                foregroundColor: Theme.of(dialogContext).colorScheme.onError,
              ),
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Confirm'),
            ),
          ],
        ),
      ) ??
      false;
}

class RideGuardLogo extends StatelessWidget {
  const RideGuardLogo({super.key, this.size = 26, this.showText = true});
  final double size;
  final bool showText;

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(size * 0.3),
        child: Image.asset('assets/images/logo.png',
            width: size * 1.5, height: size * 1.5, fit: BoxFit.contain),
      ),
      if (showText) ...[
        const SizedBox(width: 10),
        Flexible(
          child: Text('RideGuard',
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700)),
        ),
      ],
    ]);
  }
}

class Chip2 extends StatelessWidget {
  const Chip2(this.text, this.color, {super.key});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
            color: color, borderRadius: BorderRadius.circular(20)),
        child: Text(text,
            style: TextStyle(
                color: Theme.of(context).colorScheme.onPrimary,
                fontSize: 12,
                fontWeight: FontWeight.w700)),
      );
}

class MapPath {
  const MapPath(this.pts, this.color, {this.stops = false});
  final List<LatLng> pts;
  final Color color;
  final bool stops;
}

class MapMarker {
  const MapMarker(this.at, this.color, this.icon, {this.label});
  final LatLng at;
  final Color color;
  final IconData icon;
  final String? label;
}

final sriLankaBounds = map.LatLngBounds(
  LatLng(5.8, 79.4),
  LatLng(10.1, 82.1),
);

bool isSriLankaPoint(LatLng point) =>
    point.latitude >= sriLankaBounds.south &&
    point.latitude <= sriLankaBounds.north &&
    point.longitude >= sriLankaBounds.west &&
    point.longitude <= sriLankaBounds.east;

class RealMap extends StatefulWidget {
  const RealMap(
      {super.key,
      this.paths = const [],
      this.markers = const [],
      this.height = 280,
      this.initialCenter,
      this.followPosition,
      this.follow = false,
      this.onTap});
  final List<MapPath> paths;
  final List<MapMarker> markers;
  final double height;
  final LatLng? initialCenter;
  final LatLng? followPosition;
  final bool follow;
  final void Function(LatLng)? onTap;

  @override
  State<RealMap> createState() => _RealMapState();
}

class GpsSavedBadge extends StatefulWidget {
  const GpsSavedBadge({super.key, required this.updatedAt});
  final DateTime? updatedAt;

  @override
  State<GpsSavedBadge> createState() => _GpsSavedBadgeState();
}

class _GpsSavedBadgeState extends State<GpsSavedBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void didUpdateWidget(covariant GpsSavedBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.updatedAt != oldWidget.updatedAt && widget.updatedAt != null) {
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
        opacity: Tween<double>(begin: 0.25, end: 1).animate(
          CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.white.withAlpha(230),
            borderRadius: BorderRadius.circular(20),
          ),
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.circle, size: 10, color: Colors.green),
              SizedBox(width: 5),
              Text('GPS saved'),
            ]),
          ),
        ),
      );
}

class _RealMapState extends State<RealMap> {
  final _controller = map.MapController();
  LatLng? _userLocation;
  bool _locating = false;
  bool _userPanned = false;

  @override
  void didUpdateWidget(covariant RealMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    final point = widget.followPosition;
    if (widget.follow &&
        !_userPanned &&
        point != null &&
        point != oldWidget.followPosition) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _controller.move(point, _controller.camera.zoom);
      });
    }
  }

  Future<void> _centerOnUser() async {
    if (_locating) return;
    setState(() => _locating = true);
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        throw StateError('Turn on location services to show your location.');
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        throw StateError(
            'Location permission is required to show your location.');
      }
      final position = await Geolocator.getCurrentPosition();
      final point = LatLng(position.latitude, position.longitude);
      if (!mounted) return;
      setState(() => _userLocation = point);
      _controller.move(point, 15);
    } catch (error) {
      if (mounted) snackError(context, error);
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  Widget _mapBody(BuildContext context) {
    final points = [for (final path in widget.paths) ...path.pts];
    final center = widget.initialCenter ??
        _userLocation ??
        (points.isEmpty ? const LatLng(7.2513, 80.3464) : points.first);
    final markers = [
      ...widget.markers,
      if (_userLocation != null)
        MapMarker(_userLocation!, Colors.blue, Icons.my_location, label: 'You'),
    ];
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: SizedBox(
        height: widget.height,
        width: double.infinity,
        child: map.FlutterMap(
          mapController: _controller,
          options: map.MapOptions(
            initialCenter: center,
            initialZoom: 13,
            onTap: widget.onTap == null
                ? null
                : (_, point) {
                    if (isSriLankaPoint(point)) widget.onTap!(point);
                  },
            onPositionChanged: (_, hasGesture) {
              if (hasGesture) _userPanned = true;
            },
          ),
          children: [
            map.TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.sprintora.rideguard',
              tileProvider: map.NetworkTileProvider(
                cachingProvider: rideGuardMapCachingProvider,
              ),
            ),
            for (final path in widget.paths)
              map.PolylineLayer(
                polylines: [
                  map.Polyline(
                    points: [...path.pts],
                    color: path.color,
                    strokeWidth: 5,
                  ),
                ],
              ),
            map.MarkerLayer(
              markers: [
                for (final marker in markers)
                  map.Marker(
                    point: marker.at,
                    width: 110,
                    height: 45,
                    child: _Pin(marker),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mapBody = _mapBody(context);
    return Stack(children: [
      mapBody,
      Positioned(
        top: 8,
        right: 8,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          IconButton.filledTonal(
            tooltip: 'Center on my location',
            onPressed: _locating ? null : _centerOnUser,
            icon: _locating
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.my_location),
          ),
          IconButton.filledTonal(
            tooltip: 'Open full screen map',
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => Dialog.fullscreen(
                child: SafeArea(
                  child: Stack(children: [
                    Positioned.fill(child: mapBody),
                    Positioned(
                      top: 8,
                      right: 8,
                      child: IconButton.filledTonal(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close),
                      ),
                    ),
                  ]),
                ),
              ),
            ),
            icon: const Icon(Icons.fullscreen),
          ),
        ]),
      ),
    ]);
  }
}

class _Pin extends StatelessWidget {
  const _Pin(this.m);
  final MapMarker m;

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: m.color,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2),
          boxShadow: const [BoxShadow(blurRadius: 4, color: Colors.black38)],
        ),
        child: Icon(m.icon, color: Colors.white, size: 20),
      ),
      if (m.label != null)
        Container(
          margin: const EdgeInsets.only(left: 4),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
              color: Colors.white, borderRadius: BorderRadius.circular(6)),
          child: Text(m.label!,
              style: const TextStyle(
                  color: Colors.black,
                  fontSize: 11,
                  fontWeight: FontWeight.w700)),
        ),
    ]);
  }
}
