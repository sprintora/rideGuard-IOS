import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rideguard/location_queue.dart';
import 'package:rideguard/location_tracking_service.dart';
import 'package:rideguard/ride_reader_queue.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class SyntheticBleTransport {
  final acknowledgements = <int>[];
  bool failAck = false;

  Future<void> acknowledge(int sequence) async {
    if (failAck) throw StateError('synthetic BLE ACK failure');
    acknowledgements.add(sequence);
  }
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  Future<String> temporaryDatabasePath(String name) async {
    final directory =
        await Directory.systemTemp.createTemp('rideguard-synthetic-');
    return '${directory.path}\\$name.db';
  }

  test(
      'synthetic tap queue survives restart, orders upload, and confirms deletion',
      () async {
    final path = await temporaryDatabasePath('tap');
    final first = RideReaderQueue(
      factory: databaseFactoryFfi,
      databasePath: path,
    );
    await first.enqueue(key: 'first', tripId: 'trip', payload: {'sequence': 1});
    await first
        .enqueue(key: 'second', tripId: 'trip', payload: {'sequence': 2});
    await first.close();

    final restarted = RideReaderQueue(
      factory: databaseFactoryFfi,
      databasePath: path,
    );
    final pending = await restarted.pending();
    expect(pending.map((item) => item.key), ['first', 'second']);
    await restarted.markRetry('first');
    expect((await restarted.pending()).single.key, 'second');
    await restarted.markDone('second', 'processed');
    expect(await restarted.pendingCount(), 1);
    await restarted.markDone('first', 'processed');
    expect(await restarted.pendingCount(), 0);
    await restarted.close();
  });

  test('synthetic tap queue caps retry backoff and stops permanent rejection',
      () async {
    final path = await temporaryDatabasePath('retry');
    final queue =
        RideReaderQueue(factory: databaseFactoryFfi, databasePath: path);
    await queue.enqueue(key: 'reject', tripId: 'trip', payload: const {});
    await queue.markDone('reject', 'rejected_card');
    expect(await queue.pendingCount(), 0);
    expect(RideReaderQueue.retryDelaySeconds(100), 64);
    await queue.close();
  });

  test('synthetic no-trip tap is terminal and never uploadable', () async {
    final path = await temporaryDatabasePath('no-trip');
    final queue =
        RideReaderQueue(factory: databaseFactoryFfi, databasePath: path);
    await queue.enqueue(key: 'no-trip', tripId: null, payload: const {});
    await queue.markDone('no-trip', 'rejected_no_active_trip');
    expect(await queue.pending(), isEmpty);
    expect(await queue.resultCount('rejected_no_active_trip'), 1);
    await queue.close();
  });

  test('synthetic ACK follows durable write and not a failing write', () async {
    final path = await temporaryDatabasePath('ack');
    final queue =
        RideReaderQueue(factory: databaseFactoryFfi, databasePath: path);
    final ble = SyntheticBleTransport()..failAck = true;
    Future<void> persistThenAck() async {
      await queue.enqueue(key: 'ack', tripId: 'trip', payload: const {});
      await ble.acknowledge(7);
    }

    await expectLater(persistThenAck(), throwsStateError);
    expect(await queue.pendingCount(), 1);
    expect(ble.acknowledgements, isEmpty);
    await queue.close();
  });

  test('synthetic reconnect replay deduplicates and ACKs once', () async {
    final path = await temporaryDatabasePath('reconnect');
    final queue =
        RideReaderQueue(factory: databaseFactoryFfi, databasePath: path);
    final ble = SyntheticBleTransport();
    expect(
        await queue.enqueue(key: 'reader-1', tripId: 'trip', payload: const {}),
        isTrue);
    expect(
        await queue.enqueue(key: 'reader-1', tripId: 'trip', payload: const {}),
        isFalse);
    await ble.acknowledge(1);
    expect(ble.acknowledgements, [1]);
    await queue.close();
  });

  test('synthetic duplicate tap remains durable and can be acknowledged',
      () async {
    final path = await temporaryDatabasePath('duplicate-ack');
    final queue =
        RideReaderQueue(factory: databaseFactoryFfi, databasePath: path);
    expect(
        await queue.enqueue(
          key: 'reader-duplicate',
          tripId: 'trip',
          payload: const {'sequence': 4},
        ),
        isTrue);
    expect(
        await queue.enqueue(
          key: 'reader-duplicate',
          tripId: 'trip',
          payload: const {'sequence': 4},
        ),
        isFalse);
    expect(await queue.contains('reader-duplicate'), isTrue);
    await queue.close();
  });

  test(
      'synthetic GPS filtering rejects weak and impossible fixes but saves stationary points on schedule',
      () {
    final previous = DateTime(2026, 11, 7, 8);
    expect(
      acceptsLocationSample(
        accuracy: 81,
        speed: 10,
        previousLatitude: 7.2,
        previousLongitude: 80.1,
        previousTimestamp: previous,
        latitude: 7.21,
        longitude: 80.11,
        timestamp: previous.add(const Duration(seconds: 20)),
      ),
      isFalse,
    );
    expect(
      acceptsLocationSample(
        accuracy: 10,
        speed: 100,
        previousLatitude: 7.2,
        previousLongitude: 80.1,
        previousTimestamp: previous,
        latitude: 8.2,
        longitude: 81.1,
        timestamp: previous.add(const Duration(seconds: 20)),
      ),
      isFalse,
    );
    expect(
      acceptsLocationSample(
        accuracy: 10,
        speed: 0,
        previousLatitude: 7.2,
        previousLongitude: 80.1,
        previousTimestamp: previous,
        latitude: 7.20001,
        longitude: 80.10001,
        timestamp: previous.add(locationSampleInterval),
      ),
      isTrue,
    );
  });

  test('synthetic GPS queue uploads in order and deletes after confirmation',
      () async {
    final path = await temporaryDatabasePath('locations');
    final queue =
        LocationQueue(factory: databaseFactoryFfi, databasePath: path);
    await queue.enqueue(key: 'point-1', tripId: 'trip', payload: {'lat': 7.2});
    await queue.enqueue(key: 'point-2', tripId: 'trip', payload: {'lat': 7.3});
    final points = await queue.pending();
    expect(points.map((point) => point['key']), ['point-1', 'point-2']);
    expect(await queue.pending(), hasLength(2));
    await queue.remove('point-1');
    expect((await queue.pending()).single['key'], 'point-2');
    await queue.close();
  });

  test('synthetic GPS pending count is scoped to one trip', () async {
    final path = await temporaryDatabasePath('location-count');
    final queue =
        LocationQueue(factory: databaseFactoryFfi, databasePath: path);
    await queue.enqueue(key: 'trip-a-1', tripId: 'trip-a', payload: const {});
    await queue.enqueue(key: 'trip-b-1', tripId: 'trip-b', payload: const {});
    expect(await queue.pendingCountForTrip('trip-a'), 1);
    expect(await queue.pendingCountForTrip('trip-b'), 1);
    await queue.close();
  });
}
