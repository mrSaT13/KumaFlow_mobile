# KumaFlow 3.7.49 — релиз заметки

Дата: 16 октября 2026
Версия: `3.7.49+2079` (`pubspec.yaml:4`)

## Что нового
- Библиотека → Избранное без дубля: сверху плитки-папки (Плейлисты → отдельный экран), снизу только недавние альбомы.
- Волна: спиннер генерации и честная пауза «Продолжить», как на ПК.
- V2 hero: цвет от играющего трека → жанр → дефолт, плавное перетекание настроений, счётчик треков с тумблером.
- Крестики на пилюлях больше не промахиваются в шторку, коллаб прячется при выключенных аккаунтах.
- Пульт (сторона ПК, нужен пересбор exe): честный лайк и громкость.

## Проверено
- `analyze` по тронутым файлам без ошибок.

## Известно
- Патч пульта заработает только после пересборки exe из `C:\kumaflow-pc-new`.

## Сборка
- Успех: **94.9 MB** (16.10.2026, SHA256 `F9718A89…46077`).
- APK: `C:\kfmobile\build\app\outputs\flutter-apk\KumaFlow_V3.7.49.apk`.

---

# KumaFlow 3.7.46 — релиз заметки

Дата: 15 октября 2026
Версия: `3.7.46+2076` (`pubspec.yaml:4`)

## Что нового
- Моя волна V2 (Настройки → Оформление → Главная): карточка как на ПК — светлая/тёмная, живое пятно-блоб в цветах обложки, жанровые эффекты (Огонь, Варп, Дым…) с тумблерами, пульс в темпе трека.
- Тап «Скачанное» строит умную ML-волну из офлайна (лайки + настроения), в Настройки → ML есть возврат на простой шаффл и кнопка подтяжки настроений с мозга.
- Пульт помнит PIN в кейчейне (поле PIN в редактировании), неверный PIN больше не крутит реконнекты.
- Двойной сплэш и двойной движок убиты: один запуск, один движок, сплэш без налезающего текста.
- Сервер лёг — приложение больше не штормит: circuit breaker на 5xx, короткие ретраи коннекта, обложки с негативным кэшем и даунсемплом.
- Синк большой библиотеки не фризит: bulk-импорт ML и чанкованные транзакции БД.

## Проверено
- Один процесс/движок, пинг сразу `Ping OK → authenticated` (лог).
- `analyze` без ошибок.

## Известно
- Сервер за Keenetic-прокси периодически отдаёт 502/403 — это бэкенд (Navidrome), чинится на серверной стороне; приложение деградирует gracefully и продолжает само.
- Фаза кика волны — по BPM трека, не по реальному FFT (настоящий бит в такт требует разрешения микрофона).

## Сборка
- Успех: **94.5 MB** (15.10.2026, SHA256 `C61F36F3…4D4FB`).
- APK: `C:\kfmobile\build\app\outputs\flutter-apk\KumaFlow_V3.7.46.apk`.

---

# KumaFlow 3.7.36 — релиз заметки

Дата: 14 октября 2026
Версия: `3.7.36+2066` (`pubspec.yaml:4`)

## Что нового
- Пульт больше не закрывается сам после подключения: плеер остаётся открытым, соединение не рвётся.
- Громкость с телефона регулируется мягко — без дёрганий звука на ПК.
- ПК в сети находится сам: поиск переведён на системный NSD, ручной ввод IP нужен реже.

## Проверено
- `analyze` без ошибок.

## Известно
- Очередь на ПК пока только для просмотра — тап по треку не запускает его (в протоколе ПК 1.11.5 нет такой команды).
- Пульт не соединяется через гостевой Wi-Fi с изоляцией клиентов (телефон физически не видит ПК — чинится настройкой роутера).

## Сборка
- Успех с 1-й попытки (~551с): **94.1 MB** (14.10.2026, SHA256 `47FBA8CD…604F32`).
- APK: `C:\kfmobile\build\app\outputs\flutter-apk\KumaFlow_V3.7.36.apk`.

---

# KumaFlow 3.7.32 — релиз заметки

Дата: 12 октября 2026
Версия: `3.7.32+2062` (`pubspec.yaml:4`)

