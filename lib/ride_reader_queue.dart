import 'dart:convert';

import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

class RideReaderQueueItem {
  const RideReaderQueueItem({
    required this.key,
    required this.tripId,
    required this.payload,
    required this.attempts,
  });

  final String key;
  final String? tripId;
  final Map<String, dynamic> payload;
  final int attempts;
}

class RideReaderQueue {
  RideReaderQueue({
    DatabaseFactory? factory,
    String? databasePath,
  })  : _databaseFactory = factory ?? databaseFactory,
        _databasePath = databasePath;

  Database? _database;
  final DatabaseFactory _databaseFactory;
  final String? _databasePath;

  static String idempotencyKey({
    required String deviceId,
    required int sequence,
    required String? tripId,
  }) =>
      '$deviceId-$sequence-${tripId ?? 'unassigned'}';

  static int retryDelaySeconds(int attempts) =>
      1 << (attempts > 6 ? 6 : attempts);

  Future<Database> get database async {
    final existing = _database;
    if (existing != null) return existing;
    final directory =
        _databasePath == null ? await getApplicationDocumentsDirectory() : null;
    _database = await _databaseFactory.openDatabase(
      _databasePath ?? '${directory!.path}/rideguard_queue.db',
      options: OpenDatabaseOptions(
        version: 3,
        onCreate: (db, version) async {
          await db.execute('''
          CREATE TABLE ride_reader_queue (
            event_key TEXT PRIMARY KEY,
            trip_id TEXT,
            payload TEXT NOT NULL,
            state TEXT NOT NULL,
            attempts INTEGER NOT NULL DEFAULT 0,
            next_attempt_at INTEGER NOT NULL DEFAULT 0,
            result TEXT,
            completed_at INTEGER
          )
        ''');
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion < 2) {
            await db
                .execute('CREATE INDEX IF NOT EXISTS ride_reader_queue_state '
                    'ON ride_reader_queue (state, next_attempt_at)');
          }
          if (oldVersion < 3) {
            final columns = await db.rawQuery(
              'PRAGMA table_info(ride_reader_queue)',
            );
            final hasCompletedAt = columns.any(
              (column) => column['name'] == 'completed_at',
            );
            if (!hasCompletedAt) {
              await db.execute(
                  'ALTER TABLE ride_reader_queue ADD COLUMN completed_at INTEGER');
            }
          }
        },
      ),
    );
    return _database!;
  }

  Future<bool> enqueue({
    required String key,
    required String? tripId,
    required Map<String, dynamic> payload,
  }) async {
    final db = await database;
    final inserted = await db.insert(
      'ride_reader_queue',
      {
        'event_key': key,
        'trip_id': tripId,
        'payload': jsonEncode(payload),
        'state': 'pending',
        'next_attempt_at': 0,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    return inserted != 0;
  }

  Future<bool> contains(String key) async {
    final db = await database;
    final rows = await db.query(
      'ride_reader_queue',
      columns: ['event_key'],
      where: 'event_key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<List<RideReaderQueueItem>> pending({int limit = 50}) async {
    final db = await database;
    final rows = await db.query(
      'ride_reader_queue',
      where: 'state = ? AND next_attempt_at <= ?',
      whereArgs: ['pending', DateTime.now().millisecondsSinceEpoch],
      orderBy: 'rowid ASC',
      limit: limit,
    );
    return rows
        .map((row) => RideReaderQueueItem(
              key: row['event_key']! as String,
              tripId: row['trip_id'] as String?,
              payload: Map<String, dynamic>.from(
                jsonDecode(row['payload']! as String) as Map,
              ),
              attempts: row['attempts']! as int,
            ))
        .toList();
  }

  Future<void> markRetry(String key) async {
    final db = await database;
    final row = await db.query(
      'ride_reader_queue',
      columns: ['attempts'],
      where: 'event_key = ?',
      whereArgs: [key],
      limit: 1,
    );
    if (row.isEmpty) return;
    final attempts = (row.first['attempts']! as int) + 1;
    final delaySeconds = retryDelaySeconds(attempts);
    await db.update(
      'ride_reader_queue',
      {
        'attempts': attempts,
        'next_attempt_at':
            DateTime.now().millisecondsSinceEpoch + delaySeconds * 1000,
      },
      where: 'event_key = ?',
      whereArgs: [key],
    );
  }

  Future<void> markDone(String key, String result) async {
    final db = await database;
    await db.update(
      'ride_reader_queue',
      {
        'state': 'done',
        'result': result,
        'completed_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'event_key = ?',
      whereArgs: [key],
    );
  }

  Future<int> pendingCount() async {
    final db = await database;
    final result = await db.rawQuery(
      "SELECT COUNT(*) AS count FROM ride_reader_queue WHERE state = 'pending'",
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  Future<int> resultCount(String result) async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS count FROM ride_reader_queue WHERE result = ?',
      [result],
    );
    return Sqflite.firstIntValue(rows) ?? 0;
  }

  Future<int> resultCountToday(String result) async {
    final now =
        DateTime.now().toUtc().add(const Duration(hours: 5, minutes: 30));
    final start = DateTime.utc(now.year, now.month, now.day)
        .subtract(const Duration(hours: 5, minutes: 30))
        .millisecondsSinceEpoch;
    final end = start + const Duration(days: 1).inMilliseconds;
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS count FROM ride_reader_queue '
      'WHERE result = ? AND completed_at >= ? AND completed_at < ?',
      [result, start, end],
    );
    return Sqflite.firstIntValue(rows) ?? 0;
  }

  Future<void> close() async {
    await _database?.close();
    _database = null;
  }
}
