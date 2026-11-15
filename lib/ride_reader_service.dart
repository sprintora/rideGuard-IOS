import 'dart:async';
import 'dart:developer' as developer;
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'permission_service.dart';

const rideReaderServiceUuid = '7f4b0001-6f4a-4f4a-9b2b-524944455231';
const rideReaderTapUuid = '7f4b0002-6f4a-4f4a-9b2b-524944455231';
const rideReaderAckUuid = '7f4b0003-6f4a-4f4a-9b2b-524944455231';
const rideReaderFeedbackUuid = '7f4b0004-6f4a-4f4a-9b2b-524944455231';
const rideReaderInfoUuid = '7f4b0005-6f4a-4f4a-9b2b-524944455231';
const rideReaderControlUuid = '7f4b0006-6f4a-4f4a-9b2b-524944455231';
const rideReaderStatusUuid = '7f4b0007-6f4a-4f4a-9b2b-524944455231';
const rideReaderProtocolVersion = '2.0.0';

final rideReaderServiceProvider = Provider<RideReaderService>((ref) {
  return RideReaderService.shared;
});

enum RideReaderConnectionState {
  disconnected,
  bluetoothOff,
  permissionDenied,
  scanning,
  connecting,
  connected,
  reconnecting,
  failed,
}

enum RideReaderFailureKind {
  locationOff,
  bluetoothOff,
  permissionDenied,
  noReader,
  pairing,
  connection,
  serviceDiscovery,
  missingCharacteristic,
  invalidInfo,
  deviceMismatch,
  unknown,
}

class RideReaderFailure implements Exception {
  const RideReaderFailure(this.kind, this.message);

  final RideReaderFailureKind kind;
  final String message;

  static const locationOff = RideReaderFailure(
    RideReaderFailureKind.locationOff,
    'Turn on Location to find the Ride Reader',
  );
  static const bluetoothOff = RideReaderFailure(
    RideReaderFailureKind.bluetoothOff,
    'Turn on Bluetooth',
  );
  static const permissionDenied = RideReaderFailure(
    RideReaderFailureKind.permissionDenied,
    'Bluetooth permission is required. Open app settings to allow it.',
  );
  static const noReader = RideReaderFailure(
    RideReaderFailureKind.noReader,
    'No Ride Reader found. Make sure it is powered and within range.',
  );
  static const pairing = RideReaderFailure(
    RideReaderFailureKind.pairing,
    'Do not pair in Settings. Press Connect here.',
  );

  @override
  String toString() => message;
}

bool isRideReaderAdvertisement({
  required String name,
  required Iterable<String> serviceUuids,
}) {
  final normalizedName = name.trim().toLowerCase();
  if (normalizedName.startsWith('busrfid-')) return false;
  final hasService =
      serviceUuids.any((uuid) => uuid.toLowerCase() == rideReaderServiceUuid);
  return hasService || normalizedName.startsWith('ridereader-');
}

String rideReaderDisplayName(ScanResult result) {
  final platformName = result.device.platformName.trim();
  if (platformName.isNotEmpty) return platformName;
  final advertisedName = result.advertisementData.advName.trim();
  if (advertisedName.isNotEmpty) return advertisedName;
  return 'Ride Reader ${result.device.remoteId.str}';
}

RideReaderFailure mapRideReaderError(Object error) {
  if (error is RideReaderFailure) return error;
  final text = error.toString().toLowerCase();
  if (text.contains('location services are required') ||
      text.contains('location service')) {
    return RideReaderFailure.locationOff;
  }
  if (text.contains('bluetooth') &&
      (text.contains('off') || text.contains('powered'))) {
    return RideReaderFailure.bluetoothOff;
  }
  if (text.contains('permission') ||
      text.contains('not authorized') ||
      text.contains('denied')) {
    return RideReaderFailure.permissionDenied;
  }
  if (text.contains('pair') || text.contains('bond')) {
    return RideReaderFailure.pairing;
  }
  if (text.contains('not registered') || text.contains('device id mismatch')) {
    return RideReaderFailure(
      RideReaderFailureKind.deviceMismatch,
      error.toString(),
    );
  }
  if (text.contains('characteristic missing')) {
    return RideReaderFailure(
      RideReaderFailureKind.missingCharacteristic,
      'Reader connected, but its required services are not available. Check the reader firmware.',
    );
  }
  if (text.contains('info packet') || text.contains('information')) {
    return const RideReaderFailure(
      RideReaderFailureKind.invalidInfo,
      'Reader connected but did not send its information (INFO). Restart the reader.',
    );
  }
  if (text.contains('discover')) {
    return const RideReaderFailure(
      RideReaderFailureKind.serviceDiscovery,
      'Reader connected, but its services could not be discovered. Restart the reader and try again.',
    );
  }
  if (text.contains('connect') || text.contains('timeout')) {
    return const RideReaderFailure(
      RideReaderFailureKind.connection,
      'Could not connect to the reader. Move closer and try again.',
    );
  }
  return RideReaderFailure(
    RideReaderFailureKind.unknown,
    'Unable to find or connect to the Ride Reader. Try again.',
  );
}

