import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rideguard/app_models.dart';
import 'package:rideguard/ride_reader_queue.dart';
import 'package:rideguard/ride_reader_service.dart';

// All packets and records in this file are synthetic test fixtures.

List<int> tapPacket(int sequence, String code, int uptime) {
  final data = ByteData(24);
  data.setUint32(0, sequence, Endian.little);
  for (var index = 0; index < code.length; index++) {
    data.setUint8(4 + index, code.codeUnitAt(index));
  }
  data.setUint32(20, uptime, Endian.little);
  return data.buffer.asUint8List();
}

void main() {
  test('parses the synthetic TAP fixture layout', () {
    final tap = RideReaderTap.parse(tapPacket(7, 'ABCD2345EFGH6789', 1234));

    expect(tap.sequence, 7);
    expect(tap.cardCode, 'ABCD2345EFGH6789');
    expect(tap.uptimeMs, 1234);
  });

  test('rejects truncated and extra-byte TAP packets', () {
    final packet = tapPacket(1, 'ABCD2345EFGH6789', 20);

    expect(
      () => RideReaderTap.parse(packet.sublist(0, packet.length - 1)),
      throwsFormatException,
    );
    expect(
      () => RideReaderTap.parse([...packet, 0]),
      throwsFormatException,
    );
  });

  test('rejects invalid card codes', () {
    final packet = tapPacket(1, 'ABCD-345EFGH6789', 20);

    expect(() => RideReaderTap.parse(packet), throwsFormatException);
  });

  test('maps scan failures to driver-safe messages', () {
    expect(
      mapRideReaderError(
        StateError(
            'PlatformException(startScan, Location services are required for Bluetooth scan)'),
      ).message,
      'Turn on Location to find the Ride Reader',
    );
    expect(
      mapRideReaderError(StateError('Bluetooth is off')).message,
      'Turn on Bluetooth',
    );
    expect(
      mapRideReaderError(StateError('permission permanently denied')).message,
      'Bluetooth permission is required. Open app settings to allow it.',
    );
    expect(
      mapRideReaderError(RideReaderFailure.noReader).message,
      'No Ride Reader found. Make sure it is powered and within range.',
    );
    expect(
      mapRideReaderError(StateError('pairing required')).message,
      'Do not pair in Settings. Press Connect here.',
    );
  });

  test('ignores BusRFID scan results', () {
    expect(
      isRideReaderAdvertisement(
        name: 'BusRFID-E8F8',
        serviceUuids: [rideReaderServiceUuid],
      ),
      isFalse,
    );
    expect(
      isRideReaderAdvertisement(
        name: 'RideReader-E8F8',
        serviceUuids: [rideReaderServiceUuid],
      ),
      isTrue,
    );
  });

  test('accepts an unnamed reader when the Ride Reader service is advertised',
      () {
    expect(
      isRideReaderAdvertisement(
        name: '',
        serviceUuids: [rideReaderServiceUuid],
      ),
      isTrue,
    );
  });

  test('orders out-of-order events by phone time then reader sequence', () {
    final state = calculateOnBoardState([
      {
        'studentId': 'student-2',
        'mode': 'boarding',
        'tappedAt': 300,
        'readerSequence': 3,
      },
      {
        'studentId': 'student-1',
        'mode': 'boarding',
        'tappedAt': 100,
        'readerSequence': 2,
      },
      {
        'studentId': 'student-1',
        'mode': 'alighting',
        'tappedAt': 200,
        'readerSequence': 4,
      },
    ]);

    expect(state.studentIds, {'student-2'});
  });

  test('queue keys are stable and retry backoff is capped', () {
    final first = RideReaderQueue.idempotencyKey(
      deviceId: 'reader-1',
      sequence: 12,
      tripId: 'trip-1',
    );
    final second = RideReaderQueue.idempotencyKey(
      deviceId: 'reader-1',
      sequence: 12,
      tripId: 'trip-1',
    );

    expect(first, second);
    expect(RideReaderQueue.retryDelaySeconds(1), 2);
    expect(RideReaderQueue.retryDelaySeconds(99), 64);
  });
}
