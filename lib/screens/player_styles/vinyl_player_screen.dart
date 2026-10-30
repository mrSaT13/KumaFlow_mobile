import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/player_provider.dart' as pp;
import '../../services/subsonic_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/multi_artist_widget.dart';
import 'skin_common.dart';

// Vinyl style: rotating disc with center hole, needle arm
class VinylPlayerScreen extends StatefulWidget {
  const VinylPlayerScreen({super.key});
  @override State<VinylPlayerScreen> createState()=>_VinylState();
}
class _VinylState extends State<VinylPlayerScreen> with SingleTickerProviderStateMixin{
  late AnimationController _rot;
  @override void initState(){super.initState(); _rot=AnimationController(vsync: this, duration: const Duration(seconds: 12))..repeat();}
  @override void dispose(){_rot.dispose(); super.dispose();}
  Widget _ph()=>Container(color: const Color(0xFF1a1a1a), child: const Center(child: Icon(Icons.album_rounded, size: 64, color: Colors.white24)));
  @override Widget build(BuildContext context){
    final p=Provider.of<pp.PlayerProvider>(context);
    final s=p.currentSong;
    final loc = AppLocalizations.of(context)!;
    final svc=Provider.of<SubsonicService>(context, listen: false);
    final isRadio = p.isPlayingRadio && p.currentRadioStation != null;
    final url = isRadio ? '' : SkinCommon.coverUrl(s, svc);
    final title = isRadio ? p.currentRadioStation!.name : (s?.title ?? loc.noSongPlaying);
    final isPlaying=p.isPlaying;
    if(isPlaying && !_rot.isAnimating) _rot.repeat(); if(!isPlaying) _rot.stop();
    return Scaffold(
      backgroundColor: const Color(0xFF0f0f0f),
      body: Container(
        decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF1a1a1a), Color(0xFF2b1a0f), Color(0xFF0f0f0f)])),
        child: SafeArea(child: Column(children: [
          _header(context),
          const SizedBox(height: 8),
          Expanded(child: GestureDetector(
            onTap: ()=>p.togglePlayPause(),
            onHorizontalDragEnd: (d)=>SkinCommon.onHSwipe(context, d, s),
            onVerticalDragEnd: (d) { if ((d.primaryVelocity ?? 0) > 500 && Navigator.canPop(context)) Navigator.pop(context); },
            child: Stack(alignment: Alignment.center, children: [
            // Vinyl disc
            AnimatedBuilder(animation: _rot, builder: (_, child){
              return Transform.rotate(angle: _rot.value*2*math.pi, child: child);
            }, child: Container(width: MediaQuery.of(context).size.width*0.78, height: MediaQuery.of(context).size.width*0.78, constraints: const BoxConstraints(maxWidth: 340, maxHeight: 340), decoration: BoxDecoration(shape: BoxShape.circle, color: const Color(0xFF0a0a0a), border: Border.all(color: const Color(0xFF222222), width: 2), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.7), blurRadius: 30, offset: const Offset(0,16))]), child: Stack(alignment: Alignment.center, children: [
              // grooves
              Container(decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.white.withOpacity(0.04), width: 1))),
              Container(margin: const EdgeInsets.all(18), decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.white.withOpacity(0.06), width: 1))),
              Container(margin: const EdgeInsets.all(36), decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.white.withOpacity(0.05), width: 1))),
              // center artwork
              Container(width: 140, height: 140, decoration: const BoxDecoration(shape: BoxShape.circle), child: ClipOval(child: SkinCommon.artwork(url, placeholder: _ph()))),
              // center hole
              Container(width: 18, height: 18, decoration: BoxDecoration(shape: BoxShape.circle, color: const Color(0xFF111111), border: Border.all(color: Colors.white24, width: 1.5))),
            ]))),
            // needle arm (static)
            Positioned(top: 0, right: MediaQuery.of(context).size.width*0.12, child: Transform.rotate(angle: 0.35, child: Container(width: 6, height: 140, decoration: BoxDecoration(color: const Color(0xFFc0c0c0), borderRadius: BorderRadius.circular(3), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.4), blurRadius: 8)])))),
          ]))),
          GestureDetector(
            onHorizontalDragEnd: (d)=>SkinCommon.onHSwipe(context, d, s),
            child: Padding(padding: const EdgeInsets.symmetric(horizontal: 24), child: Column(children: [
            Text(title, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold), maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center),
            const SizedBox(height: 4),
            if (isRadio)
              Text(loc.internetRadio, style: const TextStyle(color: Colors.white60, fontSize: 15), maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center)
            else
              MultiArtistWidget(
                artists: s?.artistParticipants,
                artistFallback: s?.artist,
                artistIdFallback: s?.artistId,
                style: const TextStyle(color: Colors.white60, fontSize: 15),
                onBeforeNavigate: () { if (Navigator.canPop(context)) Navigator.pop(context); },
              ),
          ]))),
          const SizedBox(height: 12),
          _progress(context,p),
          const SizedBox(height: 12),
          _controls(context,p),
          const SizedBox(height: 12),
          _bottom(context,p),
          const SizedBox(height: 12),
        ])),
      ),
    );
  }
  Widget _header(BuildContext ctx)=>Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Row(children: [IconButton(icon: const Icon(Icons.keyboard_arrow_down_rounded, color: Colors.white70, size: 28), onPressed: ()=>Navigator.pop(ctx)), const Spacer(), const Text('VINYL', style: TextStyle(color: Colors.white60, fontSize: 11, letterSpacing: 2)), const Spacer(), IconButton(icon: const Icon(Icons.more_horiz_rounded, color: Colors.white70), onPressed: ()=>SkinCommon.openQueue(ctx))]));
  Widget _progress(BuildContext ctx, pp.PlayerProvider p){final dur=p.currentSong?.duration!=null? Duration(seconds: p.currentSong!.duration!):Duration.zero; return Padding(padding: const EdgeInsets.symmetric(horizontal: 24), child: StreamBuilder<Duration>(stream: p.positionStream, initialData: p.position, builder: (_,snap){final pos=snap.data??Duration.zero; return Column(children: [SliderTheme(data: SliderTheme.of(ctx).copyWith(trackHeight: 3, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6), activeTrackColor: AppTheme.appleMusicRed, inactiveTrackColor: Colors.white24, thumbColor: AppTheme.appleMusicRed), child: Slider(value: pos.inSeconds.toDouble().clamp(0, dur.inSeconds.toDouble()), max: dur.inSeconds.toDouble()>0?dur.inSeconds.toDouble():1, onChanged: (v)=>p.seek(Duration(seconds: v.toInt())))), Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(_fmt(pos), style: const TextStyle(color: Colors.white54, fontSize: 11)), Text(_fmt(dur), style: const TextStyle(color: Colors.white54, fontSize: 11))])]);}));}
  Widget _controls(BuildContext ctx, pp.PlayerProvider p)=>Padding(padding: const EdgeInsets.symmetric(horizontal: 24), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
    IconButton(icon: Icon(p.shuffleEnabled?Icons.shuffle_on_rounded:Icons.shuffle_rounded, color: p.shuffleEnabled?AppTheme.appleMusicRed:Colors.white38), onPressed: ()=>p.toggleShuffle()),
    GestureDetector(onTap: ()=>p.skipPrevious(), child: const Icon(Icons.skip_previous_rounded, color: Colors.white, size: 36)),
    GestureDetector(onTap: ()=>p.togglePlayPause(), child: Container(width: 60,height:60, decoration: BoxDecoration(color: AppTheme.appleMusicRed, shape: BoxShape.circle, boxShadow: [BoxShadow(color: AppTheme.appleMusicRed.withOpacity(0.4), blurRadius: 16)]), child: Icon(p.isPlaying?Icons.pause_rounded:Icons.play_arrow_rounded, color: Colors.white, size: 32))),
    GestureDetector(onTap: ()=>p.skipNext(), child: const Icon(Icons.skip_next_rounded, color: Colors.white, size: 36)),
    IconButton(icon: Icon(p.repeatMode!=pp.RepeatMode.off?Icons.repeat_on_rounded:Icons.repeat_rounded, color: p.repeatMode!=pp.RepeatMode.off?AppTheme.appleMusicRed:Colors.white38), onPressed: ()=>p.toggleRepeat()),
  ]));
  Widget _bottom(BuildContext ctx, pp.PlayerProvider p)=>Row(mainAxisAlignment: MainAxisAlignment.center, children: [
    IconButton(icon: Icon(p.currentSong?.starred==true?Icons.favorite_rounded:Icons.favorite_border_rounded, color: p.currentSong?.starred==true?AppTheme.appleMusicRed:Colors.white38), onPressed: ()=>p.toggleFavorite()),
    const SizedBox(width: 16),
    IconButton(icon: const Icon(Icons.lyrics_rounded, color: Colors.white38), onPressed: ()=>SkinCommon.openLyrics(ctx, p.currentSong)),
    const SizedBox(width: 16),
    IconButton(icon: const Icon(Icons.queue_music_rounded, color: Colors.white38), onPressed: ()=>SkinCommon.openQueue(ctx)),
  ]);
  String _fmt(Duration d)=>'${d.inMinutes}:${(d.inSeconds%60).toString().padLeft(2,'0')}';
}