String rideReaderUserMessage(Object error) => mapRideReaderError(error).message;

String _shortId(String value) {
  final compact = value.trim();
  return compact.length <= 6 ? compact : compact.substring(compact.length - 6);
}

class RideReaderInfo {
  const RideReaderInfo({
    required this.deviceId,
    required this.firmware,
    required this.lastTapUptime,
  });

  final String deviceId;
  final String firmware;
  final int lastTapUptime;

  static RideReaderInfo parse(List<int> bytes) {
    final text = String.fromCharCodes(bytes);
    final fields = text.split(',');
    if (fields.length != 3 || fields[0].trim().isEmpty) {
      throw const FormatException('Ride Reader INFO packet is invalid');
    }
    final uptime = int.tryParse(fields[2].trim());
    if (uptime == null || uptime < 0) {
      throw const FormatException('Ride Reader INFO uptime is invalid');
    }
    return RideReaderInfo(
      deviceId: fields[0].trim(),
      firmware: fields[1].trim(),
      lastTapUptime: uptime,
    );
  }
}

class RideReaderTap {
  const RideReaderTap({
    required this.sequence,
    required this.cardCode,
    required this.uptimeMs,
  });

  final int sequence;
  final String cardCode;
  final int uptimeMs;

  String get uid => cardCode;

  static RideReaderTap parse(List<int> bytes) {
    if (bytes.length != 24) {
      throw const FormatException('Ride Reader TAP packet is too short');
    }
    final data = ByteData.sublistView(Uint8List.fromList(bytes));
    final sequence = data.getUint32(0, Endian.little);
    final code = String.fromCharCodes(bytes.sublist(4, 20));
    if (!RegExp(r'^[A-Z2-9]{16}$').hasMatch(code)) {
      throw const FormatException('Ride Reader TAP card code is invalid');
    }
    final uptime = data.getUint32(20, Endian.little);
    return RideReaderTap(sequence: sequence, cardCode: code, uptimeMs: uptime);
  }
}

class RideReaderService {
  static final RideReaderService shared = RideReaderService._internal();

  RideReaderService() {
    _instances.add(this);
  }

  RideReaderService._internal() {
    _instances.add(this);
  }

  static final Set<RideReaderService> _instances = {};

  static Future<void> disconnectAll() async {
    for (final service in List<RideReaderService>.of(_instances)) {
      await service.disconnect();
    }
  }

  BluetoothDevice? connectedDevice;
  RideReaderInfo? info;
  BluetoothCharacteristic? _ack;
  BluetoothCharacteristic? _feedback;
  BluetoothCharacteristic? _infoCharacteristic;
  BluetoothCharacteristic? _control;
  BluetoothCharacteristic? _status;
  StreamSubscription<List<ScanResult>>? _scanSubscription;
  StreamSubscription<List<int>>? _tapSubscription;
  StreamSubscription<List<int>>? _statusSubscription;
  StreamSubscription<BluetoothConnectionState>? _connectionSubscription;
  final _devices = StreamController<List<ScanResult>>.broadcast();
  final _taps = StreamController<RideReaderTap>.broadcast();
  final _statuses = StreamController<String>.broadcast();
  final _states = StreamController<RideReaderConnectionState>.broadcast();
  final _storage = const FlutterSecureStorage();
  RideReaderConnectionState _state = RideReaderConnectionState.disconnected;
  String? _expectedDeviceId;
  bool _manualDisconnect = false;
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;
  int malformedTapCount = 0;

  Stream<List<ScanResult>> get discoveredDevices => _devices.stream;
  Stream<RideReaderTap> get taps => _taps.stream;
  Stream<String> get statuses => _statuses.stream;
  Stream<RideReaderConnectionState> get connectionStates => _states.stream;
  RideReaderConnectionState get state => _state;

  Future<void> requestPermissions() async {
    final api = await DeviceInfo.androidApiLevel;
    if (api >= 31) {
      final scan = await Permission.bluetoothScan.request();
      final connect = await Permission.bluetoothConnect.request();
      if (!scan.isGranted || !connect.isGranted) {
        _setState(RideReaderConnectionState.permissionDenied);
        throw StateError(
            'Bluetooth scan and connect permissions are required.');
      }
    } else if (api >= 29) {
      final location = await Permission.locationWhenInUse.request();
      if (!location.isGranted) {
        _setState(RideReaderConnectionState.permissionDenied);
        throw RideReaderFailure.permissionDenied;
      }
      if (!await Geolocator.isLocationServiceEnabled()) {
        _setState(RideReaderConnectionState.permissionDenied);
        throw RideReaderFailure.locationOff;
      }
    }
    if (await FlutterBluePlus.adapterState.first == BluetoothAdapterState.off) {
      _setState(RideReaderConnectionState.bluetoothOff);
      throw RideReaderFailure.bluetoothOff;
    }
  }

