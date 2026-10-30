class WordSegment {
  final Duration timestamp;
  final String text;

  WordSegment({required this.timestamp, required this.text});
}

class SyncedLyrics {
  final List<LyricLine> lines;
  final String? artist;
  final String? title;

  SyncedLyrics({required this.lines, this.artist, this.title});

  bool get isEmpty => lines.isEmpty;
  bool get isNotEmpty => lines.isNotEmpty;

  static final _wordTagRegex = RegExp(r'<(\d{1,2}):(\d{2})[.:]?(\d{2,3})>');

  static List<WordSegment> _parseWordSegments(String rawText) {
    final segments = <WordSegment>[];
    final matches = _wordTagRegex.allMatches(rawText).toList();
    for (int i = 0; i < matches.length; i++) {
      final m = matches[i];
      final minutes = int.tryParse(m.group(1) ?? '') ?? 0;
      final seconds = int.tryParse(m.group(2) ?? '') ?? 0;
      final msStr = m.group(3) ?? '0';
      final msRaw = int.tryParse(msStr) ?? 0;
      final ms = msStr.length == 2 ? msRaw * 10 : msRaw;
      final ts = Duration(minutes: minutes, seconds: seconds, milliseconds: ms);
      final textStart = m.end;
      final textEnd = i + 1 < matches.length ? matches[i + 1].start : rawText.length;
      final segText = rawText.substring(textStart, textEnd).trim();
      if (segText.isNotEmpty) {
        segments.add(WordSegment(timestamp: ts, text: segText));
      }
    }
    return segments;
  }

  // Порт из feishin/src/renderer/features/lyrics/api/lyrics-api.ts
  // alternateTimeExp для NetEase [123,456] + стандартный [mm:ss.xx]
  static final _standardRegex = RegExp(r'\[(\d{1,2}):(\d{2})[:.](\d{2,3})\](.*)', dotAll: true);
  static final _neteaseRegex = RegExp(r'\[(\d+),(\d+)\](.*)', dotAll: true);

  factory SyncedLyrics.fromLrc(String lrcContent) {
    final lines = <LyricLine>[];
    String? artist;
    String? title;

    for (final line in lrcContent.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      if (trimmed.startsWith('[ar:')) {
        artist = trimmed.substring(4, trimmed.length - 1).trim();
        continue;
      }
      if (trimmed.startsWith('[ti:')) {
        title = trimmed.substring(4, trimmed.length - 1).trim();
        continue;
      }

      if (trimmed.startsWith('[al:') ||
          trimmed.startsWith('[by:') ||
          trimmed.startsWith('[offset:') ||
          trimmed.startsWith('[re:') ||
          trimmed.startsWith('[ve:')) {
        continue;
      }

      // 1) Стандарт [mm:ss.xx] — как в aonsoku/Castafiore
      final stdMatch = _standardRegex.firstMatch(trimmed);
      if (stdMatch != null) {
        final minutes = int.tryParse(stdMatch.group(1) ?? '');
        final seconds = int.tryParse(stdMatch.group(2) ?? '');
        final millisPart = stdMatch.group(3);
        if (minutes == null || seconds == null || millisPart == null) continue;
        final millisRaw = int.tryParse(millisPart);
        if (millisRaw == null) continue;
        final milliseconds = millisPart.length == 2 ? millisRaw * 10 : millisRaw;
        final rawText = stdMatch.group(4) ?? '';
        final lineTimestamp = Duration(minutes: minutes, seconds: seconds, milliseconds: milliseconds);

        if (_wordTagRegex.hasMatch(rawText)) {
          final cleanText = rawText.replaceAll(_wordTagRegex, '').replaceAll(RegExp(r'\s+'), ' ').trim();
          if (cleanText.isNotEmpty) {
            final wordSegs = _parseWordSegments(rawText);
            lines.add(LyricLine(timestamp: lineTimestamp, text: cleanText, words: wordSegs.isNotEmpty ? wordSegs : null));
          }
        } else {
          final text = rawText.trim();
          if (text.isNotEmpty) lines.add(LyricLine(timestamp: lineTimestamp, text: text));
        }
        continue;
      }

      // 2) NetEase [offset,duration] — feishin alternateTimeExp
      final neMatch = _neteaseRegex.firstMatch(trimmed);
      if (neMatch != null) {
        final startMs = int.tryParse(neMatch.group(1) ?? '0') ?? 0;
        final text = (neMatch.group(3) ?? '').trim();
        if (text.isNotEmpty) {
          lines.add(LyricLine(timestamp: Duration(milliseconds: startMs), text: text));
        }
        continue;
      }
    }

    lines.sort((a, b) => a.timestamp.compareTo(b.timestamp));

    return SyncedLyrics(lines: lines, artist: artist, title: title);
  }

  factory SyncedLyrics.fromPlainText(String text) {
    final lines = text
        .split('\n')
        .where((line) => line.trim().isNotEmpty)
        .toList();

    return SyncedLyrics(
      lines: lines.asMap().entries.map((entry) {
        return LyricLine(timestamp: Duration.zero, text: entry.value.trim());
      }).toList(),
    );
  }

  int getCurrentLineIndex(Duration position) {
    if (lines.isEmpty) return -1;
    if (position < lines.first.timestamp) {
      return -1;
    }

    for (int i = lines.length - 1; i >= 0; i--) {
      if (position >= lines[i].timestamp) {
        return i;
      }
    }
    return -1;
  }
}

class LyricLine {
  final Duration timestamp;
  final String text;
  final List<WordSegment>? words;

  LyricLine({required this.timestamp, required this.text, this.words});

  bool get hasWordTimestamps => words != null && words!.isNotEmpty;

  @override
  String toString() => '[$timestamp] $text';
}
