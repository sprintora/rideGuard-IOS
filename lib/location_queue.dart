import 'dart:convert';

import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

class LocationQueue {
  LocationQueue({
    DatabaseFactory? factory,
    String? databasePath,
  })  : _databaseFactory = factory ?? databaseFactory,
        _databasePath = databasePath;

  Database? _database;
  final DatabaseFactory _databaseFactory;
  final String? _databasePath;

  Future<Database> get database async {
    if (_database != null) return _database!;
    final directory =
        _databasePath == null ? await getApplicationDocumentsDirectory() : null;
    _database = await _databaseFactory.openDatabase(
      _databasePath ?? '${directory!.path}/rideguard_queue.db',
      options: OpenDatabaseOptions(
        version: 2,
        onCreate: (db, version) async {
          await db.execute('''
          CREATE TABLE location_queue (
            point_key TEXT PRIMARY KEY,
            trip_id TEXT NOT NULL,
            payload TEXT NOT NULL,
            created_at INTEGER NOT NULL
          )
        ''');
        },
        onOpen: (db) async {
          await db.execute('''
          CREATE TABLE IF NOT EXISTS location_queue (
            point_key TEXT PRIMARY KEY,
            trip_id TEXT NOT NULL,
            payload TEXT NOT NULL,
            created_at INTEGER NOT NULL
          )
        ''');
        },
      ),
    );
    return _database!;
  }

  Future<void> enqueue({
    required String key,
    required String tripId,
    required Map<String, dynamic> payload,
  }) async {
    final db = await database;
    await db.insert(
      'location_queue',
      {
        'point_key': key,
        'trip_id': tripId,
        'payload': jsonEncode(payload),
        'created_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<List<Map<String, dynamic>>> pending({int limit = 50}) async {
    final db = await database;
    final rows = await db.query(
      'location_queue',
      orderBy: 'created_at ASC',
      limit: limit,
    );
    return rows
        .map((row) => {
              'key': row['point_key'],
              'tripId': row['trip_id'],
              'payload': Map<String, dynamic>.from(
                  jsonDecode(row['payload']! as String) as Map),
            })
        .toList();
  }

  Future<int> pendingCountForTrip(String tripId) async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) AS count FROM location_queue WHERE trip_id = ?',
      [tripId],
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  Future<void> remove(String key) async {
    final db = await database;
    await db.delete('location_queue', where: 'point_key = ?', whereArgs: [key]);
  }

  Future<void> close() async {
    await _database?.close();
    _database = null;
  }
}
