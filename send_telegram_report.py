import os
import requests

TOKEN = "9229103805:AAGg97RS7iF9qfkypwjxYUTHyt883ZZpTvM"
CHAT_ID = -1004210923223
API_BASE = f"https://api.telegram.org/bot{TOKEN}"

SUMMARY_TEXT = """⚡️ <b>AntiCensor v5.6.3-OTA: ФИКС ЗАДЕРЖКИ ПОДГРУЗКИ SOUNDCLOUD НА iPhone!</b> ⚡️

══════════════════════════════
🛠 <b>ЧТО НАЙДЕНО И ПОФИКШЕНО:</b>

1. ⏱ <b>УБРАНА ЗАДЕРЖКА ПРИ ПЕРВОМ ВОСПРОИЗВЕДЕНИИ SOUNDCLOUD-ТРЕКА НА iPhone:</b>
   • Раньше при первом Play айфон ждал, пока Render-сервер <code>/sc</code> синхронно резолвил SoundCloud и транскодировал весь трек в MP3 — это давало 10–30+ секунд паузы.
   • Теперь iOS заранее прогревает сервер через <code>/preload</code> в трёх случаях: при сохранении замены, при запуске приложения и при облачной синхронизации с ПК.
   • Итог: SoundCloud-трек стартует мгновенно, потому что MP3 уже лежит в кэше сервера.

══════════════════════════════
📦 <b>Файл AntiCensor.dylib (v5.6.3-OTA, Build 2026112101) прикреплён ниже!</b>"""

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
                "caption": "🚀 <b>AntiCensor.dylib (v5.6.3-OTA, Build 2026112101)</b>\nФикс задержки подгрузки SoundCloud на iPhone (фоновая предзагрузка /preload)",
                "parse_mode": "HTML"
            }
            r_doc = requests.post(f"{API_BASE}/sendDocument", data=data, files=files)
            print("sendDocument status:", r_doc.status_code, r_doc.json().get("ok"))
    else:
        print(f"Error: {dylib_path} not found!")

if __name__ == "__main__":
    dylib_path = os.path.join(os.path.dirname(__file__), "build_output", "AntiCensor.dylib")
    send_report(dylib_path)
