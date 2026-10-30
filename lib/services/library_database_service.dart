import 'dart:async';
import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../models/models.dart';

/// SQLite-based persistent storage for the music library.
///
/// Replaces the previous SharedPreferences + single-blob JSON approach
/// which caused OutOfMemoryError with libraries containing 100k+ songs.
///
/// Batch inserts use transactions and 1k-record chunks so that even
/// millions of rows can be written without spikes in memory usage.
class LibraryDatabaseService {
  static const String _dbName = 'kumaflow_library.db';
  static const int _dbVersion = 9; // v9: search indexes (title/artist/album) + queue id-only rows
  static const int _batchSize = 1000;

  Database? _db;

  Future<Database> get database async {
    _db ??= await _initDatabase();
    return _db!;
  }

  Future<Database> _initDatabase() async {
    final databasesPath = await getDatabasesPath();
    final dbPath = join(databasesPath, _dbName);

    final db = await openDatabase(
      dbPath,
      version: _dbVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );

    // PRAGMA tuning — WAL mode, larger cache, busy timeout for concurrent access
    // journal_mode returns a row, so use rawQuery; others are safe with execute
    try {
      await db.rawQuery('PRAGMA journal_mode = WAL');
    } catch (_) {
      // fallback: try execute on platforms where rawQuery is not allowed for PRAGMA
      try { await db.execute('PRAGMA journal_mode = WAL'); } catch (_) {}
    }
    try { await db.execute('PRAGMA synchronous = NORMAL'); } catch (_) {}
    try { await db.execute('PRAGMA busy_timeout = 5000'); } catch (_) {}
    try { await db.execute('PRAGMA cache_size = -32000'); } catch (_) {} // 32MB
    try { await db.execute('PRAGMA temp_store = MEMORY'); } catch (_) {}

    return db;
  }

