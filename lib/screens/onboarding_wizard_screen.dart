import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../widgets/app_gradient_background.dart';
import '../services/theme_service.dart';
import '../theme/app_theme.dart';

/// Красивый начальный визард с иконкой приложения, всеми предварительными
/// настройками и кнопкой Пропустить. Сохраняет флаг wizard_done.
class OnboardingWizardScreen extends StatefulWidget {
  final VoidCallback onDone;
  const OnboardingWizardScreen({super.key, required this.onDone});

  static const String _kDoneKey = 'onboarding_wizard_done';

  static Future<bool> isDone() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_kDoneKey) ?? false;
  }

  static Future<void> markDone() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kDoneKey, true);
  }

  @override
  State<OnboardingWizardScreen> createState() => _OnboardingWizardScreenState();
}

class _OnboardingWizardScreenState extends State<OnboardingWizardScreen> {
  final _pageCtrl = PageController();
  int _page = 0;
  static const int _pages = 4;

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;

  void _next() {
    if (_page < _pages - 1) {
      _pageCtrl.nextPage(duration: const Duration(milliseconds: 350), curve: Curves.easeOutCubic);
    } else {
      _finish();
    }
  }

  void _skip() => _finish();

  Future<void> _finish() async {
    await OnboardingWizardScreen.markDone();
    widget.onDone();
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = context.select<ThemeService, Color>((t) => t.accentColor.color);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AppGradientBackground(
        child: SafeArea(
          child: Column(
            children: [
              // top bar with Skip
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Row(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: Image.asset('assets/app_icon.png', width: 32, height: 32, fit: BoxFit.cover, errorBuilder: (_, __, ___) => Icon(Icons.music_note_rounded, color: accent)),
                          ),
                          const SizedBox(width: 10),
                          Text('KumaFlow', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: _isDark ? Colors.white : Colors.black87)),
                        ],
                      ),
                    ),
                    TextButton(onPressed: _skip, child: Text('Пропустить', style: TextStyle(color: _isDark ? Colors.white70 : Colors.black54))),
                  ],
                ),
              ),
              // dots
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: List.generate(_pages, (i) {
                    final active = i == _page;
                    return Expanded(
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 250),
                        height: 4,
                        margin: EdgeInsets.only(right: i == _pages - 1 ? 0 : 6),
                        decoration: BoxDecoration(
                          color: active ? accent : (_isDark ? Colors.white24 : Colors.black12),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    );
                  }),
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: PageView(
                  controller: _pageCtrl,
                  onPageChanged: (i) => setState(() => _page = i),
                  children: [
                    _welcomeStep(accent),
                    _appearanceStep(),
                    _gradientStep(),
                    _finishStep(accent),
                  ],
                ),
              ),
              // bottom bar
              Container(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: _isDark ? AppTheme.darkDivider : AppTheme.lightDivider)),
                  color: (_isDark ? AppTheme.darkBackground : Colors.white).withValues(alpha: 0.92),
                ),
                child: Row(
                  children: [
                    if (_page > 0)
                      TextButton(onPressed: () => _pageCtrl.previousPage(duration: const Duration(milliseconds: 300), curve: Curves.easeOutCubic), child: const Text('Назад'))
                    else
                      const Spacer(),
                    const Spacer(),
                    FilledButton(
                      onPressed: _next,
                      style: FilledButton.styleFrom(backgroundColor: accent, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                      child: Text(_page == _pages - 1 ? 'Начать' : 'Далее'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _welcomeStep(Color accent) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
      child: Column(
        children: [
          const SizedBox(height: 8),
          Container(
            width: 110,
            height: 110,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(28),
              boxShadow: [BoxShadow(color: accent.withValues(alpha: 0.35), blurRadius: 24, offset: const Offset(0, 8)), BoxShadow(color: Colors.black.withValues(alpha: 0.25), blurRadius: 12, offset: const Offset(0, 4))],
            ),
            child: ClipRRect(borderRadius: BorderRadius.circular(28), child: Image.asset('assets/app_icon.png', fit: BoxFit.cover, errorBuilder: (_, __, ___) => Container(color: accent, child: const Icon(Icons.music_note_rounded, color: Colors.white, size: 48)))),
          ),
          const SizedBox(height: 24),
          Text('Добро пожаловать в KumaFlow', textAlign: TextAlign.center, style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: _isDark ? Colors.white : Colors.black87)),
          const SizedBox(height: 12),
          Text('Твоя музыка, твои правила. Настрой внешний вид, выбери жанры и начни слушать — всё за минуту.',
              textAlign: TextAlign.center, style: TextStyle(fontSize: 14, height: 1.45, color: _isDark ? AppTheme.darkSecondaryText : AppTheme.lightSecondaryText)),
          const SizedBox(height: 28),
          _featureRow(CupertinoIcons.paintbrush, const Color(0xFF5856D6), 'Персональный стиль', 'Тема, акцент, градиент — всё под тебя'),
          const SizedBox(height: 14),
          _featureRow(CupertinoIcons.music_note_2, const Color(0xFFFF3B30), 'Умные миксы', 'Выбери жанры и артистов — ML подстроит рекомендации'),
          const SizedBox(height: 14),
          _featureRow(CupertinoIcons.cloud, const Color(0xFF007AFF), 'Любой сервер', 'Subsonic, Jellyfin, локальные файлы — всё в одном месте'),
        ],
      ),
    );
  }

  Widget _featureRow(IconData icon, Color color, String title, String subtitle) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(width: 40, height: 40, decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(12)), child: Icon(icon, color: color, size: 20)),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: _isDark ? Colors.white : Colors.black87)),
            const SizedBox(height: 2),
            Text(subtitle, style: TextStyle(fontSize: 12.5, height: 1.3, color: _isDark ? AppTheme.darkSecondaryText : AppTheme.lightSecondaryText)),
          ]),
        ),
      ],
    );
  }

  Widget _appearanceStep() {
    final theme = Provider.of<ThemeService>(context);
    final isDark = _isDark;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Внешний вид', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: isDark ? Colors.white : Colors.black87)),
          const SizedBox(height: 6),
          Text('Выбери тему и акцент — они применятся везде, включая экран входа и холодный старт.',
              style: TextStyle(fontSize: 13, color: isDark ? AppTheme.darkSecondaryText : AppTheme.lightSecondaryText)),
          const SizedBox(height: 20),
          _sectionCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _editorLabel(CupertinoIcons.moon_stars_fill, const Color(0xFF5856D6), 'Тема'),
              const SizedBox(height: 10),
              _ThemeModeChips(value: theme.themeMode, onChanged: (m) => theme.setThemeMode(m)),
            ]),
          ),
          const SizedBox(height: 14),
          _sectionCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _editorLabel(Icons.palette_rounded, const Color(0xFFFF9500), 'Акцентный цвет'),
              const SizedBox(height: 10),
              _AccentPicker(selected: theme.accentColor, onChanged: (c) => theme.setAccentColor(c)),
              const SizedBox(height: 8),
              Text('Кнопка «Далее» в холодном старте и экран выбора сервера используют этот цвет.',
                  style: TextStyle(fontSize: 11, color: isDark ? AppTheme.darkSecondaryText : AppTheme.lightSecondaryText)),
            ]),
          ),
          const SizedBox(height: 14),
          _sectionCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Container(width: 28, height: 28, decoration: BoxDecoration(color: const Color(0xFF64D2FF).withValues(alpha: 0.15), borderRadius: BorderRadius.circular(6)), child: const Icon(CupertinoIcons.sparkles, color: Color(0xFF64D2FF), size: 16)),
                const SizedBox(width: 10),
                Expanded(child: Text('Эффекты', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: isDark ? Colors.white : Colors.black87))),
              ]),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(child: Text('AMOLED чёрный', style: TextStyle(fontSize: 13, color: isDark ? Colors.white : Colors.black87))),
                CupertinoSwitch(value: theme.amoled, activeTrackColor: theme.accentColor.color, onChanged: (v) => theme.setAmoled(v)),
              ]),
              const Divider(height: 20),
              Row(children: [
                Expanded(child: Text('Liquid Glass (бета)', style: TextStyle(fontSize: 13, color: isDark ? Colors.white : Colors.black87))),
                CupertinoSwitch(value: theme.liquidGlass, activeTrackColor: theme.accentColor.color, onChanged: (v) => theme.setLiquidGlass(v)),
              ]),
            ]),
          ),
        ],
      ),
    );
  }

  Widget _gradientStep() {
    final theme = Provider.of<ThemeService>(context);
    final isDark = _isDark;
    final intensity = theme.gradientIntensity;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Градиент', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: isDark ? Colors.white : Colors.black87)),
          const SizedBox(height: 6),
          Text('Интенсивность фона как на главной — от однотона до яркого градиента под акцент.',
              style: TextStyle(fontSize: 13, color: isDark ? AppTheme.darkSecondaryText : AppTheme.lightSecondaryText)),
          const SizedBox(height: 20),
          _sectionCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Container(width: 28, height: 28, decoration: BoxDecoration(color: const Color(0xFFAF52DE).withValues(alpha: 0.15), borderRadius: BorderRadius.circular(6)), child: const Icon(Icons.gradient_rounded, color: Color(0xFFAF52DE), size: 16)),
                const SizedBox(width: 10),
                Expanded(child: Text('Интенсивность градиента', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: isDark ? Colors.white : Colors.black87))),
                Text('${(intensity * 100).round()}%', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: theme.accentColor.color)),
              ]),
              const SizedBox(height: 10),
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  activeTrackColor: theme.accentColor.color,
                  inactiveTrackColor: isDark ? AppTheme.darkDivider : AppTheme.lightDivider,
                  thumbColor: theme.accentColor.color,
                  overlayColor: theme.accentColor.color.withValues(alpha: 0.12),
                  trackHeight: 3,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                ),
                child: Slider(value: intensity, min: 0, max: 1, divisions: 10, onChanged: (v) => theme.setGradientIntensity(v)),
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  height: 56,
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF121212) : Colors.white,
                    border: Border.all(color: isDark ? AppTheme.darkDivider : AppTheme.lightDivider),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              theme.accentColor.color.withValues(alpha: 0.50 * intensity),
                              theme.accentColor.color.withValues(alpha: 0.30 * intensity),
                              theme.accentColor.color.withValues(alpha: 0.05 * intensity),
                              Colors.transparent,
                            ],
                            stops: const [0.0, 0.3, 0.7, 1.0],
                          ),
                        ),
                      ),
                      Center(
                        child: Text(
                          intensity == 0 ? 'Без градиента' : intensity < 0.4 ? 'Едва заметно' : intensity < 0.8 ? 'Умеренно' : 'Ярко',
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: isDark ? Colors.white : Colors.black),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text('Этот же градиент будет на экране входа и холодном старте.', style: TextStyle(fontSize: 11, color: isDark ? AppTheme.darkSecondaryText : AppTheme.lightSecondaryText)),
            ]),
          ),
          const SizedBox(height: 14),
          _sectionCard(
            child: Row(
              children: [
                Container(width: 36, height: 36, decoration: BoxDecoration(gradient: LinearGradient(colors: [theme.accentColor.color, theme.accentColor.color.withValues(alpha: 0.6)]), borderRadius: BorderRadius.circular(8)), child: const Icon(Icons.auto_awesome_rounded, color: Colors.white, size: 18)),
                const SizedBox(width: 12),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Предпросмотр холодного старта', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: isDark ? Colors.white : Colors.black87)),
                  Text('Кнопка «Далее» будет этого цвета', style: TextStyle(fontSize: 11, color: isDark ? AppTheme.darkSecondaryText : AppTheme.lightSecondaryText)),
                ])),
                Container(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8), decoration: BoxDecoration(color: theme.accentColor.color, borderRadius: BorderRadius.circular(10)), child: const Text('Далее', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 12))),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _finishStep(Color accent) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 88,
            height: 88,
            decoration: BoxDecoration(shape: BoxShape.circle, color: accent.withValues(alpha: 0.15), border: Border.all(color: accent, width: 3)),
            child: Icon(CupertinoIcons.checkmark_alt, size: 42, color: accent),
          ),
          const SizedBox(height: 20),
          Text('Всё готово!', textAlign: TextAlign.center, style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: _isDark ? Colors.white : Colors.black87)),
          const SizedBox(height: 10),
          Text('Ты настроил внешний вид. Теперь выбери сервер и музыкальные вкусы — или пропусти и сделай это позже в настройках.',
              textAlign: TextAlign.center, style: TextStyle(fontSize: 14, height: 1.4, color: _isDark ? AppTheme.darkSecondaryText : AppTheme.lightSecondaryText)),
          const SizedBox(height: 28),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: (_isDark ? Colors.white.withValues(alpha: 0.06) : Colors.black.withValues(alpha: 0.04)), borderRadius: BorderRadius.circular(12), border: Border.all(color: _isDark ? Colors.white12 : Colors.black12)),
            child: Row(children: [
              Icon(CupertinoIcons.info_circle, size: 18, color: accent),
              const SizedBox(width: 10),
              Expanded(child: Text('Можно в любой момент изменить тему и градиент в Настройки → Отображение.', style: TextStyle(fontSize: 12, color: _isDark ? Colors.white70 : Colors.black54))),
            ]),
          ),
        ],
      ),
    );
  }

  Widget _sectionCard({required Widget child}) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      decoration: BoxDecoration(color: _isDark ? AppTheme.darkSurface : Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: _isDark ? Colors.white10 : Colors.black.withValues(alpha: 0.06))),
      child: child,
    );
  }

  Widget _editorLabel(IconData icon, Color color, String label) {
    return Row(children: [
      Container(width: 28, height: 28, decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(6)), child: Icon(icon, color: color, size: 16)),
      const SizedBox(width: 10),
      Text(label, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: _isDark ? Colors.white : Colors.black87)),
    ]);
  }
}

