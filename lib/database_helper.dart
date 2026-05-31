import 'dart:async';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

class DatabaseHelper {
  static final DatabaseHelper _instance = DatabaseHelper._internal();
  static Database? _database;

  factory DatabaseHelper() => _instance;

  DatabaseHelper._internal();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    String path = join(await getDatabasesPath(), 'tamagotchi.db');
    return await openDatabase(
      path,
      version: 2,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE tamagochis (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            level INTEGER,
            exp INTEGER DEFAULT 0,
            gold INTEGER,
            diamonds INTEGER,
            mood INTEGER,
            fullness INTEGER,
            hygiene INTEGER,
            energy INTEGER,
            last_updated TIMESTAMP DEFAULT CURRENT_TIMESTAMP
          )
        ''');
        await db.insert('tamagochis', {
          'level': 1,
          'exp': 0,
          'gold': 0,
          'diamonds': 0,
          'mood': 80,
          'fullness': 50,
          'hygiene': 100,
          'energy': 70,
        });
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute(
            'ALTER TABLE tamagochis ADD COLUMN exp INTEGER DEFAULT 0',
          );
        }
      },
    );
  }

  Future<Map<String, dynamic>?> getTamagotchi() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query('tamagochis', limit: 1);
    if (maps.isNotEmpty) return maps.first;
    return null;
  }

  Future<void> updateTamagotchi(Map<String, dynamic> data) async {
    final db = await database;
    final updateData = {
      if (data['level'] != null) 'level': data['level'],
      if (data['exp'] != null) 'exp': data['exp'],
      if (data['gold'] != null) 'gold': data['gold'],
      if (data['diamonds'] != null) 'diamonds': data['diamonds'],
      if (data['mood'] != null) 'mood': data['mood'],
      if (data['fullness'] != null) 'fullness': data['fullness'],
      if (data['hygiene'] != null) 'hygiene': data['hygiene'],
      if (data['energy'] != null) 'energy': data['energy'],
      'last_updated': DateTime.now().toIso8601String(),
    };
    await db.update('tamagochis', updateData, where: 'id = ?', whereArgs: [1]);
  }
}
