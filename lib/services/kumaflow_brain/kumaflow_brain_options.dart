/// Каталог опций волны с сервера (канон — сервер, а не зашитые списки).
/// GET /api/wave/options -> {activities[{code,label,hint}],
/// characteristics, languages, moods[{name,count}]}.
/// Плеер кеширует; без мозга — зашитый fallback (офлайн).
/// Сервер: ff5249d v0.2.8, ACTIVITY_PRESETS по кодам + русские алиасы.
class BrainOption {
  final String code;
  final String label;
  final String hint;
  const BrainOption({required this.code, this.label = '', this.hint = ''});

  factory BrainOption.fromJson(Map<String, dynamic> j) => BrainOption(
        code: (j['code'] ?? '').toString(),
        label: (j['label'] ?? '').toString(),
        hint: (j['hint'] ?? '').toString(),
      );

  Map<String, dynamic> toJson() => {
        'code': code,
        if (label.isNotEmpty) 'label': label,
        if (hint.isNotEmpty) 'hint': hint,
      };

  String get display => label.trim().isNotEmpty ? label.trim() : code;
}

class BrainMood {
  final String name;
  final int count;
  const BrainMood({required this.name, this.count = 0});

  factory BrainMood.fromJson(dynamic j) {
    if (j is String) return BrainMood(name: j);
    if (j is Map) {
      final m = Map<String, dynamic>.from(j);
      final c = m['count'];
      return BrainMood(
        name: (m['name'] ?? '').toString(),
        count: c is num ? c.toInt() : int.tryParse('$c') ?? 0,
      );
    }
    return const BrainMood(name: '');
  }
}

class BrainWaveOptions {
  final List<BrainOption> activities;
  final List<BrainOption> characteristics;
  final List<BrainOption> languages;
  final List<BrainMood> moods;
  final DateTime? fetchedAt;

  const BrainWaveOptions({
    this.activities = const [],
    this.characteristics = const [],
    this.languages = const [],
    this.moods = const [],
    this.fetchedAt,
  });

  bool get isEmpty =>
      activities.isEmpty && characteristics.isEmpty && languages.isEmpty;
  bool get isNotEmpty => !isEmpty;

