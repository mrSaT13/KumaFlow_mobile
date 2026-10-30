import 'artist_ref.dart';

class Song {
  final String id;
  final String title;
  final String? album;
  final String? albumId;
  final String? artist;
  final String? artistId;
  final int? track;
  final int? year;
  final String? genre;
  final String? mood;
  final String? coverArt;
  final int? duration;
  final int? bitRate;
  final String? suffix;
  final String? contentType;
  final int? size;
  final String? path;
  final bool? starred;
  final int? userRating;
  final bool isLocal;
  final int? playCount;
  final String? played; // ISO date from server
  final double? averageRating;
  final double? replayGainTrackGain;
  final double? replayGainAlbumGain;
  final double? replayGainTrackPeak;
  final double? replayGainAlbumPeak;
  final List<ArtistRef>? artistParticipants;
  final DateTime? created;
  final bool? hasDolbyAtmos;
  // ABS chapter clipping
  final double? absStart;
  final double? absEnd;
  // Collab / multi-server: с какого сервера трек (null = основной).
  // Нужен чтобы плеер подставлял правильный stream/cover URL.
  final String? sourceServerId;
  final String? sourceLabel;

  Song({
    required this.id,
    required this.title,
    this.album,
    this.albumId,
    this.artist,
    this.artistId,
    this.track,
    this.year,
    this.genre,
    this.mood,
    this.coverArt,
    this.duration,
    this.bitRate,
    this.suffix,
    this.contentType,
    this.size,
    this.path,
    this.starred,
    this.userRating,
    this.isLocal = false,
    this.playCount,
    this.played,
    this.averageRating,
    this.replayGainTrackGain,
    this.replayGainAlbumGain,
    this.replayGainTrackPeak,
    this.replayGainAlbumPeak,
    this.artistParticipants,
    this.created,
    this.hasDolbyAtmos,
    this.absStart,
    this.absEnd,
    this.sourceServerId,
    this.sourceLabel,
  });

