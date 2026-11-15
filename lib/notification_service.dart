import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationService {
  NotificationService._();

  static final _plugin = FlutterLocalNotificationsPlugin();

  static Future<void> initialize() async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const settings = InitializationSettings(
      android: android,
      iOS: DarwinInitializationSettings(),
    );
    await _plugin.initialize(settings);
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(const AndroidNotificationChannel(
          'rideguard_alerts',
          'RideGuard alerts',
          description: 'Bus and child safety alerts.',
          importance: Importance.max,
          playSound: true,
          showBadge: true,
        ));
    FirebaseMessaging.onMessage.listen(showRemoteMessage);
  }

  static Future<void> showRemoteMessage(RemoteMessage message) async {
    final notification = message.notification;
    if (notification == null) return;
    await _plugin.show(
      message.hashCode,
      notification.title ?? 'RideGuard',
      notification.body ?? '',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'rideguard_alerts',
          'RideGuard alerts',
          channelDescription: 'Bus and child safety alerts.',
          importance: Importance.max,
          priority: Priority.max,
          visibility: NotificationVisibility.public,
          playSound: true,
          channelShowBadge: true,
        ),
        iOS: DarwinNotificationDetails(presentAlert: true, presentBadge: true),
      ),
    );
  }
}
