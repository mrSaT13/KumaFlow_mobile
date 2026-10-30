<div align="center">

# 🌊 KumaFlow Mobile

### Свободный музыкальный плеер — Subsonic · Navidrome · Jellyfin · офлайн · «Моя волна»

[![Version](https://img.shields.io/badge/version-3.7.56-fa243c?style=for-the-badge)](https://github.com/mrSaT13/KumaFlow_mobile/releases)
[![Flutter](https://img.shields.io/badge/Flutter-3.44-02569B?style=for-the-badge&logo=flutter)](https://flutter.dev)
[![Platform](https://img.shields.io/badge/platform-Android%20%7C%20Windows%20%7C%20Linux-success?style=for-the-badge)](https://github.com/mrSaT13/KumaFlow_mobile/releases)
[![License](https://img.shields.io/badge/license-CC%20BY--NC--SA%204.0-lightgrey?style=for-the-badge)](LICENSE)

[🇷🇺 Русский](#-о-проекте) · [🇬🇧 English](#-about)

</div>

---

## 🇷🇺 О проекте

**KumaFlow Mobile** — кроссплатформенный клиент для своей музыкальной коллекции:
серверы **Subsonic / Navidrome / Airsonic**, плюс **Jellyfin**, **AudiobookShelf**,
локальные файлы, **Яндекс Музыка** и **МТС Музыка (Kion)**. Интерфейс в духе Apple Music,
тёмная/светлая темы, «Моя волна» с машинным обучением, тексты песен, офлайн-кеш,
Chromecast/DLNA и связка с **KumaFlow Brain** (сервер рекомендаций и уведомлений о новинках).

> ⚠️ Проект распространяется под **CC BY-NC-SA 4.0** — только некоммерческое использование.
> Подробности в [LICENSE](LICENSE).

### ✨ Возможности

| Блок | Что умеет |
|------|-----------|
| 🎵 Серверы | Subsonic, Navidrome, Airsonic, Jellyfin, AudiobookShelf, локальная библиотека |
| 🌊 Моя волна | ML-подборка: жанры, эпохи, занятия, «Боевое» настроение, LLM-координатор |
| 🧠 KumaFlow Brain | Синхронизация вкусов, подписки на артистов, пуши о новых альбомах |
| 🎨 Фон волны | **KumaWave V1** (статика) / **V2** (блобы) / **V3** (WebGL-шейдер с десктопа) |
| 📝 Тексты | LRC, караоке-подсветка, NetEase-формат |
| 📴 Офлайн | Кеширование треков, докачка новинок подписанных артистов |
| 📡 Трансляции | Chromecast, DLNA/UPnP, десктоп-пульт, Android Auto |
| 🎧 Аудио | Эквалайзер, кроссфейд по BPM, gapless, sleep-таймер |
| 🇷🇺 Интеграции | Яндекс Музыка (похожие, обложки), МТС Музыка, ListenBrainz-скробблинг |

### 📸 Скриншоты

Положи кадры в папку [`screenshots/`](screenshots/) — они подхватятся сюда автоматически.
Рекомендуемый формат: PNG, ширина 720–1080px.

### 🚀 Сборка

```bash
flutter pub get
flutter build apk --release        # Android
flutter build windows --release    # Windows
flutter build linux --release      # Linux
```

Нужны: Flutter 3.44+, JDK 21, Android SDK 36. Подпись релиза — через
`android/key.properties` (шаблон: `android/key.properties.example`).
Готовые APK лежат в [Releases](https://github.com/mrSaT13/KumaFlow_mobile/releases),
а не в гите.

### 🗂 Структура

```
lib/
├── main.dart            # точка входа, DI, инициализация сервисов
├── screens/             # экраны (home, now playing, волна, мозг…)
├── widgets/            # hero-карточки, волна V1/V2/V3, плеер-бары
├── providers/          # состояние (player, library, auth…)
├── services/           # Subsonic, офлайн, ML, волна, мозг, lyrics…
│   └── kumaflow_brain/ # мост и клиент KumaFlow Brain
├── models/             # Song, Album, Artist, Playlist…
├── shaders/            # vibe_wave.frag — V3-шейдер с десктопа
└── l10n/               # локализации (29 языков)
```

Серверная часть (Brain): отдельный репозиторий.

### 🤝 Контрибьюция

PR и issue приветствуются. Перед коммитом: `flutter analyze`, тесты в `test/`.

---

## 🇬🇧 About

**KumaFlow Mobile** is a cross-platform music player for self-hosted libraries:
**Subsonic / Navidrome / Airsonic** servers, plus **Jellyfin**, **AudiobookShelf**,
local files, Yandex Music and MTS Music. Apple Music-inspired UI, dark/light themes,
ML-powered “My Wave”, synced lyrics, offline cache, Chromecast/DLNA, and an optional
**KumaFlow Brain** backend (taste sync, artist subscriptions, new-release push).

> ⚠️ Licensed under **CC BY-NC-SA 4.0** — non-commercial use only. See [LICENSE](LICENSE).

Build with `flutter pub get` + `flutter build apk --release`. Ready-made APKs live in
[Releases](https://github.com/mrSaT13/KumaFlow_mobile/releases).
</div>
