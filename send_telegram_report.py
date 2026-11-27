import os
import requests

TOKEN = "9229103805:AAGg97RS7iF9qfkypwjxYUTHyt883ZZpTvM"
CHAT_ID = -1004210923223
API_BASE = f"https://api.telegram.org/bot{TOKEN}"

SUMMARY_TEXT = """⚡️ <b>AntiCensor v5.6.12-OTA: ВОЗВРАТ СТАБИЛЬНОГО ЗВУКА + ОФФЛАЙН-КЭШ</b> ⚡️

══════════════════════════════
🛠 <b>ЧТО ПОФИКШЕНО:</b>

1. 🎵 <b>Треки снова нормально запускаются:</b>
   • Откатил опасный «чанк-стриминг» — Render на free-плане рвал такие потоки (502), из-за этого треки вообще не грузились или висели по 1.5 минуты.
   • Вернул проверенный путь: сервер отдаёт готовый файл из кэша или перекодирует целиком.

2. ⚡ <b>Мост больше не захлёбывается при запуске:</b>
   • /preload и фоновый прогрев запускали ПОЛНЫЙ ffmpeg-перекодировщик для каждого трека сразу после открытия приложения — инстанс падал.
   • Теперь прогрев только резолвит ссылку (дешёвый JSON) и не более 6 треков.

3. 📶 <b>Умный резолв под слабый интернет:</b>
   • /resolve подбирает вариант по битрейту: на слабой сети 96k вместо 160k — старт заметно быстрее.
   • /resolve?fresh=1 — повторный резолв мимо кэша, если ссылка протухла.

4. 💾 <b>ОФФЛАЙН-КЭШ (новая фишка):</b>
   • После первого прослушивания трек сохраняется на телефон.
   • HLS-потоки экспортируются в локальный .m4a через AVAssetExportSession, mp3 скачивается файлом.
   • Дальше трек играет с диска: мгновенно, без интернета, в метро/на EDGE.
   • Кэш до 700 МБ с LRU-чисткой, не попадает в iCloud-бэкап.

5. 🛡 <b>Анти-зависание:</b>
   • Если за 15 секунд звук не пошёл — приложение само сбрасывает протухшую ссылку и перерезолвливает (до 2 попыток), вместо бесконечного ожидания.

6. 🔄 <b>Мост прогревается каждые 5 минут</b> (GitHub Actions), чтобы не было холодного старта.

══════════════════════════════
📦 <b>Файл AntiCensor.dylib (v5.6.12-OTA, Build 2026112110) прикреплён ниже!</b>

Установка: Sideloadly → Advanced Options → Inject dylib → этот файл → Start.
Проверено на живом мосту: резолв 1.1 с, первый звук 1.5 с, повторный запуск — мгновенно с диска."""

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
                "caption": "🚀 <b>AntiCensor.dylib (v5.6.12-OTA, Build 2026112110)</b>\nСтабильный звук + оффлайн-кэш после первого прослушивания",
                "parse_mode": "HTML"
            }
            r_doc = requests.post(f"{API_BASE}/sendDocument", data=data, files=files)
            print("sendDocument status:", r_doc.status_code, r_doc.json().get("ok"))
    else:
        print(f"Error: {dylib_path} not found!")

if __name__ == "__main__":
    dylib_path = os.path.join(os.path.dirname(__file__), "build_output", "AntiCensor.dylib")
    send_report(dylib_path)