class _ThemeModeChips extends StatelessWidget {
  final ThemeMode value;
  final ValueChanged<ThemeMode> onChanged;
  const _ThemeModeChips({required this.value, required this.onChanged});
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = context.select<ThemeService, Color>((t) => t.accentColor.color);
    final options = [
      (mode: ThemeMode.system, label: 'Система', icon: CupertinoIcons.device_phone_portrait),
      (mode: ThemeMode.light, label: 'Светлая', icon: CupertinoIcons.sun_max_fill),
      (mode: ThemeMode.dark, label: 'Тёмная', icon: CupertinoIcons.moon_fill),
    ];
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: options.map((o) {
        final sel = value == o.mode;
        return GestureDetector(
          onTap: () => onChanged(o.mode),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: sel ? accent : (isDark ? Colors.white.withValues(alpha: 0.08) : Colors.black.withValues(alpha: 0.06)),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: sel ? accent : Colors.transparent),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(o.icon, size: 14, color: sel ? Colors.white : (isDark ? Colors.white70 : Colors.black87)),
              const SizedBox(width: 6),
              Text(o.label, style: TextStyle(fontSize: 13, fontWeight: sel ? FontWeight.w600 : FontWeight.w500, color: sel ? Colors.white : (isDark ? Colors.white70 : Colors.black87))),
            ]),
          ),
        );
      }).toList(),
    );
  }
}

class _AccentPicker extends StatelessWidget {
  final AccentColor selected;
  final ValueChanged<AccentColor> onChanged;
  const _AccentPicker({required this.selected, required this.onChanged});
  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: AccentColor.values.map((c) {
        final isSel = c == selected;
        return GestureDetector(
          onTap: () => onChanged(c),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: c.color,
              shape: BoxShape.circle,
              border: Border.all(color: isSel ? Colors.white : Colors.transparent, width: 3),
              boxShadow: isSel ? [BoxShadow(color: c.color.withValues(alpha: 0.45), blurRadius: 10, spreadRadius: 1)] : null,
            ),
            child: isSel ? const Icon(Icons.check_rounded, color: Colors.white, size: 18) : null,
          ),
        );
      }).toList(),
    );
  }
}
