import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/player_provider.dart' as pp;
import '../../services/subsonic_service.dart';
import 'skin_common.dart';

// YouTube Music style: red/black, bold typography, rectangular artwork with strong shadow
class YoutubePlayerScreen extends StatelessWidget {
  const YoutubePlayerScreen({super.key});
  Widget _ph()=>Container(color: const Color(0xFF212121), child: const Center(child: Icon(Icons.play_arrow_rounded, size: 80, color: Colors.white24)));

  @override
  Widget build(BuildContext context){
    final p=Provider.of<pp.PlayerProvider>(context);
    final s=p.currentSong;
    final loc = AppLocalizations.of(context)!;
    final svc=Provider.of<SubsonicService>(context, listen: false);
    final isRadio = p.isPlayingRadio && p.currentRadioStation != null;
    final url = isRadio ? '' : SkinCommon.coverUrl(s, svc);
    final title = isRadio ? p.currentRadioStation!.name : (s?.title ?? loc.noSongPlaying);
    final artist = isRadio ? loc.internetRadio : (s?.artist ?? loc.unknownArtist);
    return Scaffold(
      backgroundColor: const Color(0xFF030303),
      body: Container(
        decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFFFF0000), Color(0xFF212121), Color(0xFF030303)], stops: [0.0, 0.30, 1.0])),
        child: SafeArea(child: Column(children: [
          Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4), child: Row(children: [
            IconButton(icon: const Icon(Icons.keyboard_arrow_down_rounded, color: Colors.white, size: 28), onPressed: ()=>Navigator.pop(context)),
            const Spacer(),
            const Row(children: [Icon(Icons.play_arrow_rounded, color: Colors.white, size: 18), SizedBox(width: 4), Text('YouTube Music', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700, letterSpacing: 0.4))]),
            const Spacer(),
            IconButton(icon: const Icon(Icons.more_vert_rounded, color: Colors.white70), onPressed: ()=>SkinCommon.openQueue(context)),
          ])),
          Expanded(child: Center(child: GestureDetector(
              onHorizontalDragEnd: (d) => SkinCommon.onHSwipe(context, d, s),
              onVerticalDragEnd: (d) { if ((d.primaryVelocity ?? 0) > 500 && Navigator.canPop(context)) Navigator.pop(context); },
              child: Container(width: MediaQuery.of(context).size.width*0.92, height: MediaQuery.of(context).size.width*0.62, constraints: const BoxConstraints(maxWidth: 420, maxHeight: 280), decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.5), blurRadius: 24, offset: const Offset(0,12))]), child: ClipRRect(borderRadius: BorderRadius.circular(12), child: SkinCommon.artwork(url, placeholder: _ph())))))),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 20), child: Column(children: [
            Text(title, style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800), maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center),
            const SizedBox(height: 4),
            Text(artist, style: const TextStyle(color: Colors.white70, fontSize: 15, fontWeight: FontWeight.w500), maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center),
          ])),
          const SizedBox(height: 14),
          _progress(context,p),
          const SizedBox(height: 12),
          _controls(context,p),
          const SizedBox(height: 10),
          _bottom(context,p),
          const SizedBox(height: 16),
        ])),
      ),
    );
  }
  Widget _progress(BuildContext ctx, pp.PlayerProvider p){final dur=p.currentSong?.duration!=null? Duration(seconds: p.currentSong!.duration!):Duration.zero; return Padding(padding: const EdgeInsets.symmetric(horizontal: 20), child: StreamBuilder<Duration>(stream: p.positionStream, initialData: p.position, builder: (_,snap){final pos=snap.data??Duration.zero; return Column(children: [SliderTheme(data: SliderTheme.of(ctx).copyWith(trackHeight: 3, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6), activeTrackColor: const Color(0xFFFF0000), inactiveTrackColor: Colors.white24, thumbColor: Colors.white), child: Slider(value: pos.inSeconds.toDouble().clamp(0, dur.inSeconds.toDouble()), max: dur.inSeconds.toDouble()>0?dur.inSeconds.toDouble():1, onChanged: (v)=>p.seek(Duration(seconds: v.toInt())))), Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(_fmt(pos), style: const TextStyle(color: Colors.white60, fontSize: 11)), Text(_fmt(dur), style: const TextStyle(color: Colors.white60, fontSize: 11))])]);}));}
  Widget _controls(BuildContext ctx, pp.PlayerProvider p)=>Padding(padding: const EdgeInsets.symmetric(horizontal: 20), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
    IconButton(icon: Icon(p.shuffleEnabled?Icons.shuffle_on_rounded:Icons.shuffle_rounded, color: p.shuffleEnabled?const Color(0xFFFF0000):Colors.white60), onPressed: ()=>p.toggleShuffle()),
    GestureDetector(onTap: ()=>p.skipPrevious(), child: const Icon(Icons.skip_previous_rounded, color: Colors.white, size: 38)),
    GestureDetector(onTap: ()=>p.togglePlayPause(), child: Container(width: 64,height:64, decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle), child: Icon(p.isPlaying?Icons.pause_rounded:Icons.play_arrow_rounded, color: Colors.black, size: 34))),
    GestureDetector(onTap: ()=>p.skipNext(), child: const Icon(Icons.skip_next_rounded, color: Colors.white, size: 38)),
    IconButton(icon: Icon(p.repeatMode!=pp.RepeatMode.off?Icons.repeat_on_rounded:Icons.repeat_rounded, color: p.repeatMode!=pp.RepeatMode.off?const Color(0xFFFF0000):Colors.white60), onPressed: ()=>p.toggleRepeat()),
  ]));
  Widget _bottom(BuildContext ctx, pp.PlayerProvider p)=>Row(mainAxisAlignment: MainAxisAlignment.center, children: [
    IconButton(icon: Icon(p.currentSong?.starred==true?Icons.thumb_up_rounded:Icons.thumb_up_outlined, color: p.currentSong?.starred==true?const Color(0xFFFF0000):Colors.white60), onPressed: ()=>p.toggleFavorite()),
    const SizedBox(width: 16),
    IconButton(icon: const Icon(Icons.queue_music_rounded, color: Colors.white60), onPressed: ()=>SkinCommon.openQueue(ctx)),
    const SizedBox(width: 16),
    IconButton(icon: const Icon(Icons.lyrics_rounded, color: Colors.white60), onPressed: ()=>SkinCommon.openLyrics(ctx, p.currentSong)),
  ]);
  String _fmt(Duration d)=>'${d.inMinutes}:${(d.inSeconds%60).toString().padLeft(2,'0')}';
}
