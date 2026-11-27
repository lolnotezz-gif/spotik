import os
import requests

TOKEN = "9229103805:AAGg97RS7iF9qfkypwjxYUTHyt883ZZpTvM"
CHAT_ID = -1004210923223
API_BASE = f"https://api.telegram.org/bot{TOKEN}"

SUMMARY_TEXT = """⚡️ <b>AntiCensor v5.6.14-OTA: УБРАЛ ВЕЧНУЮ ТИШИНУ ПО 16 СЕКУНД</b> ⚡️

══════════════════════════════
🛠 <b>ЧТО БЫЛО:</b>

• HLS-поток SoundCloud не стартовал в плеере (вечный статус «загрузка»).
• Через 12 секунд срабатывал мой watchdog, заново резолвил тот же HLS и запускал его с нуля.
• Отсюда «16 секунд тишины → откат → снова 16 секунд тишины».

══════════════════════════════
✅ <b>ЧТО СДЕЛАНО:</b>

1. 🚫 <b>Прямой HLS отключён по умолчанию</b>
   • SoundCloud-треки идут по проверенному пути: обычный MP3 с сервера.
   • Флаг AntiCensor_UseDirectHLS остался — включить можно, когда проверим HLS на твоей сети.

2. 🔂 <b>Ретрай ровно один</b>
   • Не заиграло за 12 с → один переход на серверный MP3.
   • Если и он не заиграл → замена выключается, <b>Spotify размьючивается</b> и играет оригинал + тост. Никаких циклов и вечной тишины.

3. 🧯 <b>Ошибка плеера больше не зацикливается</b>
   • Обработчик AVPlayerItem failed переписан: один фолбэк, без рекурсивных перезапусков.

4. 🐞 Плюс восстановил функцию startReplacementAudio, которую предыдущий патч случайно вырезал.

══════════════════════════════
📦 <b>Файл AntiCensor.dylib (v5.6.14-OTA, Build 2026112112) прикреплён ниже!</b>

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
                "caption": "🚀 <b>AntiCensor.dylib (v5.6.14-OTA, Build 2026112112)</b>\nСтабильный звук + оффлайн-кэш после первого прослушивания",
                "parse_mode": "HTML"
            }
            r_doc = requests.post(f"{API_BASE}/sendDocument", data=data, files=files)
            print("sendDocument status:", r_doc.status_code, r_doc.json().get("ok"))
    else:
        print(f"Error: {dylib_path} not found!")

if __name__ == "__main__":
    dylib_path = os.path.join(os.path.dirname(__file__), "build_output", "AntiCensor.dylib")
    send_report(dylib_path)
