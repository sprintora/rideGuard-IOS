import 'package:sqflite/sqflite.dart';

/// Remembers, on the phone, when each card boarded the current trip.
///
/// Used by the driver app to notice a second tap of a card that is already
/// on board (see `_handleReaderTap` in driver.dart). It is saved in a small
/// local database, so it works offline and survives an app restart.
class BoardingStore {
  BoardingStore._();
  static final BoardingStore instance = BoardingStore._();

  Database? _db;

  Future<Database> _open() async {
    final existing = _db;
    if (existing != null) return existing;
    final dir = await getDatabasesPath();
    final db = await openDatabase(
      '$dir/boarding_records.db',
      version: 1,
      onCreate: (db, version) => db.execute(
        'CREATE TABLE boardings ('
        'trip_id TEXT NOT NULL, '
        'card_code TEXT NOT NULL, '
        'boarded_at INTEGER NOT NULL, '
        'PRIMARY KEY (trip_id, card_code))',
      ),
    );
    _db = db;
    return db;
  }

  /// Saves the boarding time. The first boarding time is kept if the card
  /// is already recorded.
  Future<void> markBoarded(
      String tripId, String cardCode, int boardedAt) async {
    final db = await _open();
    await db.insert(
      'boardings',
      {'trip_id': tripId, 'card_code': cardCode, 'boarded_at': boardedAt},
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  /// Forgets the card (it got off, or its boarding was rejected).
  Future<void> remove(String tripId, String cardCode) async {
    final db = await _open();
    await db.delete(
      'boardings',
      where: 'trip_id = ? AND card_code = ?',
      whereArgs: [tripId, cardCode],
    );
  }

  /// When the card boarded this trip, or null if it is not on board.
  Future<int?> boardedAt(String tripId, String cardCode) async {
    final db = await _open();
    final rows = await db.query(
      'boardings',
      columns: ['boarded_at'],
      where: 'trip_id = ? AND card_code = ?',
      whereArgs: [tripId, cardCode],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final value = rows.first['boarded_at'];
    return value is int ? value : (value as num?)?.toInt();
  }

  /// Deletes the records of every other (older) trip.
  Future<void> pruneExcept(String tripId) async {
    final db = await _open();
    await db.delete('boardings', where: 'trip_id != ?', whereArgs: [tripId]);
  }
}
