import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/podcast.dart';
import '../theme/app_theme.dart';
import '../services/offline_service.dart';
import 'package:provider/provider.dart';

class EpisodeTile extends StatelessWidget {
  final PodcastEpisode episode;
  final Podcast podcast;
  final int index;
  final List<PodcastEpisode> playlist;
  final VoidCallback? onTap;
  final VoidCallback? onPlay;

  const EpisodeTile({
    super.key,
    required this.episode,
    required this.podcast,
    required this.index,
    required this.playlist,
    this.onTap,
    this.onPlay,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Stack(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 56,
              height: 56,
              child: _artwork(episode.imageUrl ?? podcast.imageUrl),
            ),
          ),
          Positioned.fill(
            child: Material(
              color: Colors.black.withValues(alpha: 0.25),
              borderRadius: BorderRadius.circular(8),
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: onPlay,
                child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 28),
              ),
            ),
          ),
        ],
      ),
      title: Text(
        episode.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 2),
          Text(
            episode.description.isEmpty ? podcast.author : episode.description,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: isDark ? AppTheme.darkSecondaryText : AppTheme.lightSecondaryText,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              if (episode.publishedAt != null) ...[
                Icon(Icons.calendar_today_rounded, size: 12, color: isDark ? AppTheme.darkSecondaryText : AppTheme.lightSecondaryText),
                const SizedBox(width: 4),
                Text(episode.formattedDate, style: theme.textTheme.bodySmall?.copyWith(fontSize: 11, color: isDark ? AppTheme.darkSecondaryText : AppTheme.lightSecondaryText)),
                const SizedBox(width: 10),
              ],
              Icon(Icons.timer_outlined, size: 12, color: isDark ? AppTheme.darkSecondaryText : AppTheme.lightSecondaryText),
              const SizedBox(width: 4),
              Text(episode.formattedDuration, style: theme.textTheme.bodySmall?.copyWith(fontSize: 11, color: isDark ? AppTheme.darkSecondaryText : AppTheme.lightSecondaryText)),
            ],
          ),
        ],
      ),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        _EpisodeDownloadButton(episode: episode),
        PopupMenuButton<String>(
          onSelected: (v) {
            if (v == 'play') onPlay?.call();
          },
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'play', child: Row(children: [Icon(Icons.play_arrow_rounded, size: 18), SizedBox(width: 8), Text('Play')])),
          ],
        ),
      ]),
      onTap: onTap ?? onPlay,
    );
  }

  Widget _artwork(String? url) {
    if (url == null || url.isEmpty) {
      return Container(
        color: Colors.grey.shade900,
        child: const Icon(Icons.podcasts_rounded, color: Colors.white54),
      );
    }
    return CachedNetworkImage(
      imageUrl: url,
      fit: BoxFit.cover,
      placeholder: (c, u) => Container(color: Colors.grey.shade900),
      errorWidget: (c, u, e) => Container(color: Colors.grey.shade900, child: const Icon(Icons.podcasts_rounded, color: Colors.white54)),
    );
  }
}

class _EpisodeDownloadButton extends StatefulWidget {
  final PodcastEpisode episode;
  const _EpisodeDownloadButton({required this.episode});
  @override
  State<_EpisodeDownloadButton> createState() => _EpisodeDownloadButtonState();
}
class _EpisodeDownloadButtonState extends State<_EpisodeDownloadButton> {
  @override
  Widget build(BuildContext context) {
    final off = OfflineService();
    return ListenableBuilder(
      listenable: off,
      builder: (ctx, _) {
        final prog = off.downloadProgress[widget.episode.id];
        final isDownloading = prog != null && !prog.isComplete && !prog.isError;
        final isDownloaded = off.isPodcastEpisodeDownloaded(widget.episode.id);
        if (isDownloading) {
          final pct = ((prog.progress)*100).toInt();
          return SizedBox(width: 48, child: Stack(alignment: Alignment.center, children: [
            CircularProgressIndicator(value: prog.progress>0 ? prog.progress : null, strokeWidth: 2),
            Text("$pct%", style: TextStyle(fontSize: 9)),
          ]));
        }
        if (isDownloaded) {
          return IconButton(icon: Icon(Icons.offline_pin_rounded, color: Colors.green, size:20), tooltip: "Downloaded", onPressed: () async {
            await off.deletePodcastEpisode(widget.episode.id);
            if (mounted) setState((){});
          });
        }
        return IconButton(icon: Icon(Icons.download_rounded, size:20), tooltip: "Download", onPressed: () async {
          final ok = await off.downloadPodcastEpisode(episodeId: widget.episode.id, audioUrl: widget.episode.audioUrl, onProgress: (p){ if(mounted) setState((){}); });
          if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ok ? "Downloaded: ${widget.episode.title}" : "Error")));
          if (mounted) setState((){});
        });
      },
    );
  }
}


