import os
import requests

TOKEN = "9229103805:AAGg97RS7iF9qfkypwjxYUTHyt883ZZpTvM"
CHAT_ID = -1004210923223
API_BASE = f"https://api.telegram.org/bot{TOKEN}"

SUMMARY_TEXT = """⚡️ <b>AntiCensor v5.6.4-OTA: ФИКС ПЕРЕХОДА ТРЕКОВ + ПЛАВНЫЙ КРОССФЕЙД + СЛАБЫЙ ИНТЕРНЕТ!</b> ⚡️

══════════════════════════════
🛠 <b>ЧТО ПОФИКШЕНО:</b>

1. 🔄 <b>УБРАН БАГ ПЕРЕХОДА МЕЖДУ ТРЕКАМИ:</b>
   • Раньше после окончания заменённого трека (SoundCloud / с телефона) на долю секунды проигрывалось начало ПРЕДЫДУЩЕГО трека.
   • Теперь старый плеер гасится сразу при смене трека — переход чистый.

2. 🎚 <b>ПЛАВНЫЙ ПЕРЕХОД (КРОССФЕЙД):</b>
   • Новый трек стартует с плавным нарастанием громкости (fade-in) вместо резкого щелчка.

3. 📶 <b>АДАПТАЦИЯ SOUNDCLOUD ПОД СЛАБЫЙ ИНТЕРНЕТ:</b>
   • На медленной связи (2G/3G) iOS запрашивает меньший битрейт (96/128 kbps) и держит больший буфер (до 12 сек) — меньше заиканий и пауз.
   • Сервер /sc теперь умеет отдавать MP3 в нужном битрейте.

4. 📝 <b>СВОИ ТЕКСТЫ ДЛЯ ЛЮБОГО ТРЕКА:</b>
   • Текст можно добавить/изменить через контекстное меню трека → «AntiCensor» → «Текст песни» (синхронизируется и с ПК).

══════════════════════════════
📦 <b>Файл AntiCensor.dylib (v5.6.4-OTA, Build 2026112102) прикреплён ниже!</b>"""

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
                "caption": "🚀 <b>AntiCensor.dylib (v5.6.4-OTA, Build 2026112102)</b>\nФикс перехода треков + плавный кроссфейд + адаптация SoundCloud под слабый интернет",
                "parse_mode": "HTML"
            }
            r_doc = requests.post(f"{API_BASE}/sendDocument", data=data, files=files)
            print("sendDocument status:", r_doc.status_code, r_doc.json().get("ok"))
    else:
        print(f"Error: {dylib_path} not found!")

if __name__ == "__main__":
    dylib_path = os.path.join(os.path.dirname(__file__), "build_output", "AntiCensor.dylib")
    send_report(dylib_path)
