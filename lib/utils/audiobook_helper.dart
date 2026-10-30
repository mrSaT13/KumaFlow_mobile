import '../services/offline_service.dart';
import '../services/audiobookshelf_service.dart';
import '../models/book.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class AudiobookHelper {
  static Future<void> playBook(BuildContext context, String itemId, Map<String, dynamic> initialData, {double? startTime}) async {
    final svc = AudiobookshelfService();
    final detail = await svc.fetchBookDetail(itemId) ?? initialData;
    final chapters = svc.extractBookChapters(detail);
    final audioFiles = svc.getAudioFiles(detail);
    final totalDur = svc.extractTotalDuration(detail);
    double cur = startTime ?? 0;
    if (startTime == null) {
      try {
        final prog = await svc.fetchMediaProgress(itemId, totalDuration: totalDur) ?? svc.extractMediaProgress(detail, totalDuration: totalDur);
        cur = prog?.currentTime ?? 0;
        // if finished, reset to 0
        if (prog?.isFinished == true) cur = 0;
      } catch (_) {}
    }
    final chaptersNonEmpty = chapters.isEmpty
        ? [BookChapter(id: '0', title: detail['media']?['metadata']?['title'] ?? 'Unknown', start: 0, end: totalDur, duration: totalDur)]
        : chapters;

    final player = context.read<PlayerProvider>();
    player.setAbsBookContext(itemId: itemId, chapters: chaptersNonEmpty.map((c)=>c.toJson()).toList(), totalDuration: totalDur);

    final playlist = <Song>[];
    final isSingleFile = audioFiles.length == 1 && chaptersNonEmpty.length > 1;
    final isMultiOneToOne = audioFiles.length > 1 && chaptersNonEmpty.length == audioFiles.length;
    final title = detail['media']?['metadata']?['title'] ?? 'Unknown';
    final authors = detail['media']?['metadata']?['authors'] as List?;
    final author = authors != null && authors.isNotEmpty ? authors.map((a)=>a['name']??'').join(', ') : (detail['media']?['metadata']?['authorName'] ?? '');

    for (int i=0;i<chaptersNonEmpty.length;i++) {
      final c = chaptersNonEmpty[i];
      String chapFileId = '';
      double? chapStart;
      double? chapEnd;
      if (isMultiOneToOne) {
        chapFileId = audioFiles[i]['ino']?.toString() ?? '';
      } else if (isSingleFile) {
        chapFileId = audioFiles.first['ino']?.toString() ?? '';
        chapStart = c.start; chapEnd = c.end;
      } else if (audioFiles.length > 1) {
        double acc=0;
        bool mapped=false;
        for (final f in audioFiles) {
          final fid = f['ino']?.toString() ?? '';
          final dur = (f['duration'] as num?)?.toDouble() ?? 0;
          final fStart=acc; final fEnd=acc+dur;
          if (c.start >= fStart && c.start < fEnd) {
            chapFileId=fid;
            if (c.end <= fEnd) { chapStart=c.start-fStart; chapEnd=c.end-fStart; } else { chapStart=c.start-fStart; chapEnd=dur; }
            mapped=true; break;
          }
          acc=fEnd;
        }
        if (!mapped) { chapFileId = audioFiles.first['ino']?.toString() ?? ''; chapStart=c.start; chapEnd=c.end; }
      }
      final url = chapFileId.isNotEmpty ? svc.getStreamUrl(itemId, fileId: chapFileId) : svc.getStreamUrl(itemId);
      playlist.add(Song(id: 'abs_${itemId}_ch_$i', title: 'Глава ${i+1}: ${c.title}', album: title.toString(), artist: author.toString(), genre: 'Audiobook', duration: c.duration.round(), coverArt: 'abs:$itemId', path: url, isLocal: false, absStart: chapStart, absEnd: chapEnd));
    }

    final pos = calculateChapterIndexAndPosition(chaptersNonEmpty, cur);
    int startIdx = pos.index >=0 ? pos.index : 0;
    if (totalDur>0 && cur >= totalDur-1.0) startIdx=0;
    double offset = pos.position;
    if (startIdx < chaptersNonEmpty.length) offset = offset.clamp(0, chaptersNonEmpty[startIdx].duration).toDouble();
    if (playlist.isEmpty) return;
    if (startIdx >= playlist.length) startIdx=0;
    final initialPos = offset > 0.5 ? Duration(milliseconds: (offset*1000).round()) : null;
    await player.playSong(playlist[startIdx], playlist: playlist, startIndex: startIdx, initialPosition: initialPos);
  }
}

