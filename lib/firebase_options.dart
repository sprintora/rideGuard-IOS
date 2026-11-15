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

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'AIzaSyB6khfheR7MsElngYfC1Z5Kfg2PhCdCZwg',
    appId: '1:626693756002:ios:b51c6d7d8a17feed16ad3b',
    messagingSenderId: '626693756002',
    projectId: 'rideguard-1',
    storageBucket: 'rideguard-1.firebasestorage.app',
    iosBundleId: 'com.sprintora.rideguard',
  );
}