  Future<void> scan() async {
    try {
      await requestPermissions();
      await _scanSubscription?.cancel();
      await FlutterBluePlus.stopScan();
      final results = <String, ScanResult>{};
      _setState(RideReaderConnectionState.scanning);
      _scanSubscription = FlutterBluePlus.onScanResults.listen((items) {
        for (final item in items) {
          final serviceUuids =
              item.advertisementData.serviceUuids.map((uuid) => uuid.str128);
          final advertisedName = item.advertisementData.advName.trim();
          final platformName = item.device.platformName.trim();
          if (isRideReaderAdvertisement(
            name: advertisedName.isNotEmpty ? advertisedName : platformName,
            serviceUuids: serviceUuids,
          )) {
            results[item.device.remoteId.str] = item;
          }
        }
        _devices.add(results.values.toList());
      });
      await FlutterBluePlus.startScan(
        androidUsesFineLocation: false,
        timeout: const Duration(seconds: 8),
      );
      if (results.isEmpty) {
        _setState(RideReaderConnectionState.disconnected);
        throw RideReaderFailure.noReader;
      }
    } catch (error) {
      final failure = mapRideReaderError(error);
      if (failure.kind == RideReaderFailureKind.unknown &&
          error is! RideReaderFailure) {
        developer.log('Ride Reader scan failed', error: error);
      }
      _setState(
        failure.kind == RideReaderFailureKind.bluetoothOff
            ? RideReaderConnectionState.bluetoothOff
            : failure.kind == RideReaderFailureKind.permissionDenied
                ? RideReaderConnectionState.permissionDenied
                : RideReaderConnectionState.failed,
      );
      throw failure;
    }
  }

  Future<void> connect(
    BluetoothDevice device, {
    String? expectedDeviceId,
  }) async {
    await requestPermissions();
    _expectedDeviceId = expectedDeviceId;
    _manualDisconnect = false;
    _reconnectTimer?.cancel();
    _reconnectAttempt = 0;
    _setState(RideReaderConnectionState.connecting);
    try {
      await device.connect(timeout: const Duration(seconds: 12));
      await _configureConnection(device);
      await _storage.write(
          key: 'ride_reader_remote_id', value: device.remoteId.str);
      await _storage.write(
          key: 'ride_reader_device_id', value: expectedDeviceId);
    } catch (error) {
      await device.disconnect();
      _setState(RideReaderConnectionState.failed);
      throw mapRideReaderError(error);
    }
  }

  Future<void> _configureConnection(BluetoothDevice device) async {
    late final List<BluetoothService> services;
    try {
      services = await device.discoverServices();
    } catch (_) {
      throw const RideReaderFailure(
        RideReaderFailureKind.serviceDiscovery,
        'Reader connected, but its services could not be discovered. Restart the reader and try again.',
      );
    }
    final service = services.firstWhere(
      (item) => item.uuid.str128.toLowerCase() == rideReaderServiceUuid,
      orElse: () => throw const RideReaderFailure(
        RideReaderFailureKind.serviceDiscovery,
        'Reader connected, but the Ride Reader service was not found. Check the reader firmware.',
      ),
    );
    BluetoothCharacteristic find(String uuid) =>
        service.characteristics.firstWhere(
          (item) => item.uuid.str128.toLowerCase() == uuid,
          orElse: () => throw const RideReaderFailure(
            RideReaderFailureKind.missingCharacteristic,
            'Reader connected, but its required services are not available. Check the reader firmware.',
          ),
        );
    BluetoothCharacteristic? findOptional(String uuid) {
      for (final characteristic in service.characteristics) {
        if (characteristic.uuid.str128.toLowerCase() == uuid) {
          return characteristic;
        }
      }
      return null;
    }

    final tap = find(rideReaderTapUuid);
    _ack = find(rideReaderAckUuid);
    _feedback = find(rideReaderFeedbackUuid);
    _infoCharacteristic = find(rideReaderInfoUuid);
    _control = find(rideReaderControlUuid);
    _status = findOptional(rideReaderStatusUuid);
    try {
      info = RideReaderInfo.parse(await _infoCharacteristic!.read());
    } catch (_) {
      throw const RideReaderFailure(
        RideReaderFailureKind.invalidInfo,
        'Reader connected but did not send its information (INFO). Restart the reader.',
      );
    }
    if (info!.firmware != rideReaderProtocolVersion || _status == null) {
      throw const RideReaderFailure(
        RideReaderFailureKind.invalidInfo,
        'Update the Ride Reader firmware before using card registration.',
      );
    }
    if (_expectedDeviceId != null &&
        _expectedDeviceId!.isNotEmpty &&
        info!.deviceId != _expectedDeviceId) {
      await device.disconnect();
      throw RideReaderFailure(
        RideReaderFailureKind.deviceMismatch,
        'Reader found, but it is not registered to your bus '
        '(reader id ${_shortId(info!.deviceId)}, '
        'your bus expects ${_shortId(_expectedDeviceId ?? '')}). '
        'Ask the admin to register this reader.',
      );
    }
    await tap.setNotifyValue(true);
    await _status!.setNotifyValue(true);
    await _statusSubscription?.cancel();
    _statusSubscription = _status!.onValueReceived.listen((bytes) {
      _statuses.add(String.fromCharCodes(bytes));
    });
    await _tapSubscription?.cancel();
    _tapSubscription = tap.onValueReceived.listen((bytes) {
      try {
        _taps.add(RideReaderTap.parse(bytes));
      } on FormatException {
        malformedTapCount++;
        developer.log('Dropped malformed Ride Reader TAP packet');
      }
    });
    await _connectionSubscription?.cancel();
    _connectionSubscription = device.connectionState.listen((state) {
      if (state == BluetoothConnectionState.connected) {
        _reconnectAttempt = 0;
        _setState(RideReaderConnectionState.connected);
      } else if (!_manualDisconnect) {
        _setState(RideReaderConnectionState.reconnecting);
        _scheduleReconnect();
      }
    });
    connectedDevice = device;
    _setState(RideReaderConnectionState.connected);
  }

