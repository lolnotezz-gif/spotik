import os
import requests

TOKEN = "9229103805:AAGg97RS7iF9qfkypwjxYUTHyt883ZZpTvM"
CHAT_ID = -1004210923223
API_BASE = f"https://api.telegram.org/bot{TOKEN}"

SUMMARY_TEXT = """⚡️ <b>AntiCensor v5.6.15-OTA: ВОЗВРАЩАЮ БЫСТРЫЙ СТАРТ 1-3 СЕКУНДЫ</b> ⚡️

══════════════════════════════
🛠 <b>ЧТО БЫЛО НЕ ТАК:</b>

• В 5.6.14 я отключил прямой HLS и погнал все треки через серверный транскод.
• Транскод = сначала скачать и перекодировать весь трек на сервере, отсюда 10+ секунд тишины.
• Именно прямой поток с CDN давал те самые 1-3 секунды.

══════════════════════════════
✅ <b>ЧТО СДЕЛАНО:</b>

1. ⚡ <b>Прямой HLS снова основной путь</b>
   • Старт 1-3 секунды, как раньше.

2. 🔥 <b>Прогрев фолбэка в фоне</b>
   • Если прямой поток не стартовал за 3.5 секунды — в фоне запускается подготовка серверного MP3.
   • Новый эндпоинт /warm готовит файл заранее, поэтому аварийный переход будет мгновенным, а не через 10 секунд.

3. 🔂 <b>Без циклов</b>
   • Ретрай по-прежнему один: не заиграло → серверный MP3 → если и он нет, Spotify размьючивается и играет оригинал + тост.

4. 🩺 <b>Заметил проблему на сервере</b>
   • SoundCloud сейчас отдаёт 404 на резолв с IP Render (похоже, временный rate-limit после моих нагрузочных тестов).
   • Поэтому HLS с телефона (прямой резолв) — теперь главный путь, он от Render не зависит. Серверный фолбэк восстановится сам.

══════════════════════════════
📦 <b>Файл AntiCensor.dylib (v5.6.15-OTA, Build 2026112113) прикреплён ниже!</b>

Установка: Sideloadly → Advanced Options → Inject dylib → этот файл → Start."""

def send_report(dylib_path):
    print("Posting report to Telegram...")
    msg_payload = {
        "chat_id": CHAT_ID,
        "text": SUMMARY_TEXT,
        "parse_mode": "HTML"
    }

    r_msg = requests.post(f"{API_BASE}/sendMessage", json=msg_payload)
    print("sendMessage status:", r_msg.status_code, r_msg.json().get("ok"))

    if os.path.exists(dylib_path):
        print(f"Uploading {dylib_path} ({os.path.getsize(dylib_path)} bytes)...")
        with open(dylib_path, "rb") as f:
            files = {"document": ("AntiCensor.dylib", f, "application/octet-stream")}
            data = {
                "chat_id": CHAT_ID,
                "caption": "🚀 <b>AntiCensor.dylib (v5.6.15-OTA, Build 2026112113)</b>\nСтабильный звук + оффлайн-кэш после первого прослушивания",
                "parse_mode": "HTML"
            }
            r_doc = requests.post(f"{API_BASE}/sendDocument", data=data, files=files)
            print("sendDocument status:", r_doc.status_code, r_doc.json().get("ok"))
    else:
        print(f"Error: {dylib_path} not found!")

if __name__ == "__main__":
    dylib_path = os.path.join(os.path.dirname(__file__), "build_output", "AntiCensor.dylib")
    send_report(dylib_path)
