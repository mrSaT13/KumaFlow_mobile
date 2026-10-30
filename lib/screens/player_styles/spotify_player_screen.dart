import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/player_provider.dart' as pp;
import '../../services/subsonic_service.dart';
import 'skin_common.dart';

// Spotify-style: dark background #121212, green accent, rounded controls
class SpotifyPlayerScreen extends StatelessWidget {
  const SpotifyPlayerScreen({super.key});

  Widget _placeholder()=>Container(color: const Color(0xFF282828), child: const Center(child: Icon(Icons.music_note_rounded, size: 80, color: Colors.white24)));

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<pp.PlayerProvider>(context);
    final song = provider.currentSong;
    final loc = AppLocalizations.of(context)!;
    final svc = Provider.of<SubsonicService>(context, listen: false);
    final isRadio = provider.isPlayingRadio && provider.currentRadioStation != null;
    final url = isRadio ? '' : SkinCommon.coverUrl(song, svc);
    final title = isRadio ? provider.currentRadioStation!.name : (song?.title ?? loc.noSongPlaying);
    final artist = isRadio ? loc.internetRadio : (song?.artist ?? loc.unknownArtist);
    return Scaffold(
      backgroundColor: const Color(0xFF000000),
      body: Container(
        decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF1DB954), Color(0xFF121212), Color(0xFF000000)], stops: [0.0, 0.35, 1.0])),
        child: SafeArea(child: Column(children: [
          _header(context),
          Expanded(child: Center(child: GestureDetector(
              onHorizontalDragEnd: (d) => SkinCommon.onHSwipe(context, d, song),
              onVerticalDragEnd: (d) { if ((d.primaryVelocity ?? 0) > 500 && Navigator.canPop(context)) Navigator.pop(context); },
              child: Container(width: MediaQuery.of(context).size.width*0.88, height: MediaQuery.of(context).size.width*0.88, constraints: const BoxConstraints(maxWidth: 380, maxHeight: 380), decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.6), blurRadius: 30, offset: const Offset(0,16))]), child: ClipRRect(borderRadius: BorderRadius.circular(8), child: SkinCommon.artwork(url, placeholder: _placeholder())))))),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 24), child: Column(children: [
            Text(title, style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold), maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center),
            const SizedBox(height: 6),
            Text(artist, style: const TextStyle(color: Colors.white70, fontSize: 16), maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center),
          ])),
          const SizedBox(height: 18),
          _progress(context, provider),
          const SizedBox(height: 18),
          _controls(context, provider),
          const SizedBox(height: 12),
          _bottom(context, provider),
          const SizedBox(height: 16),
        ])),
      ),
    );
  }

  Widget _header(BuildContext ctx)=>Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4), child: Row(children: [IconButton(icon: const Icon(Icons.keyboard_arrow_down_rounded, color: Colors.white, size: 28), onPressed: ()=>Navigator.pop(ctx)), const Spacer(), const Text('SPOTIFY STYLE', style: TextStyle(color: Colors.white70, fontSize: 11, letterSpacing: 1.2)), const Spacer(), IconButton(icon: const Icon(Icons.more_vert_rounded, color: Colors.white70), onPressed: ()=>SkinCommon.openQueue(ctx))]));

  Widget _progress(BuildContext ctx, pp.PlayerProvider p){
    final dur = p.currentSong?.duration != null ? Duration(seconds: p.currentSong!.duration!) : Duration.zero;
    return Padding(padding: const EdgeInsets.symmetric(horizontal: 24), child: StreamBuilder<Duration>(stream: p.positionStream, initialData: p.position, builder: (_, snap){
      final pos = snap.data ?? Duration.zero;
      return Column(children: [
        SliderTheme(data: SliderTheme.of(ctx).copyWith(trackHeight: 4, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6), activeTrackColor: const Color(0xFF1DB954), inactiveTrackColor: Colors.white24, thumbColor: Colors.white), child: Slider(value: pos.inSeconds.toDouble().clamp(0, dur.inSeconds.toDouble()), max: dur.inSeconds.toDouble()>0?dur.inSeconds.toDouble():1, onChanged: (v)=>p.seek(Duration(seconds: v.toInt())))),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(_fmt(pos), style: const TextStyle(color: Colors.white60, fontSize: 11)), Text(_fmt(dur), style: const TextStyle(color: Colors.white60, fontSize: 11))]),
      ]);
    }));
  }
  Widget _controls(BuildContext ctx, pp.PlayerProvider p)=>Padding(padding: const EdgeInsets.symmetric(horizontal: 24), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
    IconButton(icon: Icon(p.shuffleEnabled?Icons.shuffle_on_rounded:Icons.shuffle_rounded, color: p.shuffleEnabled?const Color(0xFF1DB954):Colors.white70), onPressed: ()=>p.toggleShuffle()),
    GestureDetector(onTap: ()=>p.skipPrevious(), child: const Icon(Icons.skip_previous_rounded, color: Colors.white, size: 38)),
    GestureDetector(onTap: ()=>p.togglePlayPause(), child: Container(width: 62,height:62, decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle), child: Icon(p.isPlaying?Icons.pause_rounded:Icons.play_arrow_rounded, color: Colors.black, size: 34))),
    GestureDetector(onTap: ()=>p.skipNext(), child: const Icon(Icons.skip_next_rounded, color: Colors.white, size: 38)),
    IconButton(icon: Icon(p.repeatMode!=pp.RepeatMode.off? (p.repeatMode==pp.RepeatMode.one?Icons.repeat_one_rounded:Icons.repeat_on_rounded):Icons.repeat_rounded, color: p.repeatMode!=pp.RepeatMode.off?const Color(0xFF1DB954):Colors.white70), onPressed: ()=>p.toggleRepeat()),
  ]));
  Widget _bottom(BuildContext ctx, pp.PlayerProvider p)=>Padding(padding: const EdgeInsets.symmetric(horizontal: 24), child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
    IconButton(icon: const Icon(Icons.queue_music_rounded, color: Colors.white70), onPressed: ()=>SkinCommon.openQueue(ctx)),
    const SizedBox(width: 24),
    IconButton(icon: Icon(p.currentSong?.starred==true?Icons.favorite_rounded:Icons.favorite_border_rounded, color: p.currentSong?.starred==true?const Color(0xFF1DB954):Colors.white70), onPressed: ()=>p.toggleFavorite()),
  ]));
  String _fmt(Duration d){final m=d.inMinutes; final s=d.inSeconds%60; return '$m:${s.toString().padLeft(2,'0')}';}
}
