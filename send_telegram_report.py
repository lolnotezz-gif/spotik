import os
import requests

TOKEN = "9229103805:AAGg97RS7iF9qfkypwjxYUTHyt883ZZpTvM"
CHAT_ID = -1004210923223
API_BASE = f"https://api.telegram.org/bot{TOKEN}"

SUMMARY_TEXT = """⚡️ <b>AntiCensor v5.6.16-OTA: ФИКС «4-6 СЕКУНД И ТИШИНА»</b> ⚡️

══════════════════════════════
🛠 <b>ПРИЧИНЫ (нашёл обе):</b>

1. 🐞 <b>Моя регрессия с буфером плеера</b>
   • В 5.6.9 я принудительно поставил AVPlayer «не ждать буфер» (automaticallyWaitsToMinimizeStalling = NO).
   • На слабой сети плеер стартовал быстро, но буфера хватало ровно на 4-6 секунд — дальше он вставал и сам не продолжал.
   • Вернул адаптивное поведение (на медленной сети ждём буфер) + добавил «толчок» при зависании.

2. 🚫 <b>SoundCloud блокирует сервер</b>
   • Проверил напрямую: с IP Render SoundCloud отдаёт <b>403 Forbidden</b> и на api-v2, и на on.soundcloud.com.
   • Это блокировка по IP датацентра, не мой код. Из-за неё серверный резолв и транскод сейчас не работают вообще.
   • Поэтому основной путь — прямой резолв с телефона (тот самый, что давал 1-3 секунды).

3. 🔗 <b>Разворот коротких ссылок</b>
   • Добавил /expand на сервере и клиентский фолбэк — но сервер тоже получает 403, так что пока это не спасёт.

══════════════════════════════
💡 <b>ВАЖНО ПРО ССЫЛКИ:</b>
• Если трек не играет — замени его на <b>каноническую</b> ссылку вида
  https://soundcloud.com/артист/трек
  вместо короткой https://on.soundcloud.com/...
• Тогда телефон не тратит шаг на редирект (его как раз режут).

══════════════════════════════
📦 <b>Файл AntiCensor.dylib (v5.6.16-OTA, Build 2026112114) прикреплён ниже!</b>

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
                "caption": "🚀 <b>AntiCensor.dylib (v5.6.16-OTA, Build 2026112114)</b>\nСтабильный звук + оффлайн-кэш после первого прослушивания",
                "parse_mode": "HTML"
            }
            r_doc = requests.post(f"{API_BASE}/sendDocument", data=data, files=files)
            print("sendDocument status:", r_doc.status_code, r_doc.json().get("ok"))
    else:
        print(f"Error: {dylib_path} not found!")

if __name__ == "__main__":
    dylib_path = os.path.join(os.path.dirname(__file__), "build_output", "AntiCensor.dylib")
    send_report(dylib_path)