  Future<void> _onCreate(Database db, int version) async {
    await _createSchema(db);
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      // v1 -> v2: add starred / userRating columns if missing
      try {
        await db.execute(
            'ALTER TABLE songs ADD COLUMN starred INTEGER DEFAULT 0');
      } catch (_) {}
      try {
        await db.execute(
            'ALTER TABLE songs ADD COLUMN userRating INTEGER');
      } catch (_) {}
    }
    if (oldVersion < 3) {
      // v2 -> v3: ensure isLocal exists on all tables (was added in schema but not migrated)
      for (final tbl in ['songs', 'albums', 'artists']) {
        try {
          await db.execute('ALTER TABLE $tbl ADD COLUMN isLocal INTEGER DEFAULT 0');
        } catch (_) {}
      }
      // Backfill: mark existing rows as server (isLocal=0) where null
      try {
        await db.execute('UPDATE songs SET isLocal=0 WHERE isLocal IS NULL');
        await db.execute('UPDATE albums SET isLocal=0 WHERE isLocal IS NULL');
        await db.execute('UPDATE artists SET isLocal=0 WHERE isLocal IS NULL');
      } catch (_) {}
    }
    if (oldVersion < 4) {
      // v3 -> v4: add queue, song_profiles, mix_cache, app_kv tables
      await _createV4Tables(db);
    }
    if (oldVersion < 5) {
      // v4 -> v5: hybrid ML columns for fast WHERE filtering (not-played/played/disliked/banned)
      for (final tbl in ['songs']) {
        try {
          await db.execute('ALTER TABLE songs ADD COLUMN playCount INTEGER DEFAULT 0');
        } catch (_) {}
        try {
          await db.execute('ALTER TABLE songs ADD COLUMN disliked INTEGER DEFAULT 0');
        } catch (_) {}
        try {
          await db.execute('ALTER TABLE songs ADD COLUMN skipCount INTEGER DEFAULT 0');
        } catch (_) {}
        try {
          await db.execute('ALTER TABLE songs ADD COLUMN lastPlayed INTEGER');
        } catch (_) {}
        try {
          await db.execute('ALTER TABLE songs ADD COLUMN banned INTEGER DEFAULT 0');
        } catch (_) {}
      }
      try {
        await db.execute('CREATE INDEX IF NOT EXISTS idx_song_playCount ON songs(playCount)');
      } catch (_) {}
      try {
        await db.execute('CREATE INDEX IF NOT EXISTS idx_song_disliked ON songs(disliked)');
      } catch (_) {}
      try {
        await db.execute('CREATE INDEX IF NOT EXISTS idx_song_lastPlayed ON songs(lastPlayed)');
      } catch (_) {}
      try {
        await db.execute('CREATE INDEX IF NOT EXISTS idx_song_banned ON songs(banned)');
      } catch (_) {}
      try {
        await db.execute('CREATE INDEX IF NOT EXISTS idx_song_genre ON songs(genre)');
      } catch (_) {}
    }
    if (oldVersion < 6) {
      // v5 -> v6: mood column for orchestrator/autodj hybrid filtering
      try {
        await db.execute('ALTER TABLE songs ADD COLUMN mood TEXT');
      } catch (_) {}
      try {
        await db.execute('CREATE INDEX IF NOT EXISTS idx_song_mood ON songs(mood)');
      } catch (_) {}
    }
    if (oldVersion < 7) {
      try {
        await db.execute('CREATE INDEX IF NOT EXISTS idx_song_isLocal ON songs(isLocal)');
      } catch (_) {}
    }
    if (oldVersion < 8) {
      // v7 -> v8: offline-first audio features cache (BPM/energy/valence/...)
      await _createAudioFeaturesTable(db);
    }
    if (oldVersion < 9) {
      // v8 -> v9: search/sort indexes for SQL-side filtering (П2).
      // LIKE '%q%' все равно скан, но LIKE 'q%' и ORDER BY идут по индексу.
      try {
        await db.execute('CREATE INDEX IF NOT EXISTS idx_song_title ON songs(title)');
      } catch (_) {}
      try {
        await db.execute('CREATE INDEX IF NOT EXISTS idx_song_artist ON songs(artist)');
      } catch (_) {}
      try {
        await db.execute('CREATE INDEX IF NOT EXISTS idx_song_album ON songs(album)');
      } catch (_) {}
      try {
        await db.execute('CREATE INDEX IF NOT EXISTS idx_song_created ON songs(created)');
      } catch (_) {}
      // queue.song_data -> nullable для id-only строк (П5).
      // SQLite без пересоздания таблицы: старые строки остаются как есть,
      // новые id-only пишут '' в song_data и гидрируются из songs.
      try {
        await db.execute('CREATE INDEX IF NOT EXISTS idx_queue_song_id ON queue(song_id)');
      } catch (_) {}
    }
  }

  Future<void> _createAudioFeaturesTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS audio_features (
        song_id TEXT PRIMARY KEY,
        bpm REAL,
        energy REAL,
        valence REAL,
        danceability REAL,
        acousticness REAL,
        instrumentalness REAL,
        source TEXT DEFAULT 'genre',
        updated_at INTEGER NOT NULL
      )
    ''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_audio_features_updated ON audio_features(updated_at)');
  }

  Future<void> _createSchema(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS songs (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        album TEXT,
        albumId TEXT,
        artist TEXT,
        artistId TEXT,
        track INTEGER,
        year INTEGER,
        genre TEXT,
        coverArt TEXT,
        duration INTEGER,
        bitRate INTEGER,
        suffix TEXT,
        contentType TEXT,
        size INTEGER,
        path TEXT,
        isLocal INTEGER DEFAULT 0,
        replayGainTrackGain REAL,
        replayGainAlbumGain REAL,
        replayGainTrackPeak REAL,
        replayGainAlbumPeak REAL,
        artistParticipants TEXT,
        created TEXT,
        starred INTEGER DEFAULT 0,
        userRating INTEGER,
        playCount INTEGER DEFAULT 0,
        disliked INTEGER DEFAULT 0,
        skipCount INTEGER DEFAULT 0,
        lastPlayed INTEGER,
        banned INTEGER DEFAULT 0,
        mood TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS albums (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        artist TEXT,
        artistId TEXT,
        coverArt TEXT,
        songCount INTEGER,
        duration INTEGER,
        year INTEGER,
        genre TEXT,
        created TEXT,
        isLocal INTEGER DEFAULT 0,
        artistParticipants TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS artists (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        coverArt TEXT,
        albumCount INTEGER,
        artistImageUrl TEXT,
        isLocal INTEGER DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS playlists (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        comment TEXT,
        owner TEXT,
        public INTEGER,
        songCount INTEGER,
        duration INTEGER,
        created TEXT,
        changed TEXT,
        coverArt TEXT,
        songIds TEXT
      )
    ''');

    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_song_albumId ON songs(albumId)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_song_artistId ON songs(artistId)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_album_artistId ON albums(artistId)');
    // v5 hybrid indexes
    await db.execute('CREATE INDEX IF NOT EXISTS idx_song_playCount ON songs(playCount)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_song_disliked ON songs(disliked)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_song_lastPlayed ON songs(lastPlayed)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_song_banned ON songs(banned)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_song_genre ON songs(genre)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_song_mood ON songs(mood)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_song_isLocal ON songs(isLocal)');
    // v9 search/sort indexes (П2)
    await db.execute('CREATE INDEX IF NOT EXISTS idx_song_title ON songs(title)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_song_artist ON songs(artist)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_song_album ON songs(album)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_song_created ON songs(created)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_queue_song_id ON queue(song_id)');

    // v4 tables
    await _createV4Tables(db);

    // v8: offline-first audio features cache
    await _createAudioFeaturesTable(db);
  }

  Future<void> _createV4Tables(Database db) async {
    // Queue — persistent playback queue (replaces SharedPreferences JSON blob)
    await db.execute('''
      CREATE TABLE IF NOT EXISTS queue (
        position INTEGER PRIMARY KEY,
        song_id TEXT NOT NULL,
        song_data TEXT NOT NULL
      )
    ''');

    // Song profiles — ML recommendation data (replaces SharedPreferences JSON blob)
    await db.execute('''
      CREATE TABLE IF NOT EXISTS song_profiles (
        song_id TEXT PRIMARY KEY,
        profile_data TEXT NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');

    // Mix cache — generated mix results (replaces SharedPreferences JSON blobs)
    await db.execute('''
      CREATE TABLE IF NOT EXISTS mix_cache (
        cache_key TEXT PRIMARY KEY,
        mix_type TEXT NOT NULL,
        mix_data TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');

    // App key-value — generic replacement for SharedPreferences
    await db.execute('''
      CREATE TABLE IF NOT EXISTS app_kv (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
  }

  // ── Batch inserts ───────────────────────────────────────────────────────

  // Без общей внешней транзакции: каждый чанк коммитится отдельно, замок
  // отпускается между чанками и читатели UI (getAllSongs) протискиваются.
  // Раньше один transaction на весь батч (5к песен) держал write-lock
  // секундами → «database has been locked» + ANR на старте.
  Future<void> insertSongsBatch(List<Song> songs) async {
    if (songs.isEmpty) return;
    final db = await database;
    for (var i = 0; i < songs.length; i += _batchSize) {
      final batch = db.batch();
      final end =
          (i + _batchSize < songs.length) ? i + _batchSize : songs.length;
      for (var j = i; j < end; j++) {
        batch.insert(
          'songs',
          _songToMap(songs[j]),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    }
  }

  Future<void> insertAlbumsBatch(List<Album> albums) async {
    if (albums.isEmpty) return;
    final db = await database;
    for (var i = 0; i < albums.length; i += _batchSize) {
      final batch = db.batch();
      final end =
          (i + _batchSize < albums.length) ? i + _batchSize : albums.length;
      for (var j = i; j < end; j++) {
        batch.insert(
          'albums',
          _albumToMap(albums[j]),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    }
  }

  Future<void> insertArtistsBatch(List<Artist> artists) async {
    if (artists.isEmpty) return;
    final db = await database;
    for (var i = 0; i < artists.length; i += _batchSize) {
      final batch = db.batch();
      final end = (i + _batchSize < artists.length)
          ? i + _batchSize
          : artists.length;
      for (var j = i; j < end; j++) {
        batch.insert(
          'artists',
          _artistToMap(artists[j]),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    }
  }

  Future<void> insertPlaylistsBatch(List<Playlist> playlists) async {
    if (playlists.isEmpty) return;
    final db = await database;
    for (var i = 0; i < playlists.length; i += _batchSize) {
      final batch = db.batch();
      final end = (i + _batchSize < playlists.length)
          ? i + _batchSize
          : playlists.length;
      for (var j = i; j < end; j++) {
        batch.insert(
          'playlists',
          _playlistToMap(playlists[j]),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    }
  }

  // ── Full-table queries (kept for backward-compat) ───────────────────────

  Future<List<Song>> getAllSongs() async {
    final db = await database;
    final maps = await db.query('songs');
    return maps.map((m) => _songFromMap(m)).toList();
  }

  Future<List<Album>> getAllAlbums() async {
    final db = await database;
    final maps = await db.query('albums');
    return maps.map((m) => _albumFromMap(m)).toList();
  }

  Future<List<Artist>> getAllArtists() async {
    final db = await database;
    final maps = await db.query('artists');
    return maps.map((m) => _artistFromMap(m)).toList();
  }

  Future<List<Playlist>> getAllPlaylists() async {
    final db = await database;
    final maps = await db.query('playlists');
    return maps.map((m) => _playlistFromMap(m)).toList();
  }

  // ── Paginated / low-memory queries ──────────────────────────────────────

  Future<List<Song>> getSongsPaginated({int limit = 500, int offset = 0}) async {
    final db = await database;
    final maps = await db.query('songs', limit: limit, offset: offset);
    return maps.map((m) => _songFromMap(m)).toList();
  }

  Future<List<Album>> getAlbumsPaginated({int limit = 500, int offset = 0}) async {
    final db = await database;
    final maps = await db.query('albums', limit: limit, offset: offset);
    return maps.map((m) => _albumFromMap(m)).toList();
  }

  Future<List<Artist>> getArtistsPaginated({int limit = 500, int offset = 0}) async {
    final db = await database;
    final maps = await db.query('artists', limit: limit, offset: offset);
    return maps.map((m) => _artistFromMap(m)).toList();
  }

  // ── П1+П3: легкие колонки для списков + стабильная сортировка в SQL ────
  // Полный Song нужен только на плеере; спискам хватает id/title/artist/album/cover/duration.
  static const List<String> lightSongColumns = [
    'id', 'title', 'artist', 'artistId', 'album', 'albumId',
    'coverArt', 'duration', 'genre', 'mood', 'year', 'track', 'isLocal',
  ];

  Song _songFromMapLight(Map<String, dynamic> m) {
    return Song(
      id: m['id'] as String,
      title: m['title'] as String? ?? 'Unknown',
      artist: m['artist'] as String?,
      artistId: m['artistId'] as String?,
      album: m['album'] as String?,
      albumId: m['albumId'] as String?,
      coverArt: m['coverArt'] as String?,
      duration: m['duration'] as int?,
      genre: m['genre'] as String?,
      mood: m['mood'] as String?,
      year: m['year'] as int?,
      track: m['track'] as int?,
      isLocal: (m['isLocal'] as int?) == 1,
    );
  }

  static const Map<String, String> _songSortOrders = {
    'titleAsc': 'title COLLATE NOCASE ASC',
    'titleDesc': 'title COLLATE NOCASE DESC',
    'artistAsc': 'artist COLLATE NOCASE ASC, title COLLATE NOCASE ASC',
    'artistDesc': 'artist COLLATE NOCASE DESC, title COLLATE NOCASE ASC',
    'albumAsc': 'album COLLATE NOCASE ASC, track ASC',
    'albumDesc': 'album COLLATE NOCASE DESC, track ASC',
    'recent': 'created DESC',
  };

  Future<List<Song>> getSongsLightPaginated({
    int limit = 200,
    int offset = 0,
    String sort = 'titleAsc',
  }) async {
    final db = await database;
    final orderBy = _songSortOrders[sort] ?? _songSortOrders['titleAsc']!;
    final maps = await db.query(
      'songs',
      columns: lightSongColumns,
      orderBy: orderBy,
      limit: limit,
      offset: offset,
    );
    return maps.map(_songFromMapLight).toList();
  }

  // ── П2: поиск/фильтр в SQL, не в Dart ──────────────────────────────────
  Future<List<Song>> searchSongs(String query, {int limit = 50}) async {
    final q = query.trim();
    if (q.isEmpty) return [];
    final db = await database;
    // Префиксный LIKE идет по индексу; '%q%' — скан, но в SQL а не в UI-списке 80к.
    final likePre = '$q%';
    final likeAny = '%$q%';
    final maps = await db.rawQuery(
      '''SELECT ${lightSongColumns.join(',')} FROM songs
         WHERE title LIKE ? OR artist LIKE ? OR album LIKE ?
            OR title LIKE ? OR artist LIKE ? OR album LIKE ?
         ORDER BY
           CASE WHEN title LIKE ? THEN 0 WHEN artist LIKE ? THEN 1 ELSE 2 END,
           title COLLATE NOCASE ASC
         LIMIT ?''',
      [likePre, likePre, likePre, likeAny, likeAny, likeAny, likePre, likePre, limit],
    );
    return maps.map(_songFromMapLight).toList();
  }

  Future<List<Song>> getSongsByAlbumId(String albumId, {int limit = 500, int offset = 0}) async {
    final db = await database;
    final maps = await db.query(
      'songs',
      columns: lightSongColumns,
      where: 'albumId = ?',
      whereArgs: [albumId],
      orderBy: 'track ASC, title COLLATE NOCASE ASC',
      limit: limit,
      offset: offset,
    );
    return maps.map(_songFromMapLight).toList();
  }

  Future<List<Song>> getSongsByArtistId(String artistId, {int limit = 500, int offset = 0}) async {
    final db = await database;
    final maps = await db.query(
      'songs',
      columns: lightSongColumns,
      where: 'artistId = ?',
      whereArgs: [artistId],
      orderBy: 'year ASC, album COLLATE NOCASE ASC, track ASC',
      limit: limit,
      offset: offset,
    );
    return maps.map(_songFromMapLight).toList();
  }

  // ── Второй заход: точечные SQL для экранов (без cachedAllSongs) ──────
  Future<List<Map<String, dynamic>>> getGenreStats() async {
    final db = await database;
    return db.rawQuery(
      '''SELECT genre AS genre, COUNT(*) AS cnt, MAX(coverArt) AS cover
         FROM songs WHERE genre IS NOT NULL AND TRIM(genre) != ''
         GROUP BY genre ORDER BY cnt DESC''',
    );
  }

  Future<List<Song>> getSongsByGenreSample(
    String genre, {
    String? excludeArtistId,
    int limit = 60,
  }) async {
    final db = await database;
    if (excludeArtistId != null) {
      final maps = await db.query(
        'songs',
        columns: lightSongColumns,
        where: 'genre = ? AND (artistId IS NULL OR artistId != ?)',
        whereArgs: [genre, excludeArtistId],
        orderBy: 'RANDOM()',
        limit: limit,
      );
      return maps.map(_songFromMapLight).toList();
    }
    final maps = await db.query(
      'songs',
      columns: lightSongColumns,
      where: 'genre = ?',
      whereArgs: [genre],
      orderBy: 'RANDOM()',
      limit: limit,
    );
    return maps.map(_songFromMapLight).toList();
  }

  Future<List<String>> getArtistIdsByGenre(String genre, {int limit = 5}) async {
    final db = await database;
    final rows = await db.rawQuery(
      '''SELECT DISTINCT artistId FROM songs
         WHERE genre = ? AND artistId IS NOT NULL LIMIT ?''',
      [genre, limit],
    );
    return rows.map((r) => r['artistId'] as String).toList();
  }

  /// Легкий скан для офлайна: только id/path/isLocal, чанками.
  Future<List<Map<String, dynamic>>> getSongsForOfflineScan({
    int limit = 2000,
    int offset = 0,
  }) async {
    final db = await database;
    return db.query(
      'songs',
      columns: const ['id', 'path', 'isLocal'],
      limit: limit,
      offset: offset,
    );
  }

  // ── Третий заход: рабочий набор вместо 80к в RAM ────────────────────
  // Случайная выборка полных песен для рабочего набора провайдера и пулов.
  Future<List<Song>> getRandomSongsSample({int limit = 800}) async {
    final db = await database;
    final maps = await db.query('songs', orderBy: 'RANDOM()', limit: limit);
    return maps.map(_songFromMap).toList();
  }

  Future<Map<String, int>> getAlbumPlayCounts() async {
    final db = await database;
    final rows = await db.rawQuery(
      '''SELECT albumId AS albumId, SUM(COALESCE(playCount, 0)) AS pc
         FROM songs WHERE albumId IS NOT NULL GROUP BY albumId''',
    );
    return {
      for (final r in rows) (r['albumId'] as String): (r['pc'] as int?) ?? 0,
    };
  }

  Future<Map<String, int>> getLibraryStats() async {
    final db = await database;
    final rows = await db.rawQuery(
      '''SELECT COUNT(*) AS total,
         SUM(CASE WHEN genre IS NOT NULL AND TRIM(genre) != '' THEN 1 ELSE 0 END) AS withGenre,
         SUM(CASE WHEN mood IS NOT NULL AND TRIM(mood) != '' THEN 1 ELSE 0 END) AS withMood
         FROM songs''',
    );
    final r = rows.first;
    return {
      'total': (r['total'] as int?) ?? 0,
      'withGenre': (r['withGenre'] as int?) ?? 0,
      'withMood': (r['withMood'] as int?) ?? 0,
    };
  }

  Future<Map<String, int>> getStorageStats() async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS total, SUM(size) AS size, SUM(duration) AS duration FROM songs',
    );
    final r = rows.first;
    return {
      'total': (r['total'] as int?) ?? 0,
      'size': (r['size'] as int?) ?? 0,
      'duration': (r['duration'] as int?) ?? 0,
    };
  }

  static const List<String> _ratingScanColumns = [
    'id', 'title', 'artist', 'userRating', 'playCount',
    'lastPlayed', 'starred', 'disliked',
  ];

  /// Чанковый скан рейтинговых полей для ML-импорта (без 80к объектов в RAM).
  Future<List<Map<String, dynamic>>> getSongsRatingScan({
    int limit = 2000,
    int offset = 0,
  }) async {
    final db = await database;
    return db.query('songs', columns: _ratingScanColumns, limit: limit, offset: offset);
  }

  Future<Song?> getSongById(String id, {bool light = false}) async {
    final db = await database;
    final maps = await db.query(
      'songs',
      columns: light ? lightSongColumns : null,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return light ? _songFromMapLight(maps.first) : _songFromMap(maps.first);
  }

  Future<List<Song>> getSongsByIds(List<String> ids, {bool light = true}) async {
    if (ids.isEmpty) return [];
    final db = await database;
    final out = <Song>[];
    // Чанки по 500 для IN-запроса; порядок очереди восстанавливает вызывающий.
    for (var i = 0; i < ids.length; i += 500) {
      final end = (i + 500 < ids.length) ? i + 500 : ids.length;
      final chunk = ids.sublist(i, end);
      final ph = List.filled(chunk.length, '?').join(',');
      final maps = await db.query(
        'songs',
        columns: light ? lightSongColumns : null,
        where: 'id IN ($ph)',
        whereArgs: chunk,
      );
      final byId = <String, Song>{};
      for (final m in maps) {
        final s = light ? _songFromMapLight(m) : _songFromMap(m);
        byId[s.id] = s;
      }
      for (final id in chunk) {
        final s = byId[id];
        if (s != null) out.add(s);
      }
    }
    return out;
  }

  Future<int> getSongCount() async {
    final db = await database;
    final result = await db.rawQuery('SELECT COUNT(*) FROM songs');
    return Sqflite.firstIntValue(result) ?? 0;
  }

  Future<int> getAlbumCount() async {
    final db = await database;
    final result = await db.rawQuery('SELECT COUNT(*) FROM albums');
    return Sqflite.firstIntValue(result) ?? 0;
  }

  Future<int> getArtistCount() async {
    final db = await database;
    final result = await db.rawQuery('SELECT COUNT(*) FROM artists');
    return Sqflite.firstIntValue(result) ?? 0;
  }

  // ── Hybrid ML queries: DB for coarse filters (2-5k pool for in-memory scoring) ──

  // П4: было 5000 — роняет isolate/heap на 80к. 800 хватает:
  // разнообразие дает RANDOM-сэмпл каждый вызов, а не размер пула.
  Future<List<Song>> getNotPlayedSongs({int limit = 800, int offset = 0}) async {
    final db = await database;
    final maps = await db.query('songs',
        where: '(playCount IS NULL OR playCount = 0) AND (disliked IS NULL OR disliked = 0) AND (banned IS NULL OR banned = 0)',
        limit: limit,
        offset: offset);
    return maps.map((m) => _songFromMap(m)).toList();
  }

  Future<List<Song>> getPlayedSongs({int limit = 800, int offset = 0}) async {
    final db = await database;
    final maps = await db.query('songs', where: 'playCount > 0', limit: limit, offset: offset);
    return maps.map((m) => _songFromMap(m)).toList();
  }

  Future<List<Song>> getDislikedSongs({int limit = 800, int offset = 0}) async {
    final db = await database;
    final maps = await db.query('songs', where: 'disliked = 1', limit: limit, offset: offset);
    return maps.map((m) => _songFromMap(m)).toList();
  }

  Future<List<Song>> getSongsByGenreHybrid(String genre, {int limit = 600, int offset = 0}) async {
    final db = await database;
    final maps = await db.query('songs',
        where: 'genre = ? AND (disliked IS NULL OR disliked = 0) AND (banned IS NULL OR banned = 0)',
        whereArgs: [genre],
        limit: limit,
        offset: offset);
    return maps.map((m) => _songFromMap(m)).toList();
  }

  // П4: было 2000. Меньший пул + RANDOM каждый вызов = то же разнообразие,
  // но без OOM. Для миксов используй getSongsForMixStratified ниже.
  Future<List<Song>> getSongsForMix({String? genre, String? mood, String? excludeArtistId, int limit = 600}) async {
    final db = await database;
    final whereClauses = <String>['(disliked IS NULL OR disliked = 0)', '(banned IS NULL OR banned = 0)'];
    final args = <Object?>[];
    if (genre != null) {
      whereClauses.add('genre = ?');
      args.add(genre);
    }
    if (mood != null) {
      whereClauses.add('mood = ?');
      args.add(mood);
    }
    if (excludeArtistId != null) {
      whereClauses.add('artistId != ?');
      args.add(excludeArtistId);
    }
    final where = whereClauses.join(' AND ');
    // Prefer not-played first, then fill with played — two queries
    final notPlayed = await db.query('songs', where: '$where AND (playCount IS NULL OR playCount = 0)', whereArgs: args, limit: limit, orderBy: 'RANDOM()');
    if (notPlayed.length >= limit) {
      return notPlayed.map((m) => _songFromMap(m)).toList();
    }
    final remaining = limit - notPlayed.length;
    final played = await db.query('songs', where: '$where AND playCount > 0', whereArgs: args, limit: remaining, orderBy: 'RANDOM()');
    return [...notPlayed, ...played].map((m) => _songFromMap(m)).toList();
  }

  // П4: стратифицированный пул для миксов — разнообразие без 80к в RAM.
  // Вместо одного LIMIT 2000 делаем 4 независимых RANDOM-сэмпла
  // (неигранные / жанр / настроение / свежие) и склеиваем без дублей.
  // Каждый вызов дает разный набор за счет ORDER BY RANDOM().
  Future<List<Song>> getSongsForMixStratified({
    String? genre,
    String? mood,
    String? excludeArtistId,
    int limit = 600,
    List<String> excludeIds = const [],
  }) async {
    final db = await database;
    final perBucket = (limit / 3).ceil();
    final baseFilter = <String>[
      '(disliked IS NULL OR disliked = 0)',
      '(banned IS NULL OR banned = 0)',
    ];
    final baseArgs = <Object?>[];
    if (excludeArtistId != null) {
      baseFilter.add('artistId != ?');
      baseArgs.add(excludeArtistId);
    }
    if (excludeIds.isNotEmpty) {
      final capped = excludeIds.length > 300 ? excludeIds.sublist(0, 300) : excludeIds;
      baseFilter.add('id NOT IN (${List.filled(capped.length, '?').join(',')})');
      baseArgs.addAll(capped);
    }
    final baseWhere = baseFilter.join(' AND ');
    final seen = <String>{};
    final out = <Song>[];

    Future<void> addBucket(String extraWhere, List<Object?> extraArgs) async {
      if (out.length >= limit) return;
      final where = extraWhere.isEmpty ? baseWhere : '$baseWhere AND $extraWhere';
      final args = [...baseArgs, ...extraArgs];
      final maps = await db.query(
        'songs',
        columns: lightSongColumns,
        where: where,
        whereArgs: args,
        orderBy: 'RANDOM()',
        limit: perBucket,
      );
      for (final m in maps) {
        final s = _songFromMapLight(m);
        if (seen.add(s.id)) out.add(s);
        if (out.length >= limit) break;
      }
    }

    await addBucket('(playCount IS NULL OR playCount = 0)', []);
    if (genre != null) await addBucket('genre = ?', [genre]);
    if (mood != null) await addBucket('mood = ?', [mood]);
    if (out.length < limit) await addBucket('', []);
    return out;
  }

  Future<List<Song>> getSongsByMoodHybrid(String mood, {int limit = 600, int offset = 0}) async {
    final db = await database;
    final maps = await db.query('songs',
        where: 'mood = ? AND (disliked IS NULL OR disliked = 0) AND (banned IS NULL OR banned = 0)',
        whereArgs: [mood],
        limit: limit,
        offset: offset);
    if (maps.isNotEmpty) return maps.map((m) => _songFromMap(m)).toList();
    // Fallback: genre contains mood string (некоторые серверы пишут настроение в genre)
    final fallback = await db.query('songs',
        where: 'genre LIKE ? AND (disliked IS NULL OR disliked = 0) AND (banned IS NULL OR banned = 0)',
        whereArgs: ['%$mood%'],
        limit: limit,
        offset: offset);
    return fallback.map((m) => _songFromMap(m)).toList();
  }

  Future<void> updateSongMood(String songId, String? mood) async {
    final db = await database;
    await db.update('songs', {'mood': mood}, where: 'id = ?', whereArgs: [songId]);
  }

  Future<void> updateSongMoodBatch(Map<String, String?> moods) async {
    if (moods.isEmpty) return;
    final db = await database;
    await db.transaction((txn) async {
      for (final e in moods.entries) {
        await txn.update('songs', {'mood': e.value}, where: 'id = ?', whereArgs: [e.key]);
      }
    });
  }

  /// Честный счётчик настроений для UI (сколько песен реально имеют mood).
  Future<int> countSongsWithMood() async {
    try {
      final db = await database;
      final r = await db.rawQuery(
          "SELECT COUNT(*) AS c FROM songs WHERE mood IS NOT NULL AND mood != ''");
      if (r.isEmpty) return 0;
      final v = r.first['c'];
      if (v is num) return v.toInt();
      return int.tryParse('$v') ?? 0;
    } catch (_) {
      return 0;
    }
  }

  Future<void> updateSongPlayStatus(String songId, {int? playCount, bool? disliked, int? skipCount, int? lastPlayed, bool? banned, bool? starred, int? userRating}) async {
    final db = await database;
    final values = <String, Object?>{};
    if (playCount != null) values['playCount'] = playCount;
    if (disliked != null) values['disliked'] = disliked ? 1 : 0;
    if (skipCount != null) values['skipCount'] = skipCount;
    if (lastPlayed != null) values['lastPlayed'] = lastPlayed;
    if (banned != null) values['banned'] = banned ? 1 : 0;
    if (starred != null) values['starred'] = starred ? 1 : 0;
    if (userRating != null) values['userRating'] = userRating;
    if (values.isEmpty) return;
    await db.update('songs', values, where: 'id = ?', whereArgs: [songId]);
  }

  /// Поблочные апдейты: один огромный транзакционный апдейт на всю
  /// библиотеку держал замок БД по 10+с («database has been locked» +
  /// фриз UI, факт 15.10.2026: ML-импорт одним батчем). Чанки по 500
  /// с уступкой event loop между ними — читатели UI проходят в паузах.
  Future<void> updateSongPlayStatusBatch(List<Map<String, dynamic>> updates) async {
    if (updates.isEmpty) return;
    final db = await database;
    const chunk = 500;
    for (var i = 0; i < updates.length; i += chunk) {
      final end = (i + chunk < updates.length) ? i + chunk : updates.length;
      await db.transaction((txn) async {
        for (var j = i; j < end; j++) {
          final u = updates[j];
          final id = u['id'] as String;
          final values = Map<String, Object?>.from(u)..remove('id');
          if (values.isEmpty) continue;
          await txn.update('songs', values, where: 'id = ?', whereArgs: [id]);
        }
      });
      // Уступка: замок отпущен, читатели и тапы проходят между чанками.
      await Future.delayed(Duration.zero);
    }
  }

  Future<void> setBannedForArtists(Set<String> artistIds, bool banned) async {
    if (artistIds.isEmpty) return;
    final db = await database;
    final placeholders = List.filled(artistIds.length, '?').join(',');
    await db.rawUpdate('UPDATE songs SET banned = ? WHERE artistId IN ($placeholders)', [banned ? 1 : 0, ...artistIds]);
    // Also handle artist name bans via artist field (fallback)
  }

  Future<void> setBannedForArtistNames(Set<String> artistNames, bool banned) async {
    if (artistNames.isEmpty) return;
    final db = await database;
    // Case-insensitive match on artist column
    for (final name in artistNames) {
      await db.rawUpdate('UPDATE songs SET banned = ? WHERE LOWER(artist) = LOWER(?)', [banned ? 1 : 0, name]);
    }
  }

  // ── Audio features (offline-first vibe cache, v8) ────────────────────

  static const List<String> _audioFeatureCols = [
    'bpm',
    'energy',
    'valence',
    'danceability',
    'acousticness',
    'instrumentalness',
  ];

  Future<Map<String, double>?> getAudioFeatures(String songId) async {
    final db = await database;
    final rows = await db.query(
      'audio_features',
      where: 'song_id = ?',
      whereArgs: [songId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _audioFeaturesFromRow(rows.first);
  }

  /// Batch read; [ids] are chunked into 500-id IN queries.
  Future<Map<String, Map<String, double>>> getAudioFeaturesBatch(
    List<String> ids,
  ) async {
    final out = <String, Map<String, double>>{};
    if (ids.isEmpty) return out;
    final db = await database;
    for (var i = 0; i < ids.length; i += 500) {
      final end = (i + 500 < ids.length) ? i + 500 : ids.length;
      final chunk = ids.sublist(i, end);
      final placeholders = List.filled(chunk.length, '?').join(',');
      final rows = await db.query(
        'audio_features',
        where: 'song_id IN ($placeholders)',
        whereArgs: chunk,
      );
      for (final r in rows) {
        out[r['song_id'] as String] = _audioFeaturesFromRow(r);
      }
    }
    return out;
  }

  Map<String, double> _audioFeaturesFromRow(Map<String, dynamic> row) {
    final m = <String, double>{};
    for (final c in _audioFeatureCols) {
      final v = row[c];
      if (v != null) m[c] = (v as num).toDouble();
    }
    return m;
  }

  Future<void> saveAudioFeatures(
    String songId,
    Map<String, double?> features, {
    String source = 'genre',
  }) async {
    final db = await database;
    final row = <String, Object?>{
      'song_id': songId,
      'source': source,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    };
    for (final c in _audioFeatureCols) {
      row[c] = features[c];
    }
    await db.insert(
      'audio_features',
      row,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> saveAudioFeaturesBatch(
    Map<String, Map<String, double?>> entries, {
    String source = 'genre',
  }) async {
    if (entries.isEmpty) return;
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      final list = entries.entries.toList();
      for (var i = 0; i < list.length; i += _batchSize) {
        final batch = txn.batch();
        final end =
            (i + _batchSize < list.length) ? i + _batchSize : list.length;
        for (var j = i; j < end; j++) {
          final row = <String, Object?>{
            'song_id': list[j].key,
            'source': source,
            'updated_at': now,
          };
          for (final c in _audioFeatureCols) {
            row[c] = list[j].value[c];
          }
          batch.insert(
            'audio_features',
            row,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        await batch.commit(noResult: true);
      }
    });
  }

  /// Drop feature rows whose song no longer exists (server switch / resync).
  Future<void> pruneAudioFeatures() async {
    try {
      final db = await database;
      await db.rawDelete(
        'DELETE FROM audio_features WHERE song_id NOT IN (SELECT id FROM songs)',
      );
    } catch (_) {}
  }

  Future<void> clearAudioFeatures() async {
    final db = await database;
    await db.delete('audio_features');
  }

  Future<int> getAudioFeaturesCount() async {
    final db = await database;
    final result = await db.rawQuery('SELECT COUNT(*) FROM audio_features');
    return Sqflite.firstIntValue(result) ?? 0;
  }

  // ── Destructive operations ────────────────────────────────────────────

  Future<void> clearAll() async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('songs');
      await txn.delete('albums');
      await txn.delete('artists');
      await txn.delete('playlists');
    });
  }

  /// Clear only server-side data, preserving local library entries.
  Future<void> clearServerData() async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('songs', where: 'isLocal = ?', whereArgs: [0]);
      await txn.delete('albums', where: 'isLocal = ?', whereArgs: [0]);
      await txn.delete('artists', where: 'isLocal = ?', whereArgs: [0]);
      await txn.delete('playlists');
    });
    await pruneAudioFeatures();
  }

  Future<List<Song>> getLocalSongs() async {
    final db = await database;
    final maps = await db.query('songs', where: 'isLocal = ?', whereArgs: [1]);
    return maps.map((m) => _songFromMap(m)).toList();
  }

  Future<void> close() async {
    if (_db != null) {
      await _db!.close();
      _db = null;
    }
  }

  // ── Queue persistence ────────────────────────────────────────────────

  Future<void> saveQueue(List<Map<String, dynamic>> songs, int currentIndex, String currentSongId, int positionMs) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('queue');
      if (songs.isNotEmpty) {
        for (var i = 0; i < songs.length; i += _batchSize) {
          final batch = txn.batch();
          final end = (i + _batchSize < songs.length) ? i + _batchSize : songs.length;
          for (var j = i; j < end; j++) {
            batch.insert('queue', {
              'position': j,
              'song_id': songs[j]['id'] as String,
              'song_data': jsonEncode(songs[j]),
            });
          }
          await batch.commit(noResult: true);
        }
      }
      // Store queue metadata in app_kv
      await txn.insert('app_kv', {'key': 'queue_index', 'value': '$currentIndex'}, conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.insert('app_kv', {'key': 'queue_song_id', 'value': currentSongId}, conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.insert('app_kv', {'key': 'queue_position', 'value': '$positionMs'}, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  Future<Map<String, dynamic>?> loadQueue() async {
    final db = await database;
    final rows = await db.query('queue', orderBy: 'position ASC');
    if (rows.isEmpty) return null;
    final songs = rows.map((r) => jsonDecode(r['song_data'] as String) as Map<String, dynamic>).toList();
    final indexStr = await _getKv('queue_index');
    final songId = await _getKv('queue_song_id');
    final posStr = await _getKv('queue_position');
    return {
      'songs': songs,
      'index': int.tryParse(indexStr ?? '0') ?? 0,
      'songId': songId ?? '',
      'position': int.tryParse(posStr ?? '0') ?? 0,
    };
  }

  Future<void> clearQueue() async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('queue');
      await txn.delete('app_kv', where: "key LIKE 'queue_%'");
    });
  }

  // ── П5: очередь как song_id + position (без полного song_data JSON) ────
  // Старый saveQueue писал jsonEncode(full Song) в каждую строку — дубль
  // библиотеки + рассинхрон starred/playCount. Новый путь хранит только id,
  // при загрузке гидрирует из songs (единый источник правды).
  // song_data пишем '' (не NULL — таблица создана с NOT NULL), loadQueue
  // такие строки пропускает по-старому пути и идет через loadQueueIds.
  Future<void> saveQueueIds(
    List<String> songIds,
    int currentIndex,
    String currentSongId,
    int positionMs,
  ) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('queue');
      if (songIds.isNotEmpty) {
        for (var i = 0; i < songIds.length; i += _batchSize) {
          final batch = txn.batch();
          final end = (i + _batchSize < songIds.length) ? i + _batchSize : songIds.length;
          for (var j = i; j < end; j++) {
            batch.insert('queue', {
              'position': j,
              'song_id': songIds[j],
              'song_data': '',
            });
          }
          await batch.commit(noResult: true);
        }
      }
      await txn.insert('app_kv', {'key': 'queue_index', 'value': '$currentIndex'},
          conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.insert('app_kv', {'key': 'queue_song_id', 'value': currentSongId},
          conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.insert('app_kv', {'key': 'queue_position', 'value': '$positionMs'},
          conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  Future<Map<String, dynamic>?> loadQueueIds() async {
    final db = await database;
    final rows = await db.query('queue', columns: ['position', 'song_id'], orderBy: 'position ASC');
    if (rows.isEmpty) return null;
    final ids = rows.map((r) => r['song_id'] as String).toList();
    final indexStr = await _getKv('queue_index');
    final songId = await _getKv('queue_song_id');
    final posStr = await _getKv('queue_position');
    return {
      'ids': ids,
      'index': int.tryParse(indexStr ?? '0') ?? 0,
      'songId': songId ?? '',
      'position': int.tryParse(posStr ?? '0') ?? 0,
    };
  }

  /// Гидрация очереди из songs по id с сохранением порядка.
  Future<List<Song>> resolveQueueSongs(List<String> ids, {bool light = true}) {
    return getSongsByIds(ids, light: light);
  }

  // ── Song profiles (ML) ───────────────────────────────────────────────

  Future<void> saveSongProfile(String songId, Map<String, dynamic> profile) async {
    final db = await database;
    await db.insert('song_profiles', {
      'song_id': songId,
      'profile_data': jsonEncode(profile),
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> saveSongProfilesBatch(List<Map<String, dynamic>> entries) async {
    if (entries.isEmpty) return;
    final db = await database;
    await db.transaction((txn) async {
      for (var i = 0; i < entries.length; i += _batchSize) {
        final batch = txn.batch();
        final end = (i + _batchSize < entries.length) ? i + _batchSize : entries.length;
        for (var j = i; j < end; j++) {
          batch.insert('song_profiles', {
            'song_id': entries[j]['id'],
            'profile_data': jsonEncode(entries[j]['profile']),
            'updated_at': DateTime.now().millisecondsSinceEpoch,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
        await batch.commit(noResult: true);
      }
    });
  }

  Future<Map<String, Map<String, dynamic>>> loadAllSongProfiles() async {
    final db = await database;
    final rows = await db.query('song_profiles');
    final result = <String, Map<String, dynamic>>{};
    for (final r in rows) {
      final id = r['song_id'] as String;
      final data = jsonDecode(r['profile_data'] as String) as Map<String, dynamic>;
      result[id] = data;
    }
    return result;
  }

  Future<void> clearSongProfiles() async {
    final db = await database;
    await db.delete('song_profiles');
  }

  // ── Mix cache ────────────────────────────────────────────────────────

  Future<void> saveMixCache(String cacheKey, String mixType, Map<String, dynamic> data) async {
    final db = await database;
    await db.insert('mix_cache', {
      'cache_key': cacheKey,
      'mix_type': mixType,
      'mix_data': jsonEncode(data),
      'created_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Map<String, dynamic>?> loadMixCache(String cacheKey) async {
    final db = await database;
    final rows = await db.query('mix_cache', where: 'cache_key = ?', whereArgs: [cacheKey]);
    if (rows.isEmpty) return null;
    return jsonDecode(rows.first['mix_data'] as String) as Map<String, dynamic>;
  }

  Future<void> clearMixCache() async {
    final db = await database;
    await db.delete('mix_cache');
  }

  Future<void> deleteMixCache(String cacheKey) async {
    final db = await database;
    await db.delete('mix_cache', where: 'cache_key = ?', whereArgs: [cacheKey]);
  }

  // ── App key-value ────────────────────────────────────────────────────

  Future<void> setKv(String key, String value) async {
    final db = await database;
    await db.insert('app_kv', {'key': key, 'value': value}, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<String?> getKv(String key) async {
    return _getKv(key);
  }

  Future<String?> _getKv(String key) async {
    final db = await database;
    final rows = await db.query('app_kv', where: 'key = ?', whereArgs: [key]);
    if (rows.isEmpty) return null;
    return rows.first['value'] as String?;
  }

  Future<void> removeKv(String key) async {
    final db = await database;
    await db.delete('app_kv', where: 'key = ?', whereArgs: [key]);
  }

  // ── Helpers: Song ───────────────────────────────────────────────────────

  Map<String, dynamic> _songToMap(Song song) {
    return {
      'id': song.id,
      'title': song.title,
      'album': song.album,
      'albumId': song.albumId,
      'artist': song.artist,
      'artistId': song.artistId,
      'track': song.track,
      'year': song.year,
      'genre': song.genre,
      'mood': song.mood,
      'coverArt': song.coverArt,
      'duration': song.duration,
      'bitRate': song.bitRate,
      'suffix': song.suffix,
      'contentType': song.contentType,
      'size': song.size,
      'path': song.path,
      'isLocal': song.isLocal ? 1 : 0,
      'replayGainTrackGain': song.replayGainTrackGain,
      'replayGainAlbumGain': song.replayGainAlbumGain,
      'replayGainTrackPeak': song.replayGainTrackPeak,
      'replayGainAlbumPeak': song.replayGainAlbumPeak,
      'artistParticipants': song.artistParticipants != null
          ? jsonEncode(
              song.artistParticipants!.map((a) => a.toJson()).toList(),
            )
          : null,
      'created': song.created?.toIso8601String(),
      'starred': song.starred == true ? 1 : 0,
      'userRating': song.userRating,
      'playCount': song.playCount ?? 0,
      'lastPlayed': song.played != null ? DateTime.tryParse(song.played!)?.millisecondsSinceEpoch : null,
    };
  }

  Song _songFromMap(Map<String, dynamic> m) {
    final participantsJson = m['artistParticipants'] as String?;
    return Song(
      id: m['id'] as String,
      title: m['title'] as String,
      album: m['album'] as String?,
      albumId: m['albumId'] as String?,
      artist: m['artist'] as String?,
      artistId: m['artistId'] as String?,
      track: m['track'] as int?,
      year: m['year'] as int?,
      genre: m['genre'] as String?,
      mood: m['mood'] as String?,
      coverArt: m['coverArt'] as String?,
      duration: m['duration'] as int?,
      bitRate: m['bitRate'] as int?,
      suffix: m['suffix'] as String?,
      contentType: m['contentType'] as String?,
      size: m['size'] as int?,
      path: m['path'] as String?,
      isLocal: (m['isLocal'] as int?) == 1,
      replayGainTrackGain: m['replayGainTrackGain'] as double?,
      replayGainAlbumGain: m['replayGainAlbumGain'] as double?,
      replayGainTrackPeak: m['replayGainTrackPeak'] as double?,
      replayGainAlbumPeak: m['replayGainAlbumPeak'] as double?,
      artistParticipants: participantsJson != null
          ? ArtistRef.parseList(jsonDecode(participantsJson))
          : null,
      created: m['created'] != null
          ? DateTime.tryParse(m['created'] as String)
          : null,
      starred: (m['starred'] as int?) == 1,
      userRating: m['userRating'] as int?,
      playCount: m['playCount'] as int?,
      played: m['lastPlayed'] != null ? DateTime.fromMillisecondsSinceEpoch(m['lastPlayed'] as int).toIso8601String() : null,
    );
  }

  // ── Helpers: Album ──────────────────────────────────────────────────────

  Map<String, dynamic> _albumToMap(Album album) {
    return {
      'id': album.id,
      'name': album.name,
      'artist': album.artist,
      'artistId': album.artistId,
      'coverArt': album.coverArt,
      'songCount': album.songCount,
      'duration': album.duration,
      'year': album.year,
      'genre': album.genre,
      'created': album.created?.toIso8601String(),
      'isLocal': album.isLocal ? 1 : 0,
      'artistParticipants': album.artistParticipants != null
          ? jsonEncode(
              album.artistParticipants!.map((a) => a.toJson()).toList(),
            )
          : null,
    };
  }

  Album _albumFromMap(Map<String, dynamic> m) {
    final participantsJson = m['artistParticipants'] as String?;
    return Album(
      id: m['id'] as String,
      name: m['name'] as String,
      artist: m['artist'] as String?,
      artistId: m['artistId'] as String?,
      coverArt: m['coverArt'] as String?,
      songCount: m['songCount'] as int?,
      duration: m['duration'] as int?,
      year: m['year'] as int?,
      genre: m['genre'] as String?,
      created: m['created'] != null
          ? DateTime.tryParse(m['created'] as String)
          : null,
      isLocal: (m['isLocal'] as int?) == 1,
      artistParticipants: participantsJson != null
          ? ArtistRef.parseList(jsonDecode(participantsJson))
          : null,
    );
  }

  // ── Helpers: Artist ─────────────────────────────────────────────────────

  Map<String, dynamic> _artistToMap(Artist artist) {
    return {
      'id': artist.id,
      'name': artist.name,
      'coverArt': artist.coverArt,
      'albumCount': artist.albumCount,
      'artistImageUrl': artist.artistImageUrl,
      'isLocal': artist.isLocal ? 1 : 0,
    };
  }

  Artist _artistFromMap(Map<String, dynamic> m) {
    return Artist(
      id: m['id'] as String,
      name: m['name'] as String,
      coverArt: m['coverArt'] as String?,
      albumCount: m['albumCount'] as int?,
      artistImageUrl: m['artistImageUrl'] as String?,
      isLocal: (m['isLocal'] as int?) == 1,
    );
  }

  // ── Helpers: Playlist ─────────────────────────────────────────────────

  Map<String, dynamic> _playlistToMap(Playlist playlist) {
    return {
      'id': playlist.id,
      'name': playlist.name,
      'comment': playlist.comment,
      'owner': playlist.owner,
      'public': playlist.public == true ? 1 : 0,
      'songCount': playlist.songCount,
      'duration': playlist.duration,
      'created': playlist.created?.toIso8601String(),
      'changed': playlist.changed?.toIso8601String(),
      'coverArt': playlist.coverArt,
      'songIds': playlist.songs?.map((s) => s.id).toList().join(','),
    };
  }

  Playlist _playlistFromMap(Map<String, dynamic> m) {
    final songIdsStr = m['songIds'] as String?;
    List<Song>? songList;
    if (songIdsStr != null && songIdsStr.isNotEmpty) {
      songList = songIdsStr
          .split(',')
          .map((id) => Song(id: id, title: 'Unknown'))
          .toList();
    }
    return Playlist(
      id: m['id'] as String,
      name: m['name'] as String,
      comment: m['comment'] as String?,
      owner: m['owner'] as String?,
      public: (m['public'] as int?) == 1,
      songCount: m['songCount'] as int?,
      duration: m['duration'] as int?,
      created: m['created'] != null
          ? DateTime.tryParse(m['created'] as String)
          : null,
      changed: m['changed'] != null
          ? DateTime.tryParse(m['changed'] as String)
          : null,
      coverArt: m['coverArt'] as String?,
      songs: songList,
    );
  }
}
