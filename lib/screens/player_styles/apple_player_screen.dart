import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/player_provider.dart' as pp;
import '../../services/subsonic_service.dart';
import 'skin_common.dart';

// Apple Music style: light blur, rounded artwork 12, red accent
class ApplePlayerScreen extends StatelessWidget {
  const ApplePlayerScreen({super.key});
  Widget _ph()=>Container(color: const Color(0xFFF2F2F7), child: const Center(child: Icon(Icons.music_note_rounded, size: 72, color: Colors.black12)));

  @override
  Widget build(BuildContext context) {
    final p=Provider.of<pp.PlayerProvider>(context);
    final s=p.currentSong;
    final loc = AppLocalizations.of(context)!;
    final svc=Provider.of<SubsonicService>(context, listen: false);
    final isRadio = p.isPlayingRadio && p.currentRadioStation != null;
    final url = isRadio ? '' : SkinCommon.coverUrl(s, svc);
    final title = isRadio ? p.currentRadioStation!.name : (s?.title ?? loc.noSongPlaying);
    final artist = isRadio ? loc.internetRadio : (s?.artist ?? loc.unknownArtist);
    final album = isRadio ? '' : (s?.album ?? '');
    return Scaffold(
      backgroundColor: const Color(0xFFF2F2F7),
      body: Container(
        decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.white, Color(0xFFF2F2F7)])),
        child: SafeArea(child: Column(children: [
          _header(context),
          Expanded(child: Center(child: GestureDetector(
              onHorizontalDragEnd: (d) => SkinCommon.onHSwipe(context, d, s),
              onVerticalDragEnd: (d) { if ((d.primaryVelocity ?? 0) > 500 && Navigator.canPop(context)) Navigator.pop(context); },
              child: Container(width: MediaQuery.of(context).size.width*0.82, height: MediaQuery.of(context).size.width*0.82, constraints: const BoxConstraints(maxWidth: 360, maxHeight: 360), decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.15), blurRadius: 24, offset: const Offset(0,12))]), child: ClipRRect(borderRadius: BorderRadius.circular(12), child: SkinCommon.artwork(url, placeholder: _ph())))))),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 24), child: Column(children: [
            Text(title, style: const TextStyle(color: Colors.black, fontSize: 20, fontWeight: FontWeight.w700), maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center),
            const SizedBox(height: 4),
            Text(artist, style: const TextStyle(color: Color(0xFF8E8E93), fontSize: 16, fontWeight: FontWeight.w500), maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center),
            const SizedBox(height: 2),
            Text(album, style: const TextStyle(color: Color(0xFFAEAEB2), fontSize: 13), maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center),
          ])),
          const SizedBox(height: 16),
          _progress(context,p),
          const SizedBox(height: 16),
          _controls(context,p),
          const SizedBox(height: 16),
          _bottom(context,p),
          const SizedBox(height: 10),
        ])),
      ),
    );
  }
  Widget _header(BuildContext ctx)=>Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Row(children: [IconButton(icon: const Icon(Icons.keyboard_arrow_down_rounded, color: Colors.black54, size: 28), onPressed: ()=>Navigator.pop(ctx)), const Spacer(), const Text('Apple Music', style: TextStyle(color: Colors.black87, fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.8)), const Spacer(), IconButton(icon: const Icon(Icons.more_horiz_rounded, color: Colors.black54), onPressed: ()=>SkinCommon.openQueue(ctx))]));
  Widget _progress(BuildContext ctx, pp.PlayerProvider p){final dur=p.currentSong?.duration!=null? Duration(seconds: p.currentSong!.duration!):Duration.zero; return Padding(padding: const EdgeInsets.symmetric(horizontal: 24), child: StreamBuilder<Duration>(stream: p.positionStream, initialData: p.position, builder: (_,snap){final pos=snap.data??Duration.zero; return Column(children: [SliderTheme(data: SliderTheme.of(ctx).copyWith(trackHeight: 4, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7), activeTrackColor: const Color(0xFFFA243C), inactiveTrackColor: Colors.black12, thumbColor: const Color(0xFFFA243C)), child: Slider(value: pos.inSeconds.toDouble().clamp(0, dur.inSeconds.toDouble()), max: dur.inSeconds.toDouble()>0?dur.inSeconds.toDouble():1, onChanged: (v)=>p.seek(Duration(seconds: v.toInt())))), Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(_fmt(pos), style: const TextStyle(color: Colors.black45, fontSize: 11)), Text(_fmt(dur), style: const TextStyle(color: Colors.black45, fontSize: 11))])]);}));}
  Widget _controls(BuildContext ctx, pp.PlayerProvider p)=>Padding(padding: const EdgeInsets.symmetric(horizontal: 28), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
    IconButton(icon: Icon(Icons.skip_previous_rounded, color: Colors.black87, size: 30), onPressed: ()=>p.skipPrevious()),
    Container(width: 56,height:56, decoration: BoxDecoration(color: const Color(0xFFFA243C), shape: BoxShape.circle, boxShadow: [BoxShadow(color: const Color(0xFFFA243C).withOpacity(0.35), blurRadius: 16)]), child: IconButton(icon: Icon(p.isPlaying?Icons.pause_rounded:Icons.play_arrow_rounded, color: Colors.white, size: 28), onPressed: ()=>p.togglePlayPause())),
    IconButton(icon: Icon(Icons.skip_next_rounded, color: Colors.black87, size: 30), onPressed: ()=>p.skipNext()),
  ]));
  Widget _bottom(BuildContext ctx, pp.PlayerProvider p)=>Row(mainAxisAlignment: MainAxisAlignment.center, children: [
    IconButton(icon: Icon(p.shuffleEnabled?Icons.shuffle_on_rounded:Icons.shuffle_rounded, color: p.shuffleEnabled?const Color(0xFFFA243C):Colors.black38), onPressed: ()=>p.toggleShuffle()),
    const SizedBox(width: 12),
    IconButton(icon: Icon(p.currentSong?.starred==true?Icons.favorite_rounded:Icons.favorite_border_rounded, color: p.currentSong?.starred==true?const Color(0xFFFA243C):Colors.black38), onPressed: ()=>p.toggleFavorite()),
    const SizedBox(width: 12),
    IconButton(icon: const Icon(Icons.queue_music_rounded, color: Colors.black38), onPressed: ()=>SkinCommon.openQueue(ctx)),
    const SizedBox(width: 12),
    IconButton(icon: Icon(p.repeatMode!=pp.RepeatMode.off?Icons.repeat_on_rounded:Icons.repeat_rounded, color: p.repeatMode!=pp.RepeatMode.off?const Color(0xFFFA243C):Colors.black38), onPressed: ()=>p.toggleRepeat()),
  ]);
  String _fmt(Duration d)=>'${d.inMinutes}:${(d.inSeconds%60).toString().padLeft(2,'0')}';
}
