import os
import requests

TOKEN = "9229103805:AAGg97RS7iF9qfkypwjxYUTHyt883ZZpTvM"
CHAT_ID = -1004210923223
API_BASE = f"https://api.telegram.org/bot{TOKEN}"

SUMMARY_TEXT = """⚡️ <b>AntiCensor v5.6.5-OTA: ФИКС ПЕРЕКЛЮЧЕНИЯ ТРЕКОВ + СВОИ ТЕКСТЫ!</b> ⚡️

══════════════════════════════
🛠 <b>ЧТО ПОФИКШЕНО:</b>

1. 🔄 <b>ФИКС ПЕРЕКЛЮЧЕНИЯ ТРЕКОВ:</b>
   • Раньше при ручном переключении на другой трек (не дослушав) могло заново проиграться начало ПРЕДЫДУЩЕГО трека.
   • Теперь при смене трека перемотка не применяется к старому плееру — переход чистый.

2. 📝 <b>СВОИ ТЕКСТЫ РАБОТАЮТ:</b>
   • Добавление и удаление текста теперь сразу отображается на экране (раньше не вызывалась перерисовка после сохранения).

══════════════════════════════
📦 <b>Файл AntiCensor.dylib (v5.6.5-OTA, Build 2026112103) прикреплён ниже!</b>"""

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
                "caption": "🚀 <b>AntiCensor.dylib (v5.6.5-OTA, Build 2026112103)</b>\nФикс переключения треков + свои тексты отображаются сразу",
                "parse_mode": "HTML"
            }
            r_doc = requests.post(f"{API_BASE}/sendDocument", data=data, files=files)
            print("sendDocument status:", r_doc.status_code, r_doc.json().get("ok"))
    else:
        print(f"Error: {dylib_path} not found!")

if __name__ == "__main__":
    dylib_path = os.path.join(os.path.dirname(__file__), "build_output", "AntiCensor.dylib")
    send_report(dylib_path)
