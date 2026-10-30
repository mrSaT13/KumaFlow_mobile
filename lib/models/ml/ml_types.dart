class VibeFeatures {
  final double energy;
  final double valence;
  final double danceability;
  final double bpm;
  final double acousticness;
  final double instrumentalness;

  const VibeFeatures({
    required this.energy,
    required this.valence,
    required this.danceability,
    required this.bpm,
    required this.acousticness,
    required this.instrumentalness,
  });

  factory VibeFeatures.empty() => const VibeFeatures(
    energy: 0.5, valence: 0.5, danceability: 0.5,
    bpm: 120, acousticness: 0.5, instrumentalness: 0.0,
  );

  Map<String, dynamic> toJson() => {
    'energy': energy, 'valence': valence, 'danceability': danceability,
    'bpm': bpm, 'acousticness': acousticness, 'instrumentalness': instrumentalness,
  };

  factory VibeFeatures.fromJson(Map<String, dynamic> json) => VibeFeatures(
    energy: (json['energy'] as num?)?.toDouble() ?? 0.5,
    valence: (json['valence'] as num?)?.toDouble() ?? 0.5,
    danceability: (json['danceability'] as num?)?.toDouble() ?? 0.5,
    bpm: (json['bpm'] as num?)?.toDouble() ?? 120,
    acousticness: (json['acousticness'] as num?)?.toDouble() ?? 0.5,
    instrumentalness: (json['instrumentalness'] as num?)?.toDouble() ?? 0.0,
  );
}

enum MoodType {
  energetic, happy, calm, sad, angry,
  melancholic, relaxed, focused, romantic, dramatic,
}

class MoodDetection {
  final MoodType mood;
  final double confidence;
  final double arousal;
  final double dominance;

  const MoodDetection({
    required this.mood,
    required this.confidence,
    required this.arousal,
    required this.dominance,
  });
}

class TrackRating {
  final String songId;
  final Map<String, String>? songInfo;
  bool? like;
  int playCount;
  int skipCount;
  int replayCount;
  int seekBackCount;
  int abandonCount;
  int score;
  String? lastPlayed;
  double? bpm;
  double? energy;
  double? danceability;
  double? valence;
  double? acousticness;
  List<int> hourPlayed;
  List<int> dayPlayed;
  String? firstHeard;
  int? lastSkipTime;

  TrackRating({
    required this.songId,
    this.songInfo,
    this.like,
    this.playCount = 0,
    this.skipCount = 0,
    this.replayCount = 0,
    this.seekBackCount = 0,
    this.abandonCount = 0,
    this.score = 0,
    this.lastPlayed,
    this.bpm,
    this.energy,
    this.danceability,
    this.valence,
    this.acousticness,
    List<int>? hourPlayed,
    List<int>? dayPlayed,
    this.firstHeard,
    this.lastSkipTime,
  }) : hourPlayed = hourPlayed ?? [],
       dayPlayed = dayPlayed ?? [];

  Map<String, dynamic> toJson() => {
    'songId': songId, 'songInfo': songInfo, 'like': like,
    'playCount': playCount, 'skipCount': skipCount, 'replayCount': replayCount,
    'seekBackCount': seekBackCount, 'abandonCount': abandonCount,
    'score': score, 'lastPlayed': lastPlayed,
    'bpm': bpm, 'energy': energy, 'danceability': danceability,
    'valence': valence, 'acousticness': acousticness,
    'hourPlayed': hourPlayed, 'dayPlayed': dayPlayed,
    'firstHeard': firstHeard, 'lastSkipTime': lastSkipTime,
  };

  factory TrackRating.fromJson(Map<String, dynamic> json) => TrackRating(
    songId: json['songId'] as String,
    songInfo: json['songInfo'] != null ? Map<String, String>.from(json['songInfo'] as Map) : null,
    like: json['like'] as bool?,
    playCount: json['playCount'] as int? ?? 0,
    skipCount: json['skipCount'] as int? ?? 0,
    replayCount: json['replayCount'] as int? ?? 0,
    seekBackCount: json['seekBackCount'] as int? ?? 0,
    abandonCount: json['abandonCount'] as int? ?? 0,
    score: json['score'] as int? ?? 0,
    lastPlayed: json['lastPlayed'] as String?,
    bpm: (json['bpm'] as num?)?.toDouble(),
    energy: (json['energy'] as num?)?.toDouble(),
    danceability: (json['danceability'] as num?)?.toDouble(),
    valence: (json['valence'] as num?)?.toDouble(),
    acousticness: (json['acousticness'] as num?)?.toDouble(),
    hourPlayed: json['hourPlayed'] != null ? List<int>.from(json['hourPlayed'] as List) : [],
    dayPlayed: json['dayPlayed'] != null ? List<int>.from(json['dayPlayed'] as List) : [],
    firstHeard: json['firstHeard'] as String?,
    lastSkipTime: json['lastSkipTime'] as int?,
  );
}