## Что нового
- Подключение к серверу через KeenDNS стало живучим: плеер сам дожимает сервер при капризах сети (тихие повторы), введённый адрес больше не подменяется и не «сбрасывается».
- Пульт ПК: страница управления десктопом (транспорт, громкость, очередь) — поиск ПК в сети, ручной IP, QR-код, сохранённые; диалог подключения показывает причину (фаервол/IP/PIN) и кнопки Повторить/Закрыть; при неверном PIN спрашивает заново.
- Мои загрузки: экран со счётчиками, путём кеша и очисткой; экспорт трека в общую `Музыка/KumaFlow`.
- Возврат сети без рестарта: поиск/артисты сами оживают, кнопка «Проверить соединение» в баннере.
- Микс и волна не виснут (таймаут 75с), «Эквалайзер» в `...`-меню трека, «Поделиться» — с обложкой.
- Волна точнее: радио по сиду без поиска, настроения из твоей библиотеки.

## Проверено
- Два телефона: вход и библиотека грузятся (лог).
- `analyze` без ошибок.

## Известно
- Пульт не соединяется через гостевой Wi-Fi с изоляцией клиентов (телефон физически не видит ПК — проверено замерами, чинится настройкой роутера).

## Сборка
- Успех с 1-й попытки (~367с): **93.9 MB** (12.10.2026 ~17:24, SHA256 `F4A657D7…170E41`).
- APK: `C:\kfmobile\build\app\outputs\flutter-apk\KumaFlow_V3.7.32.apk`.

---

# KumaFlow 3.5.4 — релиз заметки

Дата: 28 сентября 2026
Версия: `3.5.4+25` (`pubspec.yaml:4`)

## Что нового
- Сплэш: контент реально по центру (был прижат влево).
- Моя волна: при активном мосте, но молчащем сервере — снекбар «локально (KumaFlow Brain не ответил)».

## Сборка
- Успех с 1-й попытки (414с): **77.1 MB** (28.09.2026, SHA256 `14445535…0481D7B6`).
- APK: `D:\newKumaflow\KumaFlow\KumaFlow-3.5.4+25.apk`.

---

# KumaFlow 3.5.3 — релиз заметки

Дата: 28 сентября 2026
Версия: `3.5.3+24` (`pubspec.yaml:4`)

## Что нового
- Сплэш 1-в-1 с десктопом (кольца emerald/blue, reverse-кольцо 12с, pulse иконки, трёхцветный прогресс; фон динамический от accent).
- KumaFlow Brain: нейтральный hint URL, логин/пароль подхватываются с сервера, фильтры волны только в «Моя волна → Настроить» + настроения с сервера.
- AutoDJ KF-Brain: чанк 5, дешёвый fallback без локального ML-скоринга.

## Сборка
- Успех с 1-й попытки (274с): **77.1 MB** (28.09.2026 ~11:42, SHA256 `191BF582…95832B`).
- APK: `D:\newKumaflow\KumaFlow\KumaFlow-3.5.3+24.apk` (собран на копии `C:\kfmobile`, канон — D).
- KGP warning (battery_plus, dynamic_color и др.) — как раньше, не блокирует.

---

# KumaFlow 3.5.2 — релиз заметки

Дата: 23 сентября 2026
Версия: `3.5.2+23` (`pubspec.yaml:4`)

## Что нового
- Auto DJ → новый режим **KF-Brain**: серверная волна из мозга с автоподмесом в хвост очереди (refill при остатке ≤ порога), fallback на локальный скоринг.
- Зеркало очереди на веб (`/api/wave/publish` → `/api/wave/live`, заработает после обновления деплоя мозга).

