import 'package:flutter_test/flutter_test.dart';
import 'package:kumaflow/services/kumaflow_brain/kumaflow_brain_options.dart';

void main() {
  group('BrainWaveOptions fallback', () {
    test('covers 9 activities like server ff5249d', () {
      const o = BrainWaveOptions.fallback;
      expect(o.activities.map((e) => e.code), containsAll([
        'wakeup', 'commute', 'work', 'study', 'workout',
        'walk', 'party', 'rest', 'sleep',
      ]));
      expect(o.characteristics.map((e) => e.code),
          containsAll(['favorite', 'unfamiliar', 'popular']));
      expect(o.languages.map((e) => e.code),
          containsAll(['ru', 'foreign', 'instrumental']));
    });

    test('labels resolve, unknown code passes through', () {
      const o = BrainWaveOptions.fallback;
      expect(o.activityLabel('wakeup'), 'Просыпаюсь');
      expect(o.characteristicLabel('favorite'), 'Любимое');
      expect(o.languageLabel('ru'), 'Русский');
      expect(o.activityLabel('медитация'), 'медитация');
    });
  });

  group('normalize', () {
    test('russian pills map to codes', () {
      expect(normalizeBrainActivity('Просыпаюсь'), 'wakeup');
      expect(normalizeBrainActivity('в дороге'), 'commute');
      expect(normalizeBrainActivity('Работаю'), 'work');
      expect(normalizeBrainActivity('тренируюсь'), 'workout');
      expect(normalizeBrainActivity('засыпаю'), 'sleep');
      expect(normalizeBrainCharacteristic('Любимое'), 'favorite');
      expect(normalizeBrainCharacteristic('Незнакомое'), 'unfamiliar');
      expect(normalizeBrainLanguage('Без слов'), 'instrumental');
    });

    test('codes pass through, empty stays empty', () {
      expect(normalizeBrainActivity('workout'), 'workout');
      expect(normalizeBrainActivity(''), '');
      expect(normalizeBrainActivity(null), '');
      // Неизвестное — как есть (сервер без бонусов, очередь не пустеет).
      expect(normalizeBrainActivity('медитация'), 'медитация');
    });
  });

  group('BrainWaveOptions.fromJson', () {
    test('parses server shape', () {
      final o = BrainWaveOptions.fromJson({
        'ok': true,
        'activities': [
          {'code': 'wakeup', 'label': 'Просыпаюсь', 'hint': 'бодро'},
        ],
        'characteristics': [
          {'code': 'favorite', 'label': 'Любимое'}
        ],
        'languages': ['ru'],
        'moods': [
          {'name': 'chill', 'count': 12},
          'focus',
        ],
      });
      expect(o.activities.single.code, 'wakeup');
      expect(o.activities.single.hint, 'бодро');
      expect(o.characteristics.single.label, 'Любимое');
      expect(o.languages.single.code, 'ru');
      expect(o.moods.map((e) => e.name), containsAll(['chill', 'focus']));
      expect(o.moods.first.count, 12);
    });

    test('empty json gives empty options', () {
      const o = BrainWaveOptions();
      expect(o.isEmpty, true);
      expect(BrainWaveOptions.fromJson(const {}).isEmpty, true);
    });
  });
}
