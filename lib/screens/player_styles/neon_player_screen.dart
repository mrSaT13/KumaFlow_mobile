import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/player_provider.dart' as pp;
import '../../services/subsonic_service.dart';
import '../../widgets/multi_artist_widget.dart';
import 'skin_common.dart';

// Neon full-bleed: artwork as blurred background, glass card
class NeonPlayerScreen extends StatelessWidget {
  const NeonPlayerScreen({super.key});
  Widget _bgPh()=>Container(color: const Color(0xFF0a0a1a));
  Widget _artPh()=>Container(color: const Color(0xFF1a1a2e), child: const Center(child: Icon(Icons.music_note_rounded, size: 64, color: Colors.white24)));

  @override
  Widget build(BuildContext context){
    final p=Provider.of<pp.PlayerProvider>(context);
    final s=p.currentSong;
    final loc = AppLocalizations.of(context)!;
    final svc=Provider.of<SubsonicService>(context, listen: false);
    final isRadio = p.isPlayingRadio && p.currentRadioStation != null;
    final url = isRadio ? '' : SkinCommon.coverUrl(s, svc);
    final title = isRadio ? p.currentRadioStation!.name : (s?.title ?? loc.noSongPlaying);
    final album = isRadio ? '' : (s?.album ?? '');
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(fit: StackFit.expand, children: [
        SkinCommon.artwork(url, placeholder: _bgPh()),
        // dark overlay + blur
        Container(color: Colors.black.withOpacity(0.35)),
        BackdropFilter(filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18), child: Container(color: Colors.black.withOpacity(0.15))),
        SafeArea(child: Column(children: [
          Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4), child: Row(children: [
            IconButton(icon: const Icon(Icons.keyboard_arrow_down_rounded, color: Colors.white, size: 28), onPressed: ()=>Navigator.pop(context)),
            const Spacer(),
            Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4), decoration: BoxDecoration(color: const Color(0xFF00E5FF).withOpacity(0.9), borderRadius: BorderRadius.circular(20)), child: const Text('NEON', style: TextStyle(color: Colors.black, fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 1.2))),
            const Spacer(),
            IconButton(icon: const Icon(Icons.more_horiz_rounded, color: Colors.white70), onPressed: ()=>SkinCommon.openQueue(context)),
          ])),
          const Spacer(),
          // Glass card
          Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: ClipRRect(borderRadius: BorderRadius.circular(20), child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16), child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: Colors.white.withOpacity(0.08), borderRadius: BorderRadius.circular(20), border: Border.all(color: Colors.white.withOpacity(0.12))),
            child: Column(children: [
              GestureDetector(
                onHorizontalDragEnd: (d) => SkinCommon.onHSwipe(context, d, s),
                onVerticalDragEnd: (d) { if ((d.primaryVelocity ?? 0) > 500 && Navigator.canPop(context)) Navigator.pop(context); },
                child: Row(children: [
                Container(width: 72, height: 72, decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), boxShadow: [BoxShadow(color: const Color(0xFF00E5FF).withOpacity(0.3), blurRadius: 16)]), child: ClipRRect(borderRadius: BorderRadius.circular(12), child: SkinCommon.artwork(url, placeholder: _artPh()))),
                const SizedBox(width: 12),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold), maxLines: 1, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  if (isRadio)
                    Text(loc.internetRadio, style: const TextStyle(color: Colors.white70, fontSize: 13), maxLines: 1, overflow: TextOverflow.ellipsis)
                  else
                    MultiArtistWidget(
                      artists: s?.artistParticipants,
                      artistFallback: s?.artist,
                      artistIdFallback: s?.artistId,
                      style: const TextStyle(color: Colors.white70, fontSize: 13),
                      onBeforeNavigate: () { if (Navigator.canPop(context)) Navigator.pop(context); },
                    ),
                  const SizedBox(height: 2),
                  Text(album, style: const TextStyle(color: Colors.white38, fontSize: 11), maxLines: 1, overflow: TextOverflow.ellipsis),
                ])),
                IconButton(icon: Icon(p.currentSong?.starred==true?Icons.favorite_rounded:Icons.favorite_border_rounded, color: p.currentSong?.starred==true?const Color(0xFFFF2D55):Colors.white70), onPressed: ()=>p.toggleFavorite()),
              ]),
              ),
              const SizedBox(height: 14),
              _progress(context,p),
              const SizedBox(height: 10),
              _controls(context,p),
            ]),
          )))),
          const SizedBox(height: 14),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            IconButton(icon: Icon(p.shuffleEnabled?Icons.shuffle_on_rounded:Icons.shuffle_rounded, color: p.shuffleEnabled?const Color(0xFF00E5FF):Colors.white38), onPressed: ()=>p.toggleShuffle()),
            const SizedBox(width: 12),
            IconButton(icon: const Icon(Icons.lyrics_rounded, color: Colors.white38), onPressed: ()=>SkinCommon.openLyrics(context, s)),
            const SizedBox(width: 12),
            IconButton(icon: const Icon(Icons.queue_music_rounded, color: Colors.white38), onPressed: ()=>SkinCommon.openQueue(context)),
            const SizedBox(width: 12),
            IconButton(icon: Icon(p.repeatMode!=pp.RepeatMode.off?Icons.repeat_on_rounded:Icons.repeat_rounded, color: p.repeatMode!=pp.RepeatMode.off?const Color(0xFF00E5FF):Colors.white38), onPressed: ()=>p.toggleRepeat()),
          ]),
          const SizedBox(height: 10),
        ])),
      ]),
    );
  }
  Widget _progress(BuildContext ctx, pp.PlayerProvider p){final dur=p.currentSong?.duration!=null? Duration(seconds: p.currentSong!.duration!):Duration.zero; return StreamBuilder<Duration>(stream: p.positionStream, initialData: p.position, builder: (_,snap){final pos=snap.data??Duration.zero; return Column(children: [SliderTheme(data: SliderTheme.of(ctx).copyWith(trackHeight: 4, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6), activeTrackColor: const Color(0xFF00E5FF), inactiveTrackColor: Colors.white24, thumbColor: Colors.white), child: Slider(value: pos.inSeconds.toDouble().clamp(0, dur.inSeconds.toDouble()), max: dur.inSeconds.toDouble()>0?dur.inSeconds.toDouble():1, onChanged: (v)=>p.seek(Duration(seconds: v.toInt())))), Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(_fmt(pos), style: const TextStyle(color: Colors.white60, fontSize: 11)), Text(_fmt(dur), style: const TextStyle(color: Colors.white60, fontSize: 11))])]);});}
  Widget _controls(BuildContext ctx, pp.PlayerProvider p)=>Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
    GestureDetector(onTap: ()=>p.skipPrevious(), child: const Icon(Icons.skip_previous_rounded, color: Colors.white, size: 36)),
    GestureDetector(onTap: ()=>p.togglePlayPause(), child: Container(width: 62,height:62, decoration: BoxDecoration(shape: BoxShape.circle, gradient: const LinearGradient(colors: [Color(0xFF00E5FF), Color(0xFF2979FF)]), boxShadow: [BoxShadow(color: const Color(0xFF00E5FF).withOpacity(0.45), blurRadius: 18)]), child: Icon(p.isPlaying?Icons.pause_rounded:Icons.play_arrow_rounded, color: Colors.white, size: 32))),
    GestureDetector(onTap: ()=>p.skipNext(), child: const Icon(Icons.skip_next_rounded, color: Colors.white, size: 36)),
  ]);
  String _fmt(Duration d)=>'${d.inMinutes}:${(d.inSeconds%60).toString().padLeft(2,'0')}';
}