## Сборка
- Успех с 3-й попытки (607с): **76.8 MB** (23.09.2026 ~15:25, SHA256 `7ED34C45…45EDC13`).
- ⚠️ На D 0 байт — APK **лежит только на C**: `C:\Users\iRuStrato27_1235U_W\AppData\Local\Temp\opencode\kuma_build\build\app\outputs\flutter-apk\app-release.apk` (C-копия НЕ удалена).
- Старые APK (10:21, 13:22) переложены в `C:\...\Temp\opencode\old_apk\` как бэкап.
- Первые 2 попытки: копия на D не влезла (76.8 + 76.8 > свободных); `D:\gradle-cache` (3 ГБ) не трогали.

---

# KumaFlow 3.5.1 — релиз заметки

Дата: 23 сентября 2026
Версия: `3.5.1+22` (`pubspec.yaml:4`)

## Что нового
- Мозг: опциональный API-токен (`BRAIN_API_TOKEN`) — поле в настройках, Bearer-заголовок + token в обложках.
- Варнинг про docker-hostname (нужен LAN-IP).
- Волна: точный маппинг по `external_id` из ответов сервера вместо поиска по названию.

## Сборка
- Успех с 1-й попытки (608с): `build/app/outputs/flutter-apk/app-release.apk` **76.8 MB** (23.09.2026 13:22, SHA256 `ADDA21BF…F9159F77`), скопирован в D и сверен по хешу.
- Перед сборкой снесён stale-кэш `~/.gradle/caches/8.11.1` (6.7 ГБ, проект на Gradle 8.14) + убиты демоны; теплоту (`8.14`, `modules-2`) не трогал. C-копия удалена (C: 6.28 ГБ свободно).

---

# KumaFlow 3.5.0 — релиз заметки

Дата: 23 сентября 2026
Версия: `3.5.0+21` (`pubspec.yaml:4`)

## Что нового — мозг (mlbrainKF), тестовая интеграция
- Тумблер в Настройки → ML → Мозг (по умолчанию ВЫКЛ — всё как раньше, локально).
- ВКЛ + URL (`http://100.72.1.90:3030/`) + Подключить (by-credentials → user_id) → фоновая отсылка play/skip/complete/rate/history, кнопка «Синхронить» (sync-from-mobile страницами).
- Экран мозга: Волна (подмес в очередь только кнопками), Открытия недели (CLAP/fallback + «почему трек»), Vault opt-in, Динамика (drift/activity/wrapped/profile), Уведомления, Обложки (prefetch по 8).
- Безопасность: best-effort + backoff, очередь живёт в клиенте, пароль только в LAN.
- Известно: сервер не отдаёт `external_id` в wave/tracks — резолв по title+artist, неточное; ненайденное показывается отдельно.

## Сборка
- `flutter build apk --release` на копии в `C:\...\Temp\opencode\kuma_build` (D забит: 0.35 ГБ; проект 70 МБ копируется robocopy без build/.dart_tool/бекапов).
- Падало `mergeReleaseJavaResource: Недостаточно места` — снесён `~/.gradle/caches/build-cache-1` (870 МБ) + логи демонов, убит stale-демон 8.11.1 (3.1 ГБ RAM). Теплоту (`caches/8.14`, `modules-2`, dists) не трогал.
- Успех со 2-й попытки (инкрементально, 307с): `build/app/outputs/flutter-apk/app-release.apk` **76.8 MB** (23.09.2026 10:21, SHA256 `F563A68B…CEE784B`), скопирован в D и сверен по хешу. C-копия удалена (C: 2.29 ГБ свободно).
- Предупреждение KGP (battery_plus, dynamic_color и др.) — как раньше, не блокирует.

---

# KumaFlow 3.4.7 — релиз заметки

Дата: 18 сентября 2026
Версия: `3.4.7+20` (`pubspec.yaml:4`)

## Статус
- Промежуточный релиз, docs-sync. Детальная история `3.4.0–3.4.6` утеряна (нет git, `CHANGELOG.md` останавливался на `3.3.0+3`).
- Ниже сохранены старые заметки `3.3.0` / `3.2.0` без изменений.
- Что точно менялось в сентябре (по mtime, неточно): плеер (`player_provider.dart`), библиотека, `subsonic_service`, `auto_dj`, `cast/upnp/local_file_server`, `recommendation/ml`, `ai_service`, `yandex/jellyfin`, настройки.
- `build_346.log` (17.09): релизная сборка падала на `assembleRelease` — перед релизом пересобрать и приложить APK/размер.

---

# KumaFlow 3.3.0 — релиз заметки

Дата: 25 августа 2026
Версия: `3.3.0+3`

## Что нового — градиент и приветствие