  factory BrainWaveOptions.fromJson(Map<String, dynamic> j, {DateTime? fetchedAt}) {
    List<BrainOption> opts(dynamic v) {
      if (v is! List) return const [];
      final out = <BrainOption>[];
      for (final e in v) {
        if (e is Map) {
          final o = BrainOption.fromJson(Map<String, dynamic>.from(e));
          if (o.code.trim().isNotEmpty) out.add(o);
        } else if (e is String && e.trim().isNotEmpty) {
          out.add(BrainOption(code: e.trim()));
        }
      }
      return out;
    }

    List<BrainMood> ms(dynamic v) {
      if (v is! List) return const [];
      final out = <BrainMood>[];
      for (final e in v) {
        final m = BrainMood.fromJson(e);
        if (m.name.trim().isNotEmpty) out.add(m);
      }
      return out;
    }

    return BrainWaveOptions(
      activities: opts(j['activities']),
      characteristics: opts(j['characteristics']),
      languages: opts(j['languages']),
      moods: ms(j['moods']),
      fetchedAt: fetchedAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'activities': activities.map((e) => e.toJson()).toList(),
        'characteristics': characteristics.map((e) => e.toJson()).toList(),
        'languages': languages.map((e) => e.toJson()).toList(),
        'moods': moods.map((e) => {'name': e.name, 'count': e.count}).toList(),
      };

  String labelFor(List<BrainOption> list, String code) {
    final c = code.trim().toLowerCase();
    for (final o in list) {
      if (o.code.toLowerCase() == c) return o.display;
    }
    return code;
  }

  String activityLabel(String code) => labelFor(activities, code);
  String characteristicLabel(String code) => labelFor(characteristics, code);
  String languageLabel(String code) => labelFor(languages, code);

  /// Зашитый fallback 1в1 с сервером (ff5249d). Используется офлайн
  /// и до первой успешной загрузки каталога.
  static const BrainWaveOptions fallback = BrainWaveOptions(
    activities: [
      BrainOption(code: 'wakeup', label: 'Просыпаюсь', hint: 'бодро, но мягко'),
      BrainOption(code: 'commute', label: 'В дороге', hint: 'энергия и темп'),
      BrainOption(code: 'work', label: 'Работаю', hint: 'ровный фон'),
      BrainOption(code: 'study', label: 'Учёба / фокус', hint: 'не отвлекает'),
      BrainOption(code: 'workout', label: 'Тренировка', hint: 'темп и драйв'),
      BrainOption(code: 'walk', label: 'Прогулка', hint: 'светлое, в движении'),
      BrainOption(code: 'party', label: 'Вечеринка', hint: 'максимум движа'),
      BrainOption(code: 'rest', label: 'Отдых', hint: 'спокойное'),
      BrainOption(code: 'sleep', label: 'Засыпаю', hint: 'тихо и медленно'),
    ],
    characteristics: [
      BrainOption(code: 'favorite', label: 'Любимое', hint: 'проверенное'),
      BrainOption(code: 'unfamiliar', label: 'Незнакомое', hint: 'открытия'),
      BrainOption(code: 'popular', label: 'Популярное', hint: 'у всех на слуху'),
    ],
    languages: [
      BrainOption(code: 'ru', label: 'Русский'),
      BrainOption(code: 'foreign', label: 'Иностранный'),
      BrainOption(code: 'instrumental', label: 'Без слов'),
    ],
  );
}

/// Русские пилюли старых клиентов -> канон кодов (зеркало ACTIVITY_ALIASES).
const Map<String, String> kBrainActivityAliases = {
  'просыпаюсь': 'wakeup',
  'в дороге': 'commute',
  'работаю': 'work',
  'тренируюсь': 'workout',
  'тренировка': 'workout',
  'засыпаю': 'sleep',
};

/// Старые RU-пилюли характера/языка -> коды каталога.
const Map<String, String> kBrainCharacteristicAliases = {
  'любимое': 'favorite',
  'незнакомое': 'unfamiliar',
  'популярное': 'popular',
};

const Map<String, String> kBrainLanguageAliases = {
  'русский': 'ru',
  'иностранный': 'foreign',
  'без слов': 'instrumental',
};

/// Код занятия: алиасы старых пилюль -> канон. Неизвестное — как есть
/// (lower, без бонусов на сервере, очередь не пустеет). Пустое -> ''.
String normalizeBrainActivity(String? v) {
  final s = (v ?? '').trim().toLowerCase();
  if (s.isEmpty) return '';
  return kBrainActivityAliases[s] ?? s;
}

String normalizeBrainCharacteristic(String? v) {
  final s = (v ?? '').trim().toLowerCase();
  if (s.isEmpty) return '';
  return kBrainCharacteristicAliases[s] ?? s;
}

String normalizeBrainLanguage(String? v) {
  final s = (v ?? '').trim().toLowerCase();
  if (s.isEmpty) return '';
  return kBrainLanguageAliases[s] ?? s;
}

/// Канон муд-кодов сервера v0.3.3 (MOOD_PRESETS): EN-ключи.
/// Анализатор кладёт RU-лейблы — маппим любую форму в код.
/// Неизвестное — lower как есть (сервер без бонусов, очередь не пустеет).
const Map<String, String> kBrainMoodAliases = {
  'энергичный': 'energetic',
  'бодрый': 'energetic',
  'upbeat': 'energetic',
  'excited': 'energetic',
  'dance': 'energetic',
  'весёлый': 'happy',
  'веселый': 'happy',
  'радостный': 'happy',
  'счастливый': 'happy',
  'спокойный': 'calm',
  'грустный': 'sad',
  'печальный': 'sad',
  'тёмный': 'dark',
  'темный': 'dark',
  'мрачный': 'dark',
  'агрессивный': 'aggressive',
  'злой': 'aggressive',
  'angry': 'aggressive',
  'расслабленный': 'relaxed',
  'чилл': 'chill',
};

String normalizeBrainMood(String? v) {
  var s = (v ?? '').trim().toLowerCase().replaceAll('ё', 'е');
  if (s.isEmpty) return '';
  return kBrainMoodAliases[s] ?? s;
}

/// Санитайз mood для GET /api/tracks?mood= (зеркало сервера v0.2.9):
/// strip().lower(), вырезать `" % _ \`, max 64. Пустое -> '' (не слать).
String sanitizeBrainMoodQuery(String? v) {
  var s = (v ?? '').trim().toLowerCase();
  if (s.isEmpty) return '';
  s = s.replaceAll(RegExp(r'["%_\\]'), '');
  s = s.trim();
  if (s.isEmpty) return '';
  if (s.length > 64) s = s.substring(0, 64);
  return s.trim();
}
