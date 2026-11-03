# AntiCensor for Spotify iOS

Мод для Spotify на iOS (iPhone/iPad), позволяющий заменять зацензуренные треки на чистые оригиналы из SoundCloud с сохранением **официального синхронного караоке-текста** и фонового воспроизведения.

---

## 🚀 Архитектура проекта

1. **`backend/`** — серверный аудиомост на Python + ffmpeg (принимает ссылку на SoundCloud, на лету конвертирует в прогрессивный MP3 и стримит с поддержкой Range HTTP 206 для перемотки по тексту).
2. **`tweak/AntiCensor.m`** — нативный твик на Objective-C для iOS (перехватывает трек, при наличии замены плавно глушит звук Spotify и воспроизводит чистый оригинал, синхронизируя позицию с текстом песни).
3. **`.github/workflows/build.yml`** — автоматическая сборка `.dylib` и готового `.ipa` через бесплатный GitHub Actions (на macOS).

---

## Шаг 1: Развёртывание бесплатного сервера-моста (3 минуты)

Чтобы айфон мог воспроизводить треки через мобильный интернет или Wi-Fi, мост должен работать в облаке:

1. Зарегистрируйся на **[Render.com](https://render.com)** (бесплатно, карта не требуется).
2. Нажми **New +** -> **Web Service**.
3. Подключи свой GitHub-репозиторий с этим проектом (или выбери **Public Git repository**).
4. Render автоматически увидит `backend/Dockerfile` и `backend/render.yaml`:
   * **Environment**: `Docker`
   * **Plan**: `Free`
5. Нажми **Deploy Web Service**.
6. Через 2 минуты ты получишь свой постоянный адрес, например:
   `https://anticensor-bridge.onrender.com`

---

## Шаг 2: Сборка `.ipa` через GitHub Actions (1 клик)

1. Создай новый репозиторий на GitHub и загрузи туда файлы из этой папки:
   ```bash
   git init
   git add .
   git commit -m "Initial commit"
   git branch -M main
   git remote add origin https://github.com/твой-логин/AntiCensor-iOS.git
   git push -u origin main
   ```
2. Открой вкладку **Actions** в своём репозитории.
3. Выбери workflow **Build AntiCensor iOS** -> нажми **Run workflow**.
4. GitHub Actions на бесплатном сервере macOS скомпилирует `AntiCensor.dylib`.
5. Скачай готовый артефакт `AntiCensor.dylib`.

### Как вшить `AntiCensor.dylib` в Spotify:
В утилите **Sideloadly** на компьютере:
1. Выбери любой свежий `Spotify.ipa` (можно скачать с сайтов вроде decrypt.day или appdb).
2. Нажми кнопку **Advanced Options** -> в пункте **Inject dylib/framework** выбери скачанный `AntiCensor.dylib`.
3. Подключи iPhone проводом и нажми **Start** — модифицированный Spotify сразу установится на твой iPhone!

*(Либо в SideStore / TrollStore можно ставить готовый патченный IPA).*

---

## 📱 Как пользоваться на iPhone

1. Открой Spotify на iPhone и включи любой трек (например, зацензуренный трек Кишлака).
2. На экране текущего трека (Now Playing) **зажми пальцем обложку или название песни на 0.7 секунды**.
3. Появится системное меню **AntiCensor**:
   * Вставь ссылку на трек из SoundCloud (если ссылка уже была скопирована, она подставится сама!).
   * Нажми **«Сохранить»**.
   * *(Если сервер моста на Render, в меню «Сервер моста» один раз укажи свой URL).*
4. Трек сразу начнёт играть в полной версии без цензуры, а **текст песни будет синхронно подсвечиваться строка за строкой**!
