import os
import requests

TOKEN = "9229103805:AAGg97RS7iF9qfkypwjxYUTHyt883ZZpTvM"
CHAT_ID = -1004210923223
API_BASE = f"https://api.telegram.org/bot{TOKEN}"

SUMMARY_TEXT = """⚡️ <b>AntiCensor v5.6.17-OTA: БОЛЬШЕ НЕ СБРАСЫВАЕТ НА ТРЕК SPOTIFY</b> ⚡️

══════════════════════════════
✅ <b>ЧТО СДЕЛАНО:</b>

1. 🚫 <b>Убрал откат на оригинал Spotify</b>
   • Раньше при сбое замена выключалась, Spotify размьючивался и играл цензурный трек — это и было «сбрасывает на спотика» и «само паузится».
   • Теперь этого кода нет вообще. Spotify остаётся заглушённым всегда, пока трек не сменишь.

2. 🔁 <b>Вместо отката — ретраи</b>
   • Не заиграло → перезапуск с новым (свежим) медиа-URL.
   • Паузы: 6, 10, 14 ... до 30 секунд, до 20 попыток. Без возврата на оригинал.

3. 📶 <b>Адаптация под слабую сеть</b>
   • Буфер вперёд увеличен: 15 с на 2G/EDGE, 10 с на 3G, 6 с на средней связи.
   • На медленной сети плеер ждёт минимальный буфер (это и лечит обрыв на 4-6 секунде).
   • Добавлен «толчок» воспроизведения, если поток всё-таки встал.

4. 🧹 <b>Убрал бесполезный прогрев сервера</b>
   • SoundCloud блокирует IP Render (403), поэтому /warm только тратил время.

══════════════════════════════
⚠️ <b>ВАЖНО:</b>
• Прямые ссылки on.soundcloud.com требуют шага «развернуть редирект». Если ваш оператор режет soundcloud.com — этот шаг не проходит.
• Если трек не играет, замени ссылку на каноническую: https://soundcloud.com/артист/трек
• Сервер сейчас бесполезен: SoundCloud отдаёт ему 403 (блокировка по IP датацентра).

══════════════════════════════
📦 <b>Файл AntiCensor.dylib (v5.6.17-OTA, Build 2026112115) прикреплён ниже!</b>

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
                "caption": "🚀 <b>AntiCensor.dylib (v5.6.17-OTA, Build 2026112115)</b>\nСтабильный звук + оффлайн-кэш после первого прослушивания",
                "parse_mode": "HTML"
            }
            r_doc = requests.post(f"{API_BASE}/sendDocument", data=data, files=files)
            print("sendDocument status:", r_doc.status_code, r_doc.json().get("ok"))
    else:
        print(f"Error: {dylib_path} not found!")

if __name__ == "__main__":
    dylib_path = os.path.join(os.path.dirname(__file__), "build_output", "AntiCensor.dylib")
    send_report(dylib_path)
