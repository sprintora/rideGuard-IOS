import 'dart:io';

import 'package:android_intent_plus/android_intent.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

class RideGuardPermissionService {
  Future<bool> get locationServicesEnabled =>
      Geolocator.isLocationServiceEnabled();

  Future<PermissionStatus> foregroundLocationStatus() =>
      Permission.locationWhenInUse.status;

  Future<PermissionStatus> backgroundLocationStatus() =>
      Permission.locationAlways.status;

  Future<PermissionStatus> bluetoothScanStatus() async {
    if (!Platform.isAndroid || await DeviceInfo.androidApiLevel < 31) {
      return PermissionStatus.granted;
    }
    return Permission.bluetoothScan.status;
  }

  Future<PermissionStatus> bluetoothConnectStatus() async {
    if (!Platform.isAndroid || await DeviceInfo.androidApiLevel < 31) {
      return PermissionStatus.granted;
    }
    return Permission.bluetoothConnect.status;
  }

  Future<PermissionStatus> notificationStatus() {
    if (!Platform.isAndroid) return Future.value(PermissionStatus.granted);
    return Permission.notification.status;
  }

  Future<LocationPermission> requestForegroundLocation() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw StateError('Location services must be enabled.');
    }
    final permission = await Geolocator.requestPermission();
    if (permission == LocationPermission.deniedForever ||
        permission == LocationPermission.denied) {
      throw StateError('Precise location permission is required.');
    }
    return permission;
  }

  Future<LocationPermission> requestBackgroundLocation() async {
    final foreground = await requestForegroundLocation();
    if (Platform.isAndroid && foreground != LocationPermission.always) {
      final permission = await Geolocator.requestPermission();
      if (permission != LocationPermission.always) {
        throw StateError(
            'Background location is required for screen-locked trips.');
      }
      return permission;
    }
    return foreground;
  }

  Future<bool> requestNotifications() async {
    if (Platform.isAndroid && (await DeviceInfo.androidApiLevel) >= 33) {
      final permission = await Permission.notification.request();
      return permission.isGranted;
    }
    return true;
  }

  Future<void> openSettings() => openAppSettings();

  Future<bool> openLocationSettings() => Geolocator.openLocationSettings();

  Future<void> openBatteryOptimizationSettings() async {
    if (!Platform.isAndroid) return;
    await const AndroidIntent(
      action: 'android.settings.IGNORE_BATTERY_OPTIMIZATION_SETTINGS',
    ).launch();
  }
}

class DeviceInfo {
  static Future<int> get androidApiLevel async {
    if (!Platform.isAndroid) return 0;
    return (await DeviceInfoPlugin().androidInfo).version.sdkInt;
  }
}