### ✨ Приветствие «Добрый день» — отдельная секция
- **Проблема** (`lib/screens/home_screen.dart:192`): `SliverAppBar` был `backgroundColor: transparent` + `floating:true`. Текст `Добрый день, Antidote` сливался с обложками/списками при скролле (см. скрины).
- **Фикс** `home_screen.dart:193-287`:
  - `pinned:true, floating:false, expandedHeight/collapsedHeight 64/56`
  - `backgroundColor: 0xFF121212@0.72 (dark) / white@0.82 (light)`, `scrolledUnderElevation 8`, `shadow 0.35`
  - `flexibleSpace: ClipRect > BackdropFilter(blur 16) > Container(gradient accent 0.40→0.16 + hairline 0.08) > FlexibleSpaceBar`
  - Текст: `w800, letterSpacing -0.3, 2 shadows`, `ellipsis`

### 🎨 Градиент как на главной — на всех страницах
- **Новый виджет** `lib/widgets/app_gradient_background.dart:8` — `AppGradientBackground`:
  - `Stack[ ColoredBox(base #000000/#F2F2F7) + LinearGradient(top→bottom, accent 0.50→0.30→0.15→0.05→transparent, stops 0.0/0.15/0.35/0.6/1.0) + child]`
  - `AppGradientAppBarBackground` для AppBar с тем же градиентом `0.40→0.16`
  - Оба слушают `ThemeService.accentColor` и `gradientIntensity`
- **Глобальный фон** `lib/screens/main_screen.dart:1,429,503`:
  - Desktop и mobile `Scaffold` обёрнуты в `AppGradientBackground(background: transparent)`
  - Все табы `Home/Library/Search/Mixes/Книги/Settings` просвечивают один фон
- **Табы с блюром** (как на главной):
  - `library_screen.dart:57`, `search_screen.dart:174`, `mixes_screen.dart:33`, `audiobookshelf_screen.dart:149`, `settings_screen.dart:45` — `SliverAppBar/AppBar` `0.72/0.82 + blur 16 + accent gradient`
- **Пуш-экраны** (~30 файлов: `album_screen.dart:131`, `playlist_screen.dart:458`, `artist_screen.dart:488`, `all_songs_screen.dart:233`, `genres_screen.dart:1` и др.):
  - `Scaffold(backgroundColor: Colors.transparent, extendBodyBehindAppBar:true)` — показывает глобальный градиент
  - `AppBar/SliverAppBar` `background 0.72/0.82 + scrolledUnderElevation 8` — не перекрывает градиент

### 🎚️ Регулировка интенсивности — Настройки / Дисплей
- **Сервис** `lib/services/theme_service.dart:77,88,101,129`:
  - `static _keyGradientIntensity = 'app_gradient_intensity'`, `double _gradientIntensity = 1.0`
  - `getter gradientIntensity`, `setGradientIntensity(v)` с `clamp 0..1` + `SharedPreferences.setDouble` + `notifyListeners()`
  - Загрузка в `initialize()` из `prefs.getDouble(...) ?? 1.0`
- **Виджет** `app_gradient_background.dart:21,62` — `double a(v) => v*intensity`, `if (intensity>0.01)` скрывает градиент при 0%, `border alpha 0.08*intensity`
- **Экраны** `home/library/search/mixes/audiobookshelf/settings` — `final intensity = context.select<ThemeService,double>((t)=>t.gradientIntensity)` и `accentColor.withValues(alpha: 0.5*intensity)` etc.
- **UI** `lib/screens/settings_display_tab.dart:40,105,331,410`:
  - Поле `_gradientIntensity`, загрузка из `themeService.gradientIntensity`
  - Секция `ВНЕШНИЙ ВИД` → `_buildEditorRow(icon: Icons.gradient_rounded, color:#AF52DE, label: 'Интенсивность градиента', trailing: '0%..100%', child: Column[ Text 'Фон как на главной — 0% однотон, 100% ярко', Slider 0..1 divisions10, превью ClipRRect 28px с градиентом 0.50/0.30/0.05*intensity, подписи 0%/100% ])`
  - `onChanged: (v){ setState(()=>_gradientIntensity=v); themeService.setGradientIntensity(v); }`

### 📦 Сборка
- `flutter build apk --release` — `build/app/outputs/flutter-apk/app-release.apk` **71.2 MB** (74 685 643 байт, 25.08.2026 15:33)
- `flutter analyze lib/screens` — 0 ошибок (8 предсуществующих в `lib/services: lyrics_service 157, scrobble_service 311, activity_heatmap 140` — не блокируют сборку)
- KGP warning для `battery_plus`, `dynamic_color` и др. — как в 3.2.0

