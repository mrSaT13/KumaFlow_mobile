<div align="center">

<img src="assets/app_icon.png" width="128" alt="KumaFlow Mobile" />

# KumaFlow Mobile

**Мобильный клиент для своей музыкальной коллекции — Subsonic / Navidrome, «Моя волна», офлайн**

[![Release](https://img.shields.io/github/v/release/mrSaT13/KumaFlow_mobile)](https://github.com/mrSaT13/KumaFlow_mobile/releases/latest)
[![Platform](https://img.shields.io/badge/platform-Android%20%7C%20Windows%20%7C%20Linux-success)](https://github.com/mrSaT13/KumaFlow_mobile/releases/latest)
[![Flutter](https://img.shields.io/badge/Flutter-3.44-02569B?logo=flutter)](https://flutter.dev)
[![License](https://img.shields.io/badge/license-CC%20BY--NC--SA%204.0-lightgrey)](LICENSE)

[🇷🇺 Русский](#-о-проекте) · [🇬🇧 English](#-about)

</div>

---

## 🧩 Экосистема KumaFlow

| Репозиторий | Что это | Ссылка |
|---|---|---|
| 🎵 **KumaFlow Player** | Десктоп-плеер (Windows · macOS · Linux) + web-режим. Локальный ML, Vibe Similarity, Smart Auto-DJ, книги, Remote Control | [github.com/mrSaT13/kumaflow](https://github.com/mrSaT13/kumaflow) |
| 🧠 **KumaFlow Brain** | Опциональный серверный мозг: sonic-анализ, CLAP-поиск, «Моя волна» per-user, daily-плейлисты, тексты, бэкапы | [github.com/mrSaT13/kumaflow-brain](https://github.com/mrSaT13/kumaflow-brain) |
| 📱 **KumaFlow Mobile** | Этот репозиторий — мобильный клиент (Android, Windows, Linux) | [github.com/mrSaT13/KumaFlow_mobile](https://github.com/mrSaT13/KumaFlow_mobile) |

**Как это работает вместе:**

```
Navidrome :4533 (музыка)
   ├─→ KumaFlow Mobile (этот репо) — играет, качает в офлайн, ведёт волну
   └─→ KumaFlow Brain :8000 (опционально) — анализирует, рекомендует, пушит новинки
            ↑ плеер шлёт события/лайки, забирает волну, подписки на артистов
```

Без мозга плеер полностью работает на локальном ML. С мозгом — умнее волна, подписки на артистов с пушами о новых альбомах, общий вкус между устройствами.

> ⚠️ Проект распространяется под **CC BY-NC-SA 4.0** — только некоммерческое использование. Подробности в [LICENSE](LICENSE).

---

## 🇷🇺 О проекте

### ✨ Возможности

Всё ниже — реально есть в коде, без маркетинговых приписок.

**🎵 Серверы и источники**
- **Subsonic / Navidrome / Airsonic / OpenSubsonic** — основной источник музыки
- **Jellyfin** — отдельный клиент в настройках
- **Audiobookshelf** — аудиокниги: библиотека, главы, «Продолжить», прогресс каждые 30 сек
- **Локальные файлы** — музыка с устройства, сливается с серверной библиотекой
- Радиостанции с сервера Navidrome, подкасты (подписки + эпизоды)

**🌊 Моя волна и рекомендации**
- Локальный ML: жанры, эпохи, занятия, настроение, «Боевое», время суток, vibe-фильтрация (BPM/energy/danceability)
- С мозгом: `POST /api/wave/continue`, общие настройки волны, handoff очереди между устройствами
- AI-микс (LLM), daily-микс, умный Auto-DJ, дизлайки с автобаном артиста
- **Фон волны на выбор:** KumaWave V1 (статика) / V2 (Canvas-блобы) / V3 (WebGL-шейдер с десктопа) — Настройки → Оформление

**🧠 KumaFlow Brain (опционально)**
- Автосинк вкусов (лайки/события фоном), профиль вкуса
- Подписки на артистов колокольчиком → системный пуш + страница «Новинки» с деталями
- Докачка новинок подписанных артистов в офлайн-кеш (тумблер + «только по Wi-Fi»)

**📝 Тексты песен**
- LRC с караоке-подсветкой, построчные + пословные, NetEase-формат, LRCLIB-подтяжка

**📴 Офлайн**
- Кеширование треков, очередь докачки, индикатор прогресса синхронизации

**📡 Трансляции**
- Chromecast, DLNA/UPnP (включая gapless-prefetch), пульт десктопа, Android Auto

**🎧 Аудио**
- Эквалайзер, кроссфейд по BPM, gapless-очередь окном до 200 треков, sleep-таймер с fade-out
- Скробблинг ListenBrainz

### 🚀 Установка

Готовые сборки — только во вкладке [**Releases**](https://github.com/mrSaT13/KumaFlow_mobile/releases) (APK в гит не коммитятся).
Проверка обновлений: Настройки → О программе.

- **Android:** `KumaFlow Mobile X.Y.Z.apk` → установить, разрешить «неизвестные источники»

### 🎯 Быстрый старт

```
1. Сервер: URL http://твой-сервер:4533 + логин/пароль Navidrome
2. (Опционально) Мозг: Настройки → Мозг → URL + Token + user_id
3. Лайкни 5–10 треков → «Моя волна» на главной → Play
4. Подписка на артиста: колокольчик на странице артиста → новинки придут пушем
```

### 📸 Скриншоты

Положи кадры в [`screenshots/`](screenshots/) (PNG, ширина 720–1080) — подхватятся сюда.

| Главная — Моя волна | Сейчас играет | Новинки |
|---|---|---|
| *скриншот* | *скриншот* | *скриншот* |

### 🛠️ Разработка

**Требования:** Flutter 3.44+ · JDK 21 · Android SDK 36

```bash
git clone https://github.com/mrSaT13/KumaFlow_mobile.git
cd KumaFlow_mobile
flutter pub get
flutter analyze
flutter build apk --release   # Android
flutter build windows --release
```

Подпись релиза: `android/key.properties` + `release.jks` (локально, в гит не идут; шаблон — `android/key.properties.example`).
Проверки: `flutter analyze`, тесты в `test/`.

Структура (коротко): `lib/screens/` — экраны, `lib/widgets/` — hero-карточки и волна V1/V2/V3, `lib/providers/` — состояние, `lib/services/` — Subsonic/офлайн/ML/мозг/тексты (мост и клиент мозга — `lib/services/kumaflow_brain/`), `lib/shaders/vibe_wave.frag` — V3-шейдер с десктопа, `lib/l10n/` — 29 языков.

Вклад приветствуется: Fork → ветка `feature/...` → commit → Push → Pull Request.

---

## 🇬🇧 About

**KumaFlow Mobile** is a cross-platform client for self-hosted music: **Subsonic / Navidrome / Airsonic / OpenSubsonic** servers, plus **Jellyfin**, **Audiobookshelf** (audiobooks), local files, server radio and podcasts. ML-powered “My Wave” (local, or server-side via optional **KumaFlow Brain**), synced lyrics, offline cache, Chromecast/DLNA, Android Auto, equalizer, BPM crossfade, gapless queue, sleep timer, ListenBrainz scrobbling.

> ⚠️ Licensed under **CC BY-NC-SA 4.0** — non-commercial use only. See [LICENSE](LICENSE).

Install from [**Releases**](https://github.com/mrSaT13/KumaFlow_mobile/releases) (no APKs in git). Build: `flutter pub get` + `flutter build apk --release`.

---

## 📄 Лицензия / License

CC BY-NC-SA 4.0 — см. [LICENSE](LICENSE).
</div>