class MLProfile {
  Map<String, double> preferredGenres;
  Map<String, double> preferredArtists;
  List<String> likedSongs;
  List<String> dislikedSongs;
  List<String> bannedArtists;
  // Счётчик дизлайков по артистам: banId -> count.
  // Правило: 1 диз = бан трека, 3 дизлайка треков одного артиста = бан артиста.
  Map<String, int> artistDislikeCounts;

  MLProfile({
    Map<String, double>? preferredGenres,
    Map<String, double>? preferredArtists,
    List<String>? likedSongs,
    List<String>? dislikedSongs,
    List<String>? bannedArtists,
    Map<String, int>? artistDislikeCounts,
  }) : preferredGenres = preferredGenres ?? {},
       preferredArtists = preferredArtists ?? {},
       likedSongs = likedSongs ?? [],
       dislikedSongs = dislikedSongs ?? [],
       bannedArtists = bannedArtists ?? [],
       artistDislikeCounts = artistDislikeCounts ?? {};

  Map<String, dynamic> toJson() => {
    'preferredGenres': preferredGenres,
    'preferredArtists': preferredArtists,
    'likedSongs': likedSongs,
    'dislikedSongs': dislikedSongs,
    'bannedArtists': bannedArtists,
    'artistDislikeCounts': artistDislikeCounts,
  };

  factory MLProfile.fromJson(Map<String, dynamic> json) => MLProfile(
    preferredGenres: json['preferredGenres'] != null ? Map<String, double>.from(json['preferredGenres'] as Map) : null,
    preferredArtists: json['preferredArtists'] != null ? Map<String, double>.from(json['preferredArtists'] as Map) : null,
    likedSongs: json['likedSongs'] != null ? List<String>.from(json['likedSongs'] as List) : null,
    dislikedSongs: json['dislikedSongs'] != null ? List<String>.from(json['dislikedSongs'] as List) : null,
    bannedArtists: json['bannedArtists'] != null ? List<String>.from(json['bannedArtists'] as List) : null,
    artistDislikeCounts: json['artistDislikeCounts'] != null
        ? (json['artistDislikeCounts'] as Map).map((k, v) => MapEntry(k.toString(), (v as num).toInt()))
        : null,
  );
}

class MABArm {
  final String id;
  final String type;
  final String name;
  int totalPlays;
  double totalRewards;
  double avgReward;
  int lastPlayed;
  int contextPlays;

  MABArm({
    required this.id,
    required this.type,
    required this.name,
    this.totalPlays = 0,
    this.totalRewards = 0,
    this.avgReward = 0,
    this.lastPlayed = 0,
    this.contextPlays = 0,
  });

  Map<String, dynamic> toJson() => {
    'id': id, 'type': type, 'name': name,
    'totalPlays': totalPlays, 'totalRewards': totalRewards,
    'avgReward': avgReward, 'lastPlayed': lastPlayed,
    'contextPlays': contextPlays,
  };

  factory MABArm.fromJson(Map<String, dynamic> json) => MABArm(
    id: json['id'] as String,
    type: json['type'] as String,
    name: json['name'] as String,
    totalPlays: json['totalPlays'] as int? ?? 0,
    totalRewards: (json['totalRewards'] as num?)?.toDouble() ?? 0,
    avgReward: (json['avgReward'] as num?)?.toDouble() ?? 0,
    lastPlayed: json['lastPlayed'] as int? ?? 0,
    contextPlays: json['contextPlays'] as int? ?? 0,
  );
}

class MABContext {
  final String timeOfDay;
  final String dayOfWeek;
  final List<String> sessionHistory;
  final String recentMood;
  final int hour;

  const MABContext({
    required this.timeOfDay,
    required this.dayOfWeek,
    required this.sessionHistory,
    required this.recentMood,
    required this.hour,
  });
}

class AudioFeatures {
  final double bpm;
  final double energy;
  final double danceability;
  final double acousticness;
  final double valence;
  final String? key;
  final String? mode;

  const AudioFeatures({
    required this.bpm,
    required this.energy,
    required this.danceability,
    required this.acousticness,
    required this.valence,
    this.key,
    this.mode,
  });

  Map<String, dynamic> toJson() => {
    'bpm': bpm, 'energy': energy, 'danceability': danceability,
    'acousticness': acousticness, 'valence': valence,
    'key': key, 'mode': mode,
  };

  factory AudioFeatures.fromJson(Map<String, dynamic> json) => AudioFeatures(
    bpm: (json['bpm'] as num?)?.toDouble() ?? 120,
    energy: (json['energy'] as num?)?.toDouble() ?? 0.5,
    danceability: (json['danceability'] as num?)?.toDouble() ?? 0.5,
    acousticness: (json['acousticness'] as num?)?.toDouble() ?? 0.5,
    valence: (json['valence'] as num?)?.toDouble() ?? 0.5,
    key: json['key'] as String?,
    mode: json['mode'] as String?,
  );
}