## Что проверить
1. Главная — «Добрый день, Antidote» не сливается при скролле, AppBar матовый с градиентом.
2. Переключение табов и пуш в Альбом/Плейлист/Артиста — фон одинаковый, AppBar полупрозрачный.
3. Настройки → Дисплей → Интенсивность градиента — слайдер 0–100%, превью меняется, после перезапуска значение сохраняется.
4. Смена акцента → градиент меняет цвет на всех экранах.
5. 0% — везде однотон `#000000`/`#F2F2F7`, 100% — как на скринах.

---

# KumaFlow 3.2.0 — релиз заметки

Дата: 24 августа 2026
Версия: `3.2.0+2`

## Что сделано сегодня

### 🎙️ Audiobookshelf — полноценная интеграция
- **Модели данных**: добавлены поля `absStart`/`absEnd` в `Song` (`lib/models/song.dart`) для обрезки аудио по главам.
- **Сервис** `lib/services/audiobookshelf_service.dart`:
  - `extractChapters()` с резервной логикой `media.chapters` → `media.audioFiles[].chapters` (как в Lissen).
  - `getCoverUrl(?width=&token=)` для обложек с авторизацией.
  - `fetchBookDetail(?expanded=1&include=progress)` + парсинг `userMediaProgress`.
  - `syncProgress` с `POST /api/session/{id}/sync` и фолбэком `PATCH /api/me/progress`.
  - `getStreamUrl(?token=, fileId:)` для прямой стримилки `/api/items/{id}/file/{ino}?token=`.
- **Экран книги** `audiobook_detail_screen.dart`:
  - Обложка 200×280 с кешем.
  - Прогресс-бар с `timeRemaining`.
  - Метаданные: авторы, чтецы, серия, издатель.
  - Список глав с подсветкой `isCurrent` + тап → `_playFrom(startTime)`.
  - Таймер сна 30/60 мин через `PlayerProvider.setSleepTimer`.
  - Автосинк прогресса каждые 15 секунд с ретраями.
- **Библиотека** `audiobookshelf_screen.dart`: поиск + фильтры «Все / В процессе / Завершённые», прогресс из `userMediaProgress.progress`.
- **Настройки** в разделе «Сервер»: переключатель + поля URL/Token + кнопки «Сохранить» / «Книги» (`_AudiobookshelfSettingsTile`).
- **Точка входа** в библиотеке: тайл «Книги • Audiobookshelf» при настроенном сервере.
- **ClippingAudioSource** в `player_provider.dart:2648` — обрезка одной длинной аудио-дорожки по `absStart`/`absEnd` для глав.
- **Продолжить слушать** на главном экране: `ValueListenableBuilder` + `FutureBuilder.fetchContinueListening()`.

### 🤖 ИИ-провайдер для генерации названий миксов
- `lib/services/ai_service.dart`:
  - Провайдеры: `Ollama`, `OpenAI`, `Anthropic`, `Google`, `Custom`.
  - `generateMixName(songs, hint)` с temperature 0.8, top-10 треков и жанрами в промпте.
  - `_callAi` под каждый провайдер (правильные эндпоинты и форматы).
- `lib/screens/settings_ai_tab.dart`:
  - Выбор провайдера, выпадающий список с моделями для каждого + «Custom».
  - Поля Token (скрыт) и Base URL.
  - Кнопки «Сохранить» и «Тест подключения».
- **Карусель «AI Mix»** на главной под «Моя волна»:
  - 120×120 плитки.
  - ИИ-переименование микса в зависимости от времени суток (утро/день/вечер).
  - Защита от повторной генерации (`_lastRandomKey`).

### 🏠 Главная страница — настройка видимости
- `PlayerUiSettingsService` — нотификаторы и геттеры/сеттеры:
  - `homeShowMyWave` (Моя волна).
  - `homeShowMixes` (Миксы).
  - `homeShowRecent` (Недавние).
  - `homeShowPersonalized` (Персональные).
  - `homeShowYandex` (Яндекс).
  - `homeShowGenre` (Жанры).
  - `homeShowAiMix` (AI Mix).
