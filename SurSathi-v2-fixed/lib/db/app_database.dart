// lib/db/app_database.dart
//
// FIX: sursathi.db ek hi file thi jise CacheDB/LikedDB/DownloadDB/PlaylistDB
// alag-alag apne openDatabase() call se khol rahe the. sqflite ek file pe
// sirf ek baar onCreate chalata hai — jo class sabse pehle .instance se
// touch hoti thi, sirf uska table ban pata tha. Baaki teeno ke tables
// (jaise 'cache') kabhi bante hi nahi the.
//
// Ab sirf yahi class asli openDatabase() karti hai. CacheDB/LikedDB/
// DownloadDB/PlaylistDB sab isi se Database instance lete hain, isliye
// onCreate/onUpgrade sirf ek hi jagah, ek hi baar chalta hai aur sabke
// tables guaranteed ban jaate hain.
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

class AppDatabase {
  AppDatabase._internal();
  static final AppDatabase instance = AppDatabase._internal();

  static const String _dbName = 'sursathi.db';
  // PlaylistDB pehle version 2 pe thi (description/is_private + playlist_songs
  // ke naye columns ke liye). Ab central version bhi 2 hi rakha hai taaki
  // purane installs (jinka DB file version 1 ya 2 kisi bhi state me atka ho)
  // pe onUpgrade chal ke sab theek kar de.
  static const int _dbVersion = 2;

  Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, _dbName);

    _db = await openDatabase(
      path,
      version: _dbVersion,
      onCreate: (db, version) async {
        await _createAllTables(db);
      },
      // IMPORTANT: onCreate/onUpgrade sirf tab chalte hain jab file ka
      // stored user_version, humare _dbVersion se match na kare. Kuch
      // existing installs (jinme pehle PlaylistDB sabse pehle khulti thi)
      // ka file already user_version=2 pe atka hua hai — isliye upar wale
      // dono callbacks unke liye kabhi chalte hi nahi, aur 'cache' jaisa
      // table hamesha missing reh jaata. onOpen har baar (version match ho
      // ya na ho) chalta hai, isliye yahi asli guarantee hai ki tables
      // exist karte hain — version number pe depend nahi karta.
      onOpen: (db) async {
        await _createAllTables(db);
        await _ensurePlaylistColumns(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        // Purane buggy installs me ho sakta hai kuch tables bane hi na ho
        // (asli bug yahi tha) — isliye har upgrade pe safe-guard ke taur
        // par sab tables IF NOT EXISTS se dobara ensure kar dete hain.
        await _createAllTables(db);

        await _ensurePlaylistColumns(db);
      },
    );
    return _db!;
  }

  // v1 -> v2 me playlists/playlist_songs me add hue columns. Version number
  // pe bharosa karne ke bajaye ye onOpen se bhi (har baar) chalta hai, taaki
  // jin devices ka file already kisi purani buggy state me atka hua tha
  // unpe bhi columns guaranteed aa jayein. Har ALTER apne try-catch me hai —
  // column pehle se ho to bhi crash nahi hota, bas skip ho jaata hai.
  Future<void> _ensurePlaylistColumns(Database db) async {
    final alters = <String>[
      'ALTER TABLE playlists ADD COLUMN description TEXT',
      'ALTER TABLE playlists ADD COLUMN is_private INTEGER DEFAULT 0',
      'ALTER TABLE playlist_songs ADD COLUMN title TEXT',
      'ALTER TABLE playlist_songs ADD COLUMN artist TEXT',
      'ALTER TABLE playlist_songs ADD COLUMN thumb TEXT',
      'ALTER TABLE playlist_songs ADD COLUMN duration INTEGER',
    ];
    for (final sql in alters) {
      try {
        await db.execute(sql);
      } catch (_) {
        // Column already exists ya koi aur benign issue — ignore.
      }
    }
  }

  Future<void> _createAllTables(Database db) async {
    // --- CacheDB ---
    await db.execute('''
      CREATE TABLE IF NOT EXISTS cache (
        id TEXT PRIMARY KEY,
        title TEXT,
        artist TEXT,
        thumb TEXT,
        file_path TEXT,
        size INTEGER,
        duration INTEGER,
        cached_at INTEGER,
        last_played INTEGER,
        protected INTEGER DEFAULT 0
      )
    ''');

    // --- LikedDB ---
    await db.execute('''
      CREATE TABLE IF NOT EXISTS liked (
        id TEXT PRIMARY KEY,
        title TEXT,
        artist TEXT,
        thumb TEXT,
        duration INTEGER,
        liked_at INTEGER
      )
    ''');

    // --- DownloadDB ---
    await db.execute('''
      CREATE TABLE IF NOT EXISTS downloads (
        id TEXT PRIMARY KEY,
        title TEXT,
        artist TEXT,
        thumb TEXT,
        file_path TEXT,
        duration INTEGER,
        created_at INTEGER
      )
    ''');

    // --- PlaylistDB ---
    await db.execute('''
      CREATE TABLE IF NOT EXISTS playlists (
        id TEXT PRIMARY KEY,
        name TEXT,
        description TEXT,
        cover_emoji TEXT,
        cover_gradient TEXT,
        created_at INTEGER,
        is_collaborative INTEGER,
        is_private INTEGER DEFAULT 0,
        folder_id TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS playlist_songs (
        playlist_id TEXT,
        song_id TEXT,
        position INTEGER,
        added_at INTEGER,
        title TEXT,
        artist TEXT,
        thumb TEXT,
        duration INTEGER,
        PRIMARY KEY (playlist_id, song_id)
      )
    ''');
  }
}
