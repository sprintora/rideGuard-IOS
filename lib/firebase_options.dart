import 'dart:io' show Platform;

import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform =>
      Platform.isIOS ? ios : android;

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyBEaegUIVrH2-I83a2YUXNmcWyYgscljNY',
    appId: '1:626693756002:android:1e339c1cf9c3783f16ad3b',
    messagingSenderId: '626693756002',
    projectId: 'rideguard-1',
    storageBucket: 'rideguard-1.firebasestorage.app',
  );

  // Copy API_KEY and GOOGLE_APP_ID from the iOS app's GoogleService-Info.plist
  // (Firebase console > Project settings > Your apps > iOS).
  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'REPLACE_WITH_IOS_API_KEY',
    appId: 'REPLACE_WITH_IOS_GOOGLE_APP_ID',
    messagingSenderId: '626693756002',
    projectId: 'rideguard-1',
    storageBucket: 'rideguard-1.firebasestorage.app',
    iosBundleId: 'com.sprintora.rideguard',
  );
}
