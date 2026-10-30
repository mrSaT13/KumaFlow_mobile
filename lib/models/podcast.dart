import '../models/song.dart';

class Podcast {
  final String id;
  final String title;
  final String description;
  final String author;
  final String? link;
  final String? imageUrl;
  final String feedUrl;
  final int episodeCount;
  final DateTime createdAt;
  final DateTime updatedAt;

  Podcast({
    required this.id,
    required this.title,
    required this.description,
    required this.author,
    this.link,
    this.imageUrl,
    required this.feedUrl,
    this.episodeCount = 0,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  factory Podcast.fromJson(Map<String, dynamic> json) => Podcast(
        id: json['id']?.toString() ?? '',
        title: json['title']?.toString() ?? 'Unknown Podcast',
        description: json['description']?.toString() ?? '',
        author: json['author']?.toString() ?? 'Unknown Author',
        link: json['link']?.toString(),
        imageUrl: json['imageUrl']?.toString() ?? json['image_url']?.toString(),
        feedUrl: json['feedUrl']?.toString() ?? json['feed_url']?.toString() ?? '',
        episodeCount: (json['episodeCount'] as num?)?.toInt() ?? (json['episode_count'] as num?)?.toInt() ?? 0,
        createdAt: json['createdAt'] != null ? DateTime.tryParse(json['createdAt'].toString()) ?? DateTime.now() : DateTime.now(),
        updatedAt: json['updatedAt'] != null ? DateTime.tryParse(json['updatedAt'].toString()) ?? DateTime.now() : DateTime.now(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'description': description,
        'author': author,
        'link': link,
        'imageUrl': imageUrl,
        'feedUrl': feedUrl,
        'episodeCount': episodeCount,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  Podcast copyWith({int? episodeCount, String? imageUrl, String? description}) =>
      Podcast(
        id: id,
        title: title,
        description: description ?? this.description,
        author: author,
        link: link,
        imageUrl: imageUrl ?? this.imageUrl,
        feedUrl: feedUrl,
        episodeCount: episodeCount ?? this.episodeCount,
        createdAt: createdAt,
        updatedAt: DateTime.now(),
      );
}

class PodcastEpisode {
  final String id;
  final String podcastId;
  final String title;
  final String description;
  final String audioUrl;
  final String? imageUrl;
  final int duration; // seconds
  final DateTime? publishedAt;
  final String? guid;

  PodcastEpisode({
    required this.id,
    required this.podcastId,
    required this.title,
    required this.description,
    required this.audioUrl,
    this.imageUrl,
    this.duration = 0,
    this.publishedAt,
    this.guid,
  });

  factory PodcastEpisode.fromJson(Map<String, dynamic> json) => PodcastEpisode(
        id: json['id']?.toString() ?? '',
        podcastId: json['podcastId']?.toString() ?? json['podcast_id']?.toString() ?? '',
        title: json['title']?.toString() ?? 'Unknown Episode',
        description: json['description']?.toString() ?? '',
        audioUrl: json['audioUrl']?.toString() ?? json['audio_url']?.toString() ?? '',
        imageUrl: json['imageUrl']?.toString() ?? json['image_url']?.toString(),
        duration: (json['duration'] as num?)?.toInt() ?? 0,
        publishedAt: json['publishedAt'] != null ? DateTime.tryParse(json['publishedAt'].toString()) : null,
        guid: json['guid']?.toString(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'podcastId': podcastId,
        'title': title,
        'description': description,
        'audioUrl': audioUrl,
        'imageUrl': imageUrl,
        'duration': duration,
        'publishedAt': publishedAt?.toIso8601String(),
        'guid': guid,
      };

  /// Map to Song for player_provider queue. isLocal=true signals podcast mode.
  Song toSong(Podcast podcast) {
    // Use podcast id as albumId, episode id prefixed
    final cover = imageUrl ?? podcast.imageUrl;
    return Song(
      id: 'podcast:$id',
      title: title,
      album: podcast.title,
      albumId: podcast.id,
      artist: podcast.author,
      artistId: podcast.id,
      genre: 'Podcast',
      coverArt: cover,
      duration: duration > 0 ? duration : null,
      isLocal: true,
      // store audio url in path for direct play, also suffix/contentType
      path: audioUrl,
      contentType: 'audio/mpeg',
      suffix: 'mp3',
    );
  }

  String get formattedDuration {
    if (duration <= 0) return '--:--';
    final h = duration ~/ 3600;
    final m = (duration % 3600) ~/ 60;
    final s = duration % 60;
    if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  String get formattedDate {
    if (publishedAt == null) return '';
    final d = publishedAt!;
    return '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';
  }
}

/// iTunes search result mapped to Podcast stub (without episodes)
class PodcastSearchResult {
  final String trackName;
  final String artistName;
  final String feedUrl;
  final String artworkUrl;
  final String? trackViewUrl;
  final int? trackCount;

  PodcastSearchResult({
    required this.trackName,
    required this.artistName,
    required this.feedUrl,
    required this.artworkUrl,
    this.trackViewUrl,
    this.trackCount,
  });

  factory PodcastSearchResult.fromItunes(Map<String, dynamic> json) => PodcastSearchResult(
        trackName: json['collectionName']?.toString() ?? json['trackName']?.toString() ?? 'Unknown',
        artistName: json['artistName']?.toString() ?? 'Unknown',
        feedUrl: json['feedUrl']?.toString() ?? '',
        artworkUrl: (json['artworkUrl600'] ?? json['artworkUrl100'] ?? json['artworkUrl60'])?.toString() ?? '',
        trackViewUrl: json['collectionViewUrl']?.toString() ?? json['trackViewUrl']?.toString(),
        trackCount: (json['trackCount'] as num?)?.toInt(),
      );

  Podcast toPodcastStub() {
    final hash = feedUrl.hashCode;
    final id = 'podcast-search-${hash.abs().toString()}-${DateTime.now().millisecondsSinceEpoch.toString().substring(8)}';
    return Podcast(
      id: id,
      title: trackName,
      description: '',
      author: artistName,
      imageUrl: artworkUrl,
      feedUrl: feedUrl,
      link: trackViewUrl,
      episodeCount: trackCount ?? 0,
    );
  }
}