class SonicFingerprint {
  final double avgEnergy;
  final double avgDanceability;
  final double avgValence;
  final double avgAcousticness;
  final double avgBpm;
  final List<String> topGenres;
  final List<String> recentTrackIds;
  final String lastUpdated;

  const SonicFingerprint({
    required this.avgEnergy,
    required this.avgDanceability,
    required this.avgValence,
    required this.avgAcousticness,
    required this.avgBpm,
    required this.topGenres,
    required this.recentTrackIds,
    required this.lastUpdated,
  });

  Map<String, dynamic> toJson() => {
    'avgEnergy': avgEnergy, 'avgDanceability': avgDanceability,
    'avgValence': avgValence, 'avgAcousticness': avgAcousticness,
    'avgBpm': avgBpm, 'topGenres': topGenres,
    'recentTrackIds': recentTrackIds, 'lastUpdated': lastUpdated,
  };

  factory SonicFingerprint.fromJson(Map<String, dynamic> json) => SonicFingerprint(
    avgEnergy: (json['avgEnergy'] as num?)?.toDouble() ?? 0.5,
    avgDanceability: (json['avgDanceability'] as num?)?.toDouble() ?? 0.5,
    avgValence: (json['avgValence'] as num?)?.toDouble() ?? 0.5,
    avgAcousticness: (json['avgAcousticness'] as num?)?.toDouble() ?? 0.5,
    avgBpm: (json['avgBpm'] as num?)?.toDouble() ?? 120,
    topGenres: json['topGenres'] != null ? List<String>.from(json['topGenres'] as List) : [],
    recentTrackIds: json['recentTrackIds'] != null ? List<String>.from(json['recentTrackIds'] as List) : [],
    lastUpdated: json['lastUpdated'] as String? ?? '',
  );
}

class MoodProfile {
  final double energy;
  final double valence;
  final double tempo;
  final String mood;
  final String activity;

  const MoodProfile({
    required this.energy,
    required this.valence,
    required this.tempo,
    required this.mood,
    this.activity = '',
  });

  Map<String, dynamic> toJson() => {
    'energy': energy, 'valence': valence, 'tempo': tempo,
    'mood': mood, 'activity': activity,
  };

  factory MoodProfile.fromJson(Map<String, dynamic> json) => MoodProfile(
    energy: (json['energy'] as num?)?.toDouble() ?? 0.5,
    valence: (json['valence'] as num?)?.toDouble() ?? 0.5,
    tempo: (json['tempo'] as num?)?.toDouble() ?? 120,
    mood: json['mood'] as String? ?? 'calm',
    activity: json['activity'] as String? ?? '',
  );
}

class TempBan {
  final String targetId;
  final String type;
  final int expiresAt;
  final String reason;

  const TempBan({
    required this.targetId,
    required this.type,
    required this.expiresAt,
    required this.reason,
  });

  bool get isExpired => DateTime.now().millisecondsSinceEpoch > expiresAt;

  Map<String, dynamic> toJson() => {
    'targetId': targetId, 'type': type,
    'expiresAt': expiresAt, 'reason': reason,
  };

  factory TempBan.fromJson(Map<String, dynamic> json) => TempBan(
    targetId: json['targetId'] as String,
    type: json['type'] as String,
    expiresAt: json['expiresAt'] as int,
    reason: json['reason'] as String,
  );
}

class PlayEvent {
  final String trackId;
  final int timestamp;
  final String action;
  final int position;
  final String sessionId;
  final String timeContext;
  final int dayOfWeek;

  const PlayEvent({
    required this.trackId,
    required this.timestamp,
    required this.action,
    this.position = 0,
    this.sessionId = '',
    this.timeContext = '',
    this.dayOfWeek = 0,
  });

  Map<String, dynamic> toJson() => {
    'trackId': trackId, 'timestamp': timestamp, 'action': action,
    'position': position, 'sessionId': sessionId,
    'timeContext': timeContext, 'dayOfWeek': dayOfWeek,
  };

  factory PlayEvent.fromJson(Map<String, dynamic> json) => PlayEvent(
    trackId: json['trackId'] as String,
    timestamp: json['timestamp'] as int,
    action: json['action'] as String,
    position: json['position'] as int? ?? 0,
    sessionId: json['sessionId'] as String? ?? '',
    timeContext: json['timeContext'] as String? ?? '',
    dayOfWeek: json['dayOfWeek'] as int? ?? 0,
  );
}

class Explanation {
  final String type;
  final String text;
  final int priority;

  const Explanation({
    required this.type,
    required this.text,
    required this.priority,
  });
}

class MLWavePlaylist {
  final List<dynamic> songs;
  final String source;
  final String? name;
  final String? description;

  const MLWavePlaylist({
    required this.songs,
    required this.source,
    this.name,
    this.description,
  });
}

class MyWaveSettings {
  final String? activity;
  final String? characteristic;
  final String? mood;
  final String? language;

  const MyWaveSettings({
    this.activity,
    this.characteristic,
    this.mood,
    this.language,
  });
}
