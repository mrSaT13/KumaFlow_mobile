import 'package:flutter/material.dart';
import '../models/song.dart';
import '../theme/app_theme.dart';
import '../services/auto_dj_service.dart';

class InstantMixDialog extends StatefulWidget {
  final Song seedSong;
  final AutoDjService autoDjService;
  final List<Song>? availableSongs;
  final void Function(List<Song> songs) onConfirm;

  const InstantMixDialog({
    super.key,
    required this.seedSong,
    required this.autoDjService,
    this.availableSongs,
    required this.onConfirm,
  });

  static Future<void> show({
    required BuildContext context,
    required Song seedSong,
    required AutoDjService autoDjService,
    List<Song>? availableSongs,
    required void Function(List<Song> songs) onConfirm,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => InstantMixDialog(
        seedSong: seedSong,
        autoDjService: autoDjService,
        availableSongs: availableSongs,
        onConfirm: onConfirm,
      ),
    );
  }

  @override
  State<InstantMixDialog> createState() => _InstantMixDialogState();
}

class _InstantMixDialogState extends State<InstantMixDialog> {
  int _trackCount = 25;
  String? _selectedMood;
  bool _isLoading = false;
  List<Song> _previewSongs = [];

  static const List<int> _trackCountOptions = [10, 25, 50];
  static const List<Map<String, String>> _moodOptions = [
    {'key': 'energetic', 'label': 'Energetic', 'icon': 'bolt'},
    {'key': 'calm', 'label': 'Calm', 'icon': 'spa'},
    {'key': 'happy', 'label': 'Happy', 'icon': 'sentiment_very_satisfied'},
    {'key': 'sad', 'label': 'Melancholy', 'icon': 'sentiment_dissatisfied'},
  ];

  @override
  void initState() {
    super.initState();
    _loadPreview();
  }

  Future<void> _loadPreview() async {
    setState(() => _isLoading = true);
    try {
      final mix = await widget.autoDjService.getInstantMix(
        seedSong: widget.seedSong,
        count: _trackCount,
        mood: _selectedMood,
        availableSongs: widget.availableSongs,
      );
      if (mounted) {
        setState(() {
          _previewSongs = mix;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _onTrackCountChanged(int count) {
    setState(() => _trackCount = count);
    _loadPreview();
  }

  void _onMoodChanged(String? mood) {
    setState(() => _selectedMood = mood);
    _loadPreview();
  }

  void _onConfirm() {
    Navigator.of(context).pop();
    widget.onConfirm(_previewSongs);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? AppTheme.darkSurface : Colors.white;
    final textColor = isDark ? Colors.white : Colors.black;
    final secondaryText = isDark
        ? AppTheme.darkSecondaryText
        : AppTheme.lightSecondaryText;
    final cardColor = isDark ? AppTheme.darkCard : const Color(0xFFF5F5F5);
    final accent = Theme.of(context).colorScheme.primary;

    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(20),
            ),
          ),
          child: Column(
            children: [
              // Handle bar
              Container(
                margin: const EdgeInsets.only(top: 12),
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: secondaryText.withAlpha(80),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),

              // Header
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                child: Row(
                  children: [
                    Icon(Icons.auto_awesome, color: accent, size: 24),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Instant Mix',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              color: textColor,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Based on "${widget.seedSong.title}"',
                            style: TextStyle(
                              fontSize: 13,
                              color: secondaryText,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: Icon(Icons.close, color: secondaryText),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // Controls
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Track count selector
                    Text(
                      'Tracks',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: secondaryText,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: _trackCountOptions.map((count) {
                        final isSelected = _trackCount == count;
                        return Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                            ),
                            child: GestureDetector(
                              onTap: () => _onTrackCountChanged(count),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 10,
                                ),
                                decoration: BoxDecoration(
                                  color: isSelected ? accent : cardColor,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Center(
                                  child: Text(
                                    '$count',
                                    style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600,
                                      color: isSelected
                                          ? Colors.white
                                          : textColor,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),

                    const SizedBox(height: 16),

                    // Mood selector
                    Text(
                      'Mood',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: secondaryText,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        // "All" option
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                            ),
                            child: GestureDetector(
                              onTap: () => _onMoodChanged(null),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 10,
                                ),
                                decoration: BoxDecoration(
                                  color: _selectedMood == null
                                      ? accent
                                      : cardColor,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Center(
                                  child: Text(
                                    'All',
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      color: _selectedMood == null
                                          ? Colors.white
                                          : textColor,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        ..._moodOptions.map((mood) {
                          final isSelected = _selectedMood == mood['key'];
                          return Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                              ),
                              child: GestureDetector(
                                onTap: () =>
                                    _onMoodChanged(mood['key']),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 10,
                                  ),
                                  decoration: BoxDecoration(
                                    color: isSelected ? accent : cardColor,
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Center(
                                    child: Text(
                                      mood['label']!,
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                        color: isSelected
                                            ? Colors.white
                                            : textColor,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          );
                        }),
                      ],
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // Preview list
              Expanded(
                child: _isLoading
                    ? Center(
                        child: CircularProgressIndicator(
                          color: accent,
                        ),
                      )
                    : _previewSongs.isEmpty
                        ? Center(
                            child: Text(
                              'No songs found',
                              style: TextStyle(
                                color: secondaryText,
                                fontSize: 15,
                              ),
                            ),
                          )
                        : ListView.builder(
                            controller: scrollController,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 20,
                            ),
                            itemCount: _previewSongs.length,
                            itemBuilder: (context, index) {
                              final song = _previewSongs[index];
                              final isSeed = index == 0;
                              return _buildSongTile(
                                song: song,
                                index: index,
                                isSeed: isSeed,
                                textColor: textColor,
                                secondaryText: secondaryText,
                                cardColor: cardColor,
                                accent: accent,
                              );
                            },
                          ),
              ),

              // Confirm button
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                child: SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: ElevatedButton(
                    onPressed: _previewSongs.isNotEmpty ? _onConfirm : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: accent,
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: accent.withAlpha(100),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      elevation: 0,
                    ),
                    child: Text(
                      'Play Mix (${_previewSongs.length} tracks)',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSongTile({
    required Song song,
    required int index,
    required bool isSeed,
    required Color textColor,
    required Color secondaryText,
    required Color cardColor,
    required Color accent,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        color: isSeed ? accent.withAlpha(20) : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 2,
        ),
        leading: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: cardColor,
            borderRadius: BorderRadius.circular(6),
          ),
          child: isSeed
              ? Icon(Icons.play_circle_fill, color: accent, size: 24)
              : Center(
                  child: Text(
                    '${index}',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: secondaryText,
                    ),
                  ),
                ),
        ),
        title: Text(
          song.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 14,
            fontWeight: isSeed ? FontWeight.w600 : FontWeight.normal,
            color: textColor,
          ),
        ),
        subtitle: Text(
          song.artist ?? 'Unknown Artist',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12,
            color: secondaryText,
          ),
        ),
        trailing: Text(
          song.formattedDuration,
          style: TextStyle(
            fontSize: 12,
            color: secondaryText,
          ),
        ),
      ),
    );
  }
}
