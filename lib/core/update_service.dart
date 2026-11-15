import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

const updateManifestUrl =
    'https://github.com/kanishkaGayan/RideGuard-Releases/releases/latest/download/latest.json';

class UpdateManifest {
  const UpdateManifest({
    required this.versionName,
    required this.versionCode,
    required this.minVersionCode,
    required this.apkUrl,
    required this.apkSha256,
    required this.apkSizeBytes,
    required this.releaseNotes,
    required this.message,
  });

  final String versionName;
  final int versionCode;
  final int minVersionCode;
  final String apkUrl;
  final String apkSha256;
  final int apkSizeBytes;
  final List<String> releaseNotes;
  final String message;

  bool get forced => _installedVersionCode < minVersionCode;
  static int _installedVersionCode = 0;

  static UpdateManifest? parse(Map<String, dynamic> data) {
    if (data['schemaVersion'] != 1) return null;
    final versionName = data['versionName'];
    final versionCode = data['versionCode'];
    final minVersionCode = data['minVersionCode'];
    final apkUrlValue = data['apkUrl'];
    final sha = data['apkSha256'];
    final size = data['apkSizeBytes'];
    final parsedUrl =
        apkUrlValue is String ? Uri.tryParse(apkUrlValue) : null;
    if (versionName is! String ||
        versionCode is! int ||
        minVersionCode is! int ||
        apkUrlValue is! String ||
        sha is! String ||
        size is! int ||
        versionCode <= 0 ||
        size <= 0 ||
        parsedUrl == null ||
        !parsedUrl.isAbsolute ||
        parsedUrl.scheme != 'https' ||
        !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(sha)) {
      return null;
    }
    return UpdateManifest(
      versionName: versionName,
      versionCode: versionCode,
      minVersionCode: minVersionCode,
      apkUrl: apkUrlValue,
      apkSha256: sha.toLowerCase(),
      apkSizeBytes: size,
      releaseNotes: (data['releaseNotes'] is List)
          ? (data['releaseNotes'] as List).whereType<String>().toList()
          : const [],
      message: data['message'] is String ? data['message'] as String : '',
    );
  }
}

class UpdateService {
  static const _lastCheckKey = 'rideguard.update.lastCheck';
  static const _dismissedVersionKey = 'rideguard.update.dismissedVersion';
  static const _dismissedAtKey = 'rideguard.update.dismissedAt';

  Future<UpdateManifest?> check({bool manual = false}) async {
    try {
      final package = await PackageInfo.fromPlatform();
      final installed = int.tryParse(package.buildNumber) ?? 0;
      UpdateManifest._installedVersionCode = installed;
      final preferences = await SharedPreferences.getInstance();
      final now = DateTime.now();
      final last = DateTime.tryParse(
          preferences.getString(_lastCheckKey) ?? '');
      if (!manual &&
          last != null &&
          now.difference(last) < const Duration(hours: 6)) {
        return null;
      }
      await preferences.setString(_lastCheckKey, now.toIso8601String());
      final response = await http
          .get(Uri.parse(updateManifestUrl))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return null;
      final decoded = jsonDecode(response.body);
      if (decoded is! Map) return null;
      final manifest =
          UpdateManifest.parse(Map<String, dynamic>.from(decoded));
      if (manifest == null || manifest.versionCode <= installed) return null;
      if (!manifest.forced &&
          preferences.getInt(_dismissedVersionKey) == manifest.versionCode &&
          now.difference(DateTime.tryParse(
                  preferences.getString(_dismissedAtKey) ?? '') ??
              DateTime.fromMillisecondsSinceEpoch(0)) <
              const Duration(hours: 24)) {
        return null;
      }
      return manifest;
    } catch (_) {
      return null;
    }
  }

  Future<void> dismiss(UpdateManifest manifest) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setInt(_dismissedVersionKey, manifest.versionCode);
    await preferences.setString(
        _dismissedAtKey, DateTime.now().toIso8601String());
  }

  Future<File> download(UpdateManifest manifest) async {
    final directory = await getTemporaryDirectory();
    final file = File('${directory.path}/RideGuard-${manifest.versionName}.apk');
    final request = http.Request('GET', Uri.parse(manifest.apkUrl));
    final response = await http.Client().send(request);
    if (response.statusCode != 200) {
      throw StateError('Unable to download the update.');
    }
    final bytes = <int>[];
    await for (final chunk in response.stream) {
      bytes.addAll(chunk);
    }
    if (bytes.length != manifest.apkSizeBytes ||
        sha256.convert(bytes).toString() != manifest.apkSha256) {
      if (await file.exists()) await file.delete();
      throw StateError('The downloaded update failed verification.');
    }
    return file..writeAsBytesSync(bytes, flush: true);
  }

  Future<void> install(File file) async {
    if (Platform.isAndroid) {
      final permission = await Permission.requestInstallPackages.request();
      if (!permission.isGranted) {
        throw StateError('Allow RideGuard to install updates, then try again.');
      }
    }
    final result = await OpenFilex.open(
      file.path,
      type: 'application/vnd.android.package-archive',
    );
    if (result.type != ResultType.done) {
      throw StateError(result.message);
    }
  }
}
