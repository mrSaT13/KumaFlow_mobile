import 'package:flutter/material.dart';

/// Настроение капли «Моей волны» по жанру — порт ПК
/// (`kuma-wave-background.tsx`: waveMoodForGenre + WAVE_MOODS_META).
/// Порядок важен: pop rock — огонь, dream pop — туман.
enum WaveMood {
  none,
  fire,
  warp,
  sparkle,
  bounce,
  smoke,
  breath,
  dust,
  sun,
  fireflies,
  mist,
}

const Map<WaveMood, String> waveMoodLabels = {
  WaveMood.fire: 'Огонь',
  WaveMood.warp: 'Варп',
  WaveMood.sparkle: 'Блёстки',
  WaveMood.bounce: 'Кач',
  WaveMood.smoke: 'Дым',
  WaveMood.breath: 'Дыхание',
  WaveMood.dust: 'Пыль',
  WaveMood.sun: 'Солнце',
  WaveMood.fireflies: 'Светлячки',
  WaveMood.mist: 'Туман',
};

const Map<WaveMood, String> waveMoodHints = {
  WaveMood.fire: 'Рок, метал, альтернатива',
  WaveMood.warp: 'Электроника, техно, хаус',
  WaveMood.sparkle: 'Поп, K-Pop, J-Pop',
  WaveMood.bounce: 'Хип-хоп, рэп, R&B',
  WaveMood.smoke: 'Джаз, соул, блюз',
  WaveMood.breath: 'Классика, эмбиент',
  WaveMood.dust: 'Ло-фай, чилл, лаунж',
  WaveMood.sun: 'Регги, латина, ска',
  WaveMood.fireflies: 'Кантри, фолк, акустика',
  WaveMood.mist: 'Инди, дрим-поп, пост-рок',
};

const _fire = [
  'рок', 'rock', 'metal', 'панк', 'punk', 'grunge', 'гранж',
  'alternative', 'альтернатив', 'hardcore', 'хардкор', 'industrial',
  'индастриал', 'emo', 'эмо', 'post-hardcore',
];
const _warp = [
  'электрон', 'electro', 'edm', 'techno', 'техно', 'house', 'хаус',
  'trance', 'транс', 'dubstep', 'дабстеп', 'drum', 'dnb', 'днб',
  'synth', 'синт', 'vapor', 'вейпор', 'dance', 'дэнс', 'disco',
  'диско', 'hyperpop', 'phonk', 'фонк', 'bass', 'басс',
];
const _mist = [
  'инди', 'indie', 'dream', 'дрим', 'shoegaze', 'шугейз',
  'post-rock', 'пост-рок', 'slowcore', 'слоукор',
];
const _sparkle = ['k-pop', 'j-pop', 'поп', 'europop', 'европоп', 'dance-pop'];
const _bounce = [
  'хип-хоп', 'hip-hop', 'hip hop', 'rap', 'рэп', 'trap', 'трэп',
  'r&b', 'rnb', 'drill', 'дрилл', 'grime', 'грайм',
];
const _smoke = [
  'джаз', 'jazz', 'soul', 'соул', 'funk', 'фанк', 'blues', 'блюз',
  'neo-soul', 'acid jazz',
];
const _sun = [
  'регги', 'reggae', 'латина', 'latin', 'salsa', 'сальса', 'ska', 'ска',
  'bachata', 'бачата', 'reggaeton', 'реггетон', 'afro', 'афро',
  'calypso', 'калипсо',
];
const _breath = [
  'классик', 'classical', 'opera', 'опера', 'instrumental',
  'инструментал', 'ambient', 'амбиент', 'neoclass', 'неокласс',
];
const _dust = [
  'lo-fi', 'lofi', 'лофай', 'chill', 'чилл', 'lounge', 'лаунж',
  'downtempo', 'даунтемпо', 'trip-hop', 'трип-хоп',
];
const _fireflies = [
  'кантри', 'country', 'фолк', 'folk', 'bluegrass', 'блюграсс',
  'celtic', 'кельт', 'acoustic', 'акустик', 'singer-songwriter', 'бард',
];

