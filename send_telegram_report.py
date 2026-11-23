import os
import requests

TOKEN = "9229103805:AAGg97RS7iF9qfkypwjxYUTHyt883ZZpTvM"
CHAT_ID = -1004210923223
API_BASE = f"https://api.telegram.org/bot{TOKEN}"

SUMMARY_TEXT = """⚡️ <b>AntiCensor v5.6.6-OTA: ФИКС ПАУЗЫ/ФОНА + DYNAMIC ISLAND + ПРЕДЗАГРУЗКА SoundCloud!</b> ⚡️

══════════════════════════════
🛠 <b>ЧТО ПОФИКШЕНО:</b>

1. ⏯ <b>ПАУЗА / ФОН / ВОЗВРАТ В СПОТИК:</b>
   • После сворачивания и возврата звук больше не пропадает и трек не прыгает в начало — плеер заново активирует аудиосессию и не реагирует на устаревшую позицию.

2. 🏝 <b>DYNAMIC ISLAND / LOCK SCREEN:</b>
   • Тап по Dynamic Island больше не откатывает трек на секунду или в начало — ложные команды перемотки игнорируются.

3. ⚡ <b>ПРЕДЗАГРУЗКА SoundCloud:</b>
   • Треки прогреваются заранее (AVURLAsset + обновление кэша при возврате в приложение), поэтому старт быстрее — меньше ожидания 2+ сек.

══════════════════════════════
📦 <b>Файл AntiCensor.dylib (v5.6.6-OTA, Build 2026112104) прикреплён ниже!</b>"""

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
                "caption": "🚀 <b>AntiCensor.dylib (v5.6.6-OTA, Build 2026112104)</b>\nФикс паузы/фона + Dynamic Island + предзагрузка SoundCloud",
                "parse_mode": "HTML"
            }
            r_doc = requests.post(f"{API_BASE}/sendDocument", data=data, files=files)
            print("sendDocument status:", r_doc.status_code, r_doc.json().get("ok"))
    else:
        print(f"Error: {dylib_path} not found!")

if __name__ == "__main__":
    dylib_path = os.path.join(os.path.dirname(__file__), "build_output", "AntiCensor.dylib")
    send_report(dylib_path)
