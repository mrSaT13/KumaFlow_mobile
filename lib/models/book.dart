/// Lissen-style book models for audiobooks
/// MediaProgress, Chapter, Book — mirrors Lissen DetailedItem/PlayingChapter + ABS BookChapter

class BookChapter {
  final String id;
  final String title;
  final double start; // seconds from book start
  final double end;
  final double duration;

  const BookChapter({
    required this.id,
    required this.title,
    required this.start,
    required this.end,
    required this.duration,
  });

  factory BookChapter.fromJson(Map<String, dynamic> json) {
    final start = (json['start'] as num?)?.toDouble() ?? 0;
    final end = (json['end'] as num?)?.toDouble() ?? start;
    final duration = (json['duration'] as num?)?.toDouble() ?? (end - start);
    return BookChapter(
      id: json['id']?.toString() ?? json['ino']?.toString() ?? start.toString(),
      title: json['title']?.toString() ?? json['metadata']?['filename']?.toString() ?? 'Глава',
      start: start,
      end: end,
      duration: duration > 0 ? duration : (end - start),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'start': start,
        'end': end,
        'duration': duration,
      };
}

/// MediaProgress ~ Lissen MediaProgress + ABS userMediaProgress
class MediaProgress {
  final double currentTime; // absolute seconds from book start
  final double progress; // 0..1
  final bool isFinished;
  final int lastUpdate; // epoch ms
  final double duration; // total book duration

  const MediaProgress({
    required this.currentTime,
    required this.progress,
    required this.isFinished,
    required this.lastUpdate,
    required this.duration,
  });

  static const double finishedEpsilon = 1.0; // Lissen FINISHED_POSITION_EPSILON
  static const double finishedProgressThreshold = 0.99; // ABS threshold

  /// Compute isFinished like Lissen: currentTime >= totalDuration -1.0 OR progress >=0.99
  static bool computeIsFinished(double currentTime, double totalDuration, {double? progress, bool? explicit}) {
    if (explicit != null) return explicit;
    if (totalDuration <= 0) return false;
    if (currentTime >= totalDuration - finishedEpsilon) return true;
    final p = progress ?? (totalDuration > 0 ? currentTime / totalDuration : 0);
    return p >= finishedProgressThreshold;
  }

  factory MediaProgress.fromJson(Map<String, dynamic> json, {double totalDuration = 0}) {
    final ct = (json['currentTime'] as num?)?.toDouble() ?? (json['current_time'] as num?)?.toDouble() ?? 0;
    double prog = (json['progress'] as num?)?.toDouble() ?? 0;
    // ABS may store isFinished bool
    final explicitFinished = json['isFinished'] as bool?;
    final dur = (json['duration'] as num?)?.toDouble() ?? totalDuration;
    // Normalize prog if needed
    if (prog == 0 && dur > 0 && ct > 0) prog = (ct / dur).clamp(0, 1);
    // If prog >1 it was absolute time
    if (prog > 1) prog = (prog / (dur > 0 ? dur : 1)).clamp(0, 1);
    if (dur > 0 && ct > 0 && prog == 0) prog = (ct / dur).clamp(0, 1);
    final isFinished = computeIsFinished(ct, dur, progress: prog, explicit: explicitFinished);
    final lastUpdate = (json['lastUpdate'] as num?)?.toInt() ?? (json['updatedAt'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch;
    return MediaProgress(
      currentTime: ct,
      progress: prog.clamp(0, 1),
      isFinished: isFinished,
      lastUpdate: lastUpdate,
      duration: dur,
    );
  }

  MediaProgress copyWith({double? currentTime, double? progress, bool? isFinished, int? lastUpdate, double? duration}) {
    return MediaProgress(
      currentTime: currentTime ?? this.currentTime,
      progress: progress ?? this.progress,
      isFinished: isFinished ?? this.isFinished,
      lastUpdate: lastUpdate ?? this.lastUpdate,
      duration: duration ?? this.duration,
    );
  }

  bool get isStarted => progress > 0 && !isFinished;
  bool get isNotStarted => progress == 0 && !isFinished;
}

/// Result of calculateChapterIndexAndPosition ~ Lissen ChapterPosition
class ChapterPosition {
  final int index;
  final double position; // seconds inside chapter
  const ChapterPosition(this.index, this.position);
}

/// Lissen CalculateChapterIndexAndPosition.kt:20-48
ChapterPosition calculateChapterIndexAndPosition(List<BookChapter> chapters, double overallPosition) {
  if (chapters.isEmpty) return const ChapterPosition(-1, 0);
  const eps = 0.1;
  final target = overallPosition + eps;
  // Binary search first chapter where end > target
  int low = 0;
  int high = chapters.length - 1;
  int result = chapters.length - 1;
  // Edge: last chapter near end -> clamp to last
  final last = chapters.last;
  if (overallPosition >= last.end - eps) {
    return ChapterPosition(chapters.length - 1, 0); // caller will handle offset; Lissen returns (last, 0) when near end
  }
  while (low <= high) {
    final mid = (low + high) >> 1;
    if (chapters[mid].end > target) {
      result = mid;
      high = mid - 1;
    } else {
      low = mid + 1;
    }
  }
  final pos = (overallPosition - chapters[result].start).clamp(0, chapters[result].duration);
  return ChapterPosition(result, pos.toDouble());
}

/// FileClip ~ Lissen FileClip for multi-file chapter mapping
class FileClip {
  final String fileId;
  final double clipStart;
  final double clipEnd;
  const FileClip(this.fileId, this.clipStart, this.clipEnd);
}

/// Resolve chapters to file clips ~ Lissen PlaybackService.resolveChapterToFiles:168-219
List<List<FileClip>> resolveChapterToFiles(List<BookChapter> chapters, List<Map<String, dynamic>> audioFiles) {
  if (chapters.isEmpty || audioFiles.isEmpty) return [];
  // Build sorted files with start/end offsets (filesAsChapters already has start computed if needed)
  // If files already have start computed via filesAsChapters, use that; otherwise compute accumulated
  final files = <Map<String, dynamic>>[];
  double acc = 0;
  for (final f in audioFiles) {
    final dur = (f['duration'] as num?)?.toDouble() ?? 0;
    final start = (f['start'] as num?)?.toDouble() ?? acc;
    final end = (f['end'] as num?)?.toDouble() ?? (start + dur);
    files.add({'ino': f['ino']?.toString() ?? '', 'start': start, 'end': end, 'duration': dur});
    acc = end;
  }
  const eps = 0.01;
  final result = <List<FileClip>>[];
  for (final ch in chapters) {
    final clips = <FileClip>[];
    final chStart = ch.start;
    final chEnd = ch.end;
    for (final file in files) {
      final fileStart = (file['start'] as num).toDouble();
      final fileEnd = (file['end'] as num).toDouble();
      final fileId = file['ino']?.toString() ?? '';
      if (fileEnd <= chStart + eps) continue;
      if (fileStart >= chEnd - eps) break;
      final overlapStart = chStart > fileStart ? chStart : fileStart;
      final overlapEnd = chEnd < fileEnd ? chEnd : fileEnd;
      if (overlapEnd - overlapStart > eps) {
        final clipStart = overlapStart - fileStart;
        final clipEnd = overlapEnd - fileStart;
        clips.add(FileClip(fileId, clipStart, clipEnd));
      }
    }
    result.add(clips);
  }
  return result;
}
