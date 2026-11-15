import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

@pragma('vm:entry-point')
void rideGuardForegroundCallback() {
  FlutterForegroundTask.setTaskHandler(_RideGuardForegroundTask());
}

class _RideGuardForegroundTask extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {
    FlutterForegroundTask.sendDataToMain(<String, dynamic>{
      'type': 'tripHeartbeat',
      'timestampMillis': timestamp.millisecondsSinceEpoch,
    });
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}

  @override
  void onReceiveData(Object data) {}

  @override
  void onNotificationButtonPressed(String id) {}

  @override
  void onNotificationPressed() {
    FlutterForegroundTask.launchApp();
  }

  @override
  void onNotificationDismissed() {}
}

Future<void> initializeForegroundTripService() async {
  if (!Platform.isAndroid) return;
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'rideguard_active_trip',
      channelName: 'Active trip',
      channelDescription: 'RideGuard keeps the active trip connected.',
      channelImportance: NotificationChannelImportance.HIGH,
      priority: NotificationPriority.HIGH,
      visibility: NotificationVisibility.VISIBILITY_PUBLIC,
      onlyAlertOnce: true,
    ),
    iosNotificationOptions: const IOSNotificationOptions(
      showNotification: false,
      playSound: false,
    ),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.repeat(30000),
      allowWakeLock: true,
      allowWifiLock: true,
    ),
  );
}

Future<void> startForegroundTripService() async {
  if (!Platform.isAndroid) return;
  if (await FlutterForegroundTask.isRunningService) return;
  await FlutterForegroundTask.startService(
    serviceId: 701,
    notificationTitle: 'RideGuard active trip',
    notificationText: 'Reader and location tracking are active.',
    serviceTypes: [
      ForegroundServiceTypes.connectedDevice,
      ForegroundServiceTypes.location,
    ],
    callback: rideGuardForegroundCallback,
  );
}

Future<void> stopForegroundTripService() async {
  if (!Platform.isAndroid) return;
  if (await FlutterForegroundTask.isRunningService) {
    await FlutterForegroundTask.stopService();
  }
}