  factory Song.fromJson(Map<String, dynamic> json) {
    final replayGain = json['replayGain'] as Map<String, dynamic>?;

    return Song(
      id: json['id']?.toString() ?? '',
      title: json['title'] ?? 'Unknown Title',
      album: json['album']?.toString(),
      albumId: json['albumId']?.toString(),
      artist: json['artist']?.toString(),
      artistId: json['artistId']?.toString(),
      track: json['track'] as int?,
      year: json['year'] as int?,
      genre: json['genre']?.toString(),
      mood: json['mood']?.toString(),
      coverArt: json['coverArt']?.toString(),
      duration: json['duration'] as int?,
      bitRate: json['bitRate'] as int?,
      suffix: json['suffix']?.toString(),
      contentType: json['contentType']?.toString(),
      size: json['size'] as int?,
      path: json['path']?.toString(),
      starred: json['starred'] != null ? true : false,
      userRating: json['userRating'] as int?,
      isLocal: json['isLocal'] as bool? ?? false,
      playCount: json['playCount'] as int?,
      played: json['played']?.toString(),
      averageRating: (json['averageRating'] as num?)?.toDouble(),
      replayGainTrackGain: (replayGain?['trackGain'] as num?)?.toDouble(),
      replayGainAlbumGain: (replayGain?['albumGain'] as num?)?.toDouble(),
      replayGainTrackPeak: (replayGain?['trackPeak'] as num?)?.toDouble(),
      replayGainAlbumPeak: (replayGain?['albumPeak'] as num?)?.toDouble(),
      artistParticipants: ArtistRef.parseList(json['artists']),
      created: json['created'] != null
          ? DateTime.tryParse(json['created'].toString())
          : null,
      hasDolbyAtmos: json['hasDolbyAtmos'] as bool?,
      absStart: (json['absStart'] as num?)?.toDouble(),
      absEnd: (json['absEnd'] as num?)?.toDouble(),
      sourceServerId: json['sourceServerId']?.toString(),
      sourceLabel: json['sourceLabel']?.toString(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'album': album,
      'albumId': albumId,
      'artist': artist,
      'artistId': artistId,
      'track': track,
      'year': year,
      'genre': genre,
      'mood': mood,
      'coverArt': coverArt,
      'duration': duration,
      'bitRate': bitRate,
      'suffix': suffix,
      'contentType': contentType,
      'size': size,
      'path': path,
      'starred': starred == true ? true : null,
      'userRating': userRating,
      'playCount': playCount,
      'played': played,
      'averageRating': averageRating,
      'isLocal': isLocal,
      'replayGain': {
        if (replayGainTrackGain != null) 'trackGain': replayGainTrackGain,
        if (replayGainAlbumGain != null) 'albumGain': replayGainAlbumGain,
        if (replayGainTrackPeak != null) 'trackPeak': replayGainTrackPeak,
        if (replayGainAlbumPeak != null) 'albumPeak': replayGainAlbumPeak,
      },
      if (artistParticipants != null)
        'artists': artistParticipants!.map((a) => a.toJson()).toList(),
      'created': created?.toIso8601String(),
      if (hasDolbyAtmos != null) 'hasDolbyAtmos': hasDolbyAtmos,
      if (absStart != null) 'absStart': absStart,
      if (absEnd != null) 'absEnd': absEnd,
      if (sourceServerId != null) 'sourceServerId': sourceServerId,
      if (sourceLabel != null) 'sourceLabel': sourceLabel,
    };
  }

  String get formattedDuration {
    if (duration == null) return '0:00';
    final minutes = duration! ~/ 60;
    final seconds = duration! % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  Song copyWith({
    String? id,
    String? title,
    String? album,
    String? albumId,
    String? artist,
    String? artistId,
    int? track,
    int? year,
    String? genre,
    String? mood,
    String? coverArt,
    int? duration,
    int? bitRate,
    String? suffix,
    String? contentType,
    int? size,
    String? path,
    bool? starred,
    int? userRating,
    bool? isLocal,
    int? playCount,
    String? played,
    double? averageRating,
    double? replayGainTrackGain,
    double? replayGainAlbumGain,
    double? replayGainTrackPeak,
    double? replayGainAlbumPeak,
    List<ArtistRef>? artistParticipants,
    DateTime? created,
    bool? hasDolbyAtmos,
    double? absStart,
    double? absEnd,
    String? sourceServerId,
    String? sourceLabel,
  }) {
    return Song(
      id: id ?? this.id,
      title: title ?? this.title,
      album: album ?? this.album,
      albumId: albumId ?? this.albumId,
      artist: artist ?? this.artist,
      artistId: artistId ?? this.artistId,
      track: track ?? this.track,
      year: year ?? this.year,
      genre: genre ?? this.genre,
      mood: mood ?? this.mood,
      coverArt: coverArt ?? this.coverArt,
      duration: duration ?? this.duration,
      bitRate: bitRate ?? this.bitRate,
      suffix: suffix ?? this.suffix,
      contentType: contentType ?? this.contentType,
      size: size ?? this.size,
      path: path ?? this.path,
      starred: starred ?? this.starred,
      userRating: userRating ?? this.userRating,
      isLocal: isLocal ?? this.isLocal,
      playCount: playCount ?? this.playCount,
      played: played ?? this.played,
      averageRating: averageRating ?? this.averageRating,
      replayGainTrackGain: replayGainTrackGain ?? this.replayGainTrackGain,
      replayGainAlbumGain: replayGainAlbumGain ?? this.replayGainAlbumGain,
      replayGainTrackPeak: replayGainTrackPeak ?? this.replayGainTrackPeak,
      replayGainAlbumPeak: replayGainAlbumPeak ?? this.replayGainAlbumPeak,
      artistParticipants: artistParticipants ?? this.artistParticipants,
      created: created ?? this.created,
      hasDolbyAtmos: hasDolbyAtmos ?? this.hasDolbyAtmos,
      absStart: absStart ?? this.absStart,
      absEnd: absEnd ?? this.absEnd,
      sourceServerId: sourceServerId ?? this.sourceServerId,
      sourceLabel: sourceLabel ?? this.sourceLabel,
    );
  }

  /// Составной ключ очереди: защищает от коллизии id с разных серверов.
  String get queueKey =>
      sourceServerId == null || sourceServerId!.isEmpty ? id : '$sourceServerId::$id';

  /// Трек с чужого (collab) сервера?
  bool get isRemoteCollab =>
      sourceServerId != null && sourceServerId!.isNotEmpty;
}