WaveMood waveMoodForGenre(String? genre) {
  if (genre == null || genre.isEmpty) return WaveMood.none;
  final g = genre.toLowerCase();
  bool has(List<String> ts) => ts.any(g.contains);
  if (has(_fire)) return WaveMood.fire;
  if (has(_warp)) return WaveMood.warp;
  if (has(_mist)) return WaveMood.mist;
  if (has(_sparkle)) return WaveMood.sparkle;
  if (has(_bounce)) return WaveMood.bounce;
  if (has(_smoke)) return WaveMood.smoke;
  if (has(_sun)) return WaveMood.sun;
  if (has(_breath)) return WaveMood.breath;
  if (has(_dust)) return WaveMood.dust;
  if (has(_fireflies)) return WaveMood.fireflies;
  return WaveMood.none;
}

/// Жанровый цвет капли — порт ПК (`getGenreColor`): тот же словарь, что
/// раньше жил в `kumaflow_my_wave_hero.dart` (см. genre_carousel.dart:86).
/// Неизвестный жанр — детерминированный цвет по хешу (стабилен).
Color waveGenreColor(String genreName) {
  const map = {
    'rock': Color(0xFF3779BC),
    'pop': Color(0xFFFF6665),
    'metal': Color(0xFF9D65A9),
    'alternative': Color(0xFFC44F69),
    'indie': Color(0xFF3779BC),
    'electronic': Color(0xFF6C65A9),
    'dance': Color(0xFFE4BA0F),
    'hip-hop': Color(0xFF59CD9C),
    'hip hop': Color(0xFF59CD9C),
    'rap': Color(0xFF59CD9C),
    'jazz': Color(0xFFE3208F),
    'blues': Color(0xFFA5C94B),
    'reggae': Color(0xFFFF9344),
    'ska': Color(0xFFC44F69),
    'punk': Color(0xFFC44F69),
    'folk': Color(0xFFFD9060),
    'country': Color(0xFFFF9344),
    'classical': Color(0xFF6FC3E0),
    'r&b': Color(0xFFA5C94B),
    'soul': Color(0xFFA5C94B),
    'soundtrack': Color(0xFFFF6665),
    'relax': Color(0xFF6FC3E0),
    'ambient': Color(0xFF6FC3E0),
  };
  final lower = genreName.toLowerCase();
  if (map.containsKey(lower)) return map[lower]!;
  for (final entry in map.entries) {
    if (lower.contains(entry.key) || entry.key.contains(lower)) {
      return entry.value;
    }
  }
  final colors = map.values.toList();
  return colors[genreName.hashCode.abs() % colors.length];
}

/// Тройка капли из акцентного цвета обложки — порт buildWaveTrio:
/// гармония (0°, +35°, −35°), серый/белый акцент → null (будет дефолт).
/// Возвращает null при мусоре на входе.
List<Color>? buildWaveTrio(Color? base, bool dark) {
  if (base == null) return null;
  final hsl = HSLColor.fromColor(base);
  if (hsl.saturation < 0.08) return null; // серый — не красим
  final sat = hsl.saturation.clamp(0.62, 1.0);
  final light = dark
      ? 0.60
      : hsl.lightness.clamp(0.52, 0.62);
  Color shift(double dh, double ds, double dl) => hsl
      .withHue((hsl.hue + dh) % 360)
      .withSaturation((sat + ds).clamp(0.0, 1.0))
      .withLightness((light + dl).clamp(0.0, 1.0))
      .toColor();
  return [
    shift(0, 0, 0),
    shift(35, 0, 0),
    shift(-35, -0.05, 0.06),
  ];
}

/// Дефолтная тройка ПК.
const List<Color> defaultWaveTrio = [
  Color(0xFF00E5FF),
  Color(0xFF2979FF),
  Color(0xFF7C4DFF),
];
