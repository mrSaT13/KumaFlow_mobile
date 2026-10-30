import 'dart:math' as math;

import '../models/song.dart';
import 'ml/audio_features_cache.dart';
import 'ml/vibe_similarity.dart';

/// Энергия волны В ТАКТ ТРЕКУ без микрофона и без FFT.
///
/// Пульс идёт с частотой BPM трека (кеш audio_features → оценка по жанру
/// → 116), фаза сбрасывается на старте трека. Пауза — плавный спад
/// к спокойным 0.13. Никаких нотифаев: painter опрашивает sample()
/// каждый кадр сам, лишних перестроений дерева нет.
///
/// Честно: фаза кика не привязана к реальным ударам (для этого нужен
/// нативный Visualizer + разрешение микрофона), но темп — настоящий,
/// kamer-жанры качаются медленно, дэнс — быстро. Это и есть «анимации
/// идут по треку», а не метроном.
class WaveEnergyService {
  static final WaveEnergyService _instance = WaveEnergyService._internal();
  factory WaveEnergyService() => _instance;
  WaveEnergyService._internal();

  String? _trackId;
  double _bpm = 116;
  bool _playing = false;
  DateTime _anchor = DateTime.now();
  double _anchorEnergy = 0.13;

  /// Текущий BPM (116 до резолва) и якорная энергия — для шейдера V3.
  double get bpm => _bpm;
  double get anchorEnergy => _anchorEnergy;

  /// Трек/плей-стейт из hero (дёшево, нотифаев нет).
  void setTrack(Song? song, {required bool playing}) {
    final id = song?.id;
    if (id != _trackId) {
      // Запоминаем энергию перехода чтобы не было скачка.
      _anchorEnergy = sample().energy;
      _trackId = id;
      _anchor = DateTime.now();
      _bpm = 116;
      if (song != null) _resolveBpm(song);
    }
    if (playing != _playing) {
      _anchorEnergy = sample().energy;
      _anchor = DateTime.now();
      _playing = playing;
    }
  }

  Future<void> _resolveBpm(Song song) async {
    final id = song.id;
    try {
      final cached = await AudioFeaturesCache().getCachedBpm(id);
      if (_trackId == id && cached != null && cached > 40 && cached < 250) {
        _bpm = cached;
        return;
      }
    } catch (_) {}
    try {
      final est = VibeSimilarity().analyzeTrack(song).bpm;
      if (_trackId == id && est > 40 && est < 250) _bpm = est;
    } catch (_) {}
  }

  /// energy 0..1 (размеры/альфы), beat 0..1 (острая атака для вспышек).
  ({double energy, double beat}) sample() {
    final now = DateTime.now();
    final dt = now.difference(_anchor).inMilliseconds / 1000.0;
    if (!_playing || _trackId == null) {
      // Спад к спокойствию за ~0.6с от энергии перехода.
      final k = (dt / 0.6).clamp(0.0, 1.0);
      final e = _anchorEnergy + (0.13 - _anchorEnergy) * k;
      return (energy: e, beat: 0.0);
    }
    // Разгон от энергии перехода за ~0.3с (без щелчка на старте трека).
    final ramp = (dt / 0.3).clamp(0.0, 1.0);
    // Лёгкий свинг чтобы не было метронома.
    final beats = dt * _bpm / 60.0 + 0.02 * math.sin(dt * 2 * math.pi * 0.23);
    final phase = beats - beats.floor();
    // Кик: резкая атака, быстрый спад + слабый офф-бит для грува.
    final kick = math.pow(1 - phase, 5).toDouble();
    final off = math.pow(1 - ((phase + 0.5) % 1.0), 8).toDouble() * 0.25;
    final beat = (kick + off).clamp(0.0, 1.0);
    final target = (0.42 + beat * 0.35).clamp(0.0, 1.0);
    final e = _anchorEnergy + (target - _anchorEnergy) * ramp;
    return (energy: e, beat: beat * ramp);
  }
}