  Future<void> reconnect() async {
    final device = connectedDevice;
    if (device == null) return;
    _setState(RideReaderConnectionState.reconnecting);
    await connect(device, expectedDeviceId: _expectedDeviceId);
  }

  Future<RideReaderInfo?> readInfo() async {
    final characteristic = _infoCharacteristic;
    if (characteristic == null) return info;
    info = RideReaderInfo.parse(await characteristic.read());
    return info;
  }

  Future<void> acknowledge(int sequence) async {
    final characteristic = _ack;
    if (characteristic == null) throw StateError('No Ride Reader connected.');
    final data = ByteData(4)..setUint32(0, sequence, Endian.little);
    await characteristic.write(data.buffer.asUint8List(),
        withoutResponse: false);
  }

  Future<void> feedback(int code) async {
    if (code < 0 || code > 3) throw ArgumentError.value(code, 'code');
    final characteristic = _feedback;
    if (characteristic == null) throw StateError('No Ride Reader connected.');
    await characteristic.write([code], withoutResponse: false);
  }

  Future<void> armCardEnrollment(String code) async {
    if (!RegExp(r'^[A-Z2-9]{16}$').hasMatch(code)) {
      throw ArgumentError.value(code, 'code');
    }
    final characteristic = _control;
    if (characteristic == null) {
      throw StateError('No Ride Reader connected.');
    }
    await characteristic.write(
      'ENROLL:$code'.codeUnits,
      withoutResponse: false,
    );
  }

  Future<void> disconnect() async {
    _manualDisconnect = true;
    _reconnectTimer?.cancel();
    await _tapSubscription?.cancel();
    await _statusSubscription?.cancel();
    await _connectionSubscription?.cancel();
    _tapSubscription = null;
    _statusSubscription = null;
    _connectionSubscription = null;
    final device = connectedDevice;
    connectedDevice = null;
    _ack = null;
    _feedback = null;
    _infoCharacteristic = null;
    _control = null;
    _status = null;
    info = null;
    if (device != null) await device.disconnect();
    _setState(RideReaderConnectionState.disconnected);
  }

  Future<void> dispose() async {
    _reconnectTimer?.cancel();
    await _scanSubscription?.cancel();
    await disconnect();
    await _devices.close();
    await _taps.close();
    await _statuses.close();
    await _states.close();
    _instances.remove(this);
  }

  void _scheduleReconnect() {
    if (_manualDisconnect || connectedDevice == null) return;
    if (_reconnectTimer?.isActive == true) return;
    final seconds = 1 << (_reconnectAttempt > 5 ? 5 : _reconnectAttempt);
    _reconnectAttempt++;
    _reconnectTimer = Timer(Duration(seconds: seconds), () async {
      try {
        await reconnect();
      } catch (error) {
        developer.log('Ride Reader reconnect failed', error: error);
        _scheduleReconnect();
      }
    });
  }

  void _setState(RideReaderConnectionState state) {
    _state = state;
    if (!_states.isClosed) _states.add(state);
  }
}