- В `SettingsDisplayTab` переименована секция «ГЛАВНАЯ СТРАНИЦА» → «HOME PAGE» (фикс кодировки кириллицы).
- В `home_screen.dart` секции обёрнуты в `if (PlayerUiSettingsService().getHomeShowX())`.

### 🔧 Исправления ошибок
- **Виджет Android падение** «RemoteViews 9720000 > 6566400»:
  - Фон `#FF181818` → `#99181818` (60% прозрачность).
  - Контролы `gravity center`.
  - Даунскейл обложки до 512 с `try/catch IllegalArgumentException`.
  - `recycle()` для освобождения памяти.
- **WidgetInteger Long** в `MainActivity.kt:45`: `call.argument<Number>("positionMs")?.toLong()` (Dart отправлял Integer, падало на `B0.A.t`).
- **Артисты** в `multi_artist_widget.dart`: сплит `ArtistRef.name` по `[/,;,, ft, &, ×]` — «Исполнитель1/2» теперь две кликабельные плашки.
- **Миграция БД v2→v3**: добавлена колонка `isLocal` в таблицах `songs/albums/artists` + `UPDATE` для существующих записей.
- **Сохранение заблокированных артистов**: `ml_service.dart` при `bannedArtistNames.isEmpty && bannedArtists.isNotEmpty` копирует `id → name` и шедулит сохранение + эмит события; синхронизация в `main.dart` через `Future.microtask`.

### 🏗️ Инфраструктура
- Патч Flutter 3.44.4: `D:\flutter\packages\flutter_tools\lib\src\project.dart` — обе функции `getEmbeddingVersion()` и `computeEmbeddingVersion()` принудительно возвращают `AndroidEmbeddingVersion.v2`. Требовало удаления `flutter_tools.snapshot` и `flutter_tools.stamp` в `D:\flutter\bin\cache\`.
- В `pubspec.yaml` отключены пакеты: `flutter_chrome_cast`, `countly_flutter`, `smtc_windows`, `dart_discord_rpc` (конфликт v1 embedding).
- Сборка APK обходит D: (0 байт) через копию проекта на `C:\Users\iRuStrato27_1235U_W\AppData\Local\Temp\opencode\musly\` с `GRADLE_USER_HOME` на C: (Robocopy `/E /XD build .dart_tool .gradle .git /XF "*.apk"`).
- Сборка: 70.7 МБ, 124 сек на C:.

### 📦 Сборка
- APK: `D:\newKumaflow\KumaFlow\Musly-master\build\app\outputs\flutter-apk\app-release.apk` (74 150 493 байт, 24.08.2026 16:50).
- Бэкап исходников: `_backup_20260824_093422_pre_big6` (14 файлов).

## Что проверить после установки
1. **Настройки → Сервер → Audiobookshelf**: URL/токен сохраняются, кнопка «Книги» открывает библиотеку.
2. **Настройки → ИИ → Модель**: выпадающий список с моделями (Ollama/OpenAI/Anthropic/Google/Custom).
3. **Книга с 12 главами на 25 мин**: открыть главу 12 → играет с правильного места, обложка в «Сейчас играет», название `Глава X: …`, прогресс синхронизируется через 15 сек.
4. **Главная → Продолжить слушать**: карусель появляется после 15 сек прослушивания.
5. **Главная → тумблеры видимости**: скрывают соответствующие секции.
6. **Книги → фильтры** «В процессе» / «Завершённые»: прогресс из `userMediaProgress`.
7. **Миксы → AI переименование**: микс переименовывается под время суток.
8. **Виджет Android**: не падает, обложка уменьшена, контролы по центру, прозрачность 60%.

## Известные ограничения
- D: диск (0 байт) — сборка только на C: с копированием APK.
- Предупреждение о KGP-плагинах: `battery_plus`, `dynamic_color`, `flutter_chrome_cast`, `package_info_plus`, `safe_device`, `shared_preferences_android`, `volume_controller`, `wakelock_plus` — будущие версии Flutter не соберутся без миграции на Built-in Kotlin.
- `lyrics_service.dart:157 undefined durationMs`, `scrobble_service.dart:311 extends non-class`, `activity_heatmap.dart:140 onHover` — пред-существующие ошибки, не блокируют сборку.