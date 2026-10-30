import '../../models/ml/ml_types.dart';

class ExplainableAI {
  List<Explanation> explainRecommendation({
    required dynamic track,
    required MLProfile profile,
    required Map<String, TrackRating> ratings,
    List<TrackRating>? listeningHistory,
    bool timeAdaptivityEnabled = true,
  }) {
    final explanations = <Explanation>[];

    final rating = ratings[track?.id];
    if (rating != null) {
      for (final entry in ratings.entries) {
        if (entry.value.like == true && entry.value.songId != track?.id) {
          final entryRating = entry.value;
          if (entryRating.energy != null && rating.energy != null) {
            final energyDiff = (entryRating.energy! - rating.energy!).abs();
            if (energyDiff < 0.08) {
              explanations.add(Explanation(
                type: 'similar-track',
                text: 'Similar to ${entryRating.songInfo?['title'] ?? 'a liked track'}',
                priority: 1,
              ));
              break;
            }
          }
        }
      }
    }

    if (track?.artistId != null) {
      final artistWeight = profile.preferredArtists[track.artistId];
      if (artistWeight != null && artistWeight >= 5) {
        explanations.add(Explanation(
          type: 'similar-artist',
          text: 'By ${track.artist} — one of your favorites',
          priority: 2,
        ));
      }
    }

    if (track?.genre != null) {
      final genreWeight = profile.preferredGenres[track.genre.toLowerCase()];
      if (genreWeight != null && genreWeight >= 3) {
        explanations.add(Explanation(
          type: 'genre-match',
          text: '${track.genre} — matches your taste',
          priority: 3,
        ));
      }
    }

    if (timeAdaptivityEnabled) {
      final hour = DateTime.now().hour;
      String timeText;
      if (hour >= 6 && hour < 12) timeText = 'Perfect for your morning';
      else if (hour >= 12 && hour < 17) timeText = 'Great for your afternoon';
      else if (hour >= 17 && hour < 22) timeText = 'Ideal for your evening';
      else timeText = 'Late night vibes';

      if (explanations.length < 2) {
        explanations.add(Explanation(
          type: 'time-of-day',
          text: timeText,
          priority: 4,
        ));
      }
    }

    if (explanations.isEmpty) {
      explanations.add(Explanation(
        type: 'new-discovery',
        text: 'New discovery for you',
        priority: 10,
      ));
    }

    explanations.sort((a, b) => a.priority.compareTo(b.priority));
    return explanations;
  }
}
