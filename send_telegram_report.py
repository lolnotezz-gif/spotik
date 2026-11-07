import os
import requests

TOKEN = "9229103805:AAGg97RS7iF9qfkypwjxYUTHyt883ZZpTvM"
CHAT_ID = -1004210923223
API_BASE = f"https://api.telegram.org/bot{TOKEN}"

SUMMARY_TEXT = """🔥 <b>AntiCensor iOS v5.5.5-OTA: ФИНАЛЬНЫЙ РАЗЪЁБ ВСЕХ БАГОВ!</b> 🔥

Пофиксил синхронизацию текста и убрал нахуй 5-секундный затуп!

══════════════════════════════
🛠 <b>ЧТО СДЕЛАНО:</b>

1. ⚡️ <b>УБРАНА 5-СЕКУНДНАЯ ЗАДЕРЖКА:</b>
   • В коде стоял 5-секундный системный таймаут на запрос к SoundCloud. Если коннект чуть тупил — твик ровно 5 секунд ждал у моря погоды!
   • Срезал таймаут до <b>1.0 секунды</b>. Трек теперь стартует моментально (1–1.5 сек)!

2. 🎤 <b>СИНХРОНИЗАЦИЯ ТЕКСТА ВОССТАНОВЛЕНА:</b>
   • Из-за того, что в v5.5.4 проверка воспроизведения стояла после выхода из метода, для обычных/локальных треков статус застывал в паузе, и текст тупо замерзал на месте!
   • Вернул глобальный трекинг времени и статуса на самый верх: теперь <b>караоке и подсветка строк бегут секунда в секунду с треком</b>!

3. 🎯 <b>МГНОВЕННЫЙ ПЕРЕХОД ПО КЛИКУ НА СТРОКУ ТЕКСТА:</b>
   • Добавил <code>kCMTimeZero</code> в перемотку плеера — теперь при тапе на любую строку текста плеер прыгает ровно в эту миллисекунду без задержек и раздумий!

══════════════════════════════
📦 <b>Файл AntiCensor.dylib (v5.5.5-OTA, Build 2026110718) прикреплён ниже!</b>"""

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
                "caption": "🚀 <b>AntiCensor.dylib (v5.5.5-OTA, Build 2026110718)</b>\nТекст синхронен 1:1 • SC играет за 1 сек • Мгновенный прыжок по тексту",
                "parse_mode": "HTML"
            }
            r_doc = requests.post(f"{API_BASE}/sendDocument", data=data, files=files)
            print("sendDocument status:", r_doc.status_code, r_doc.json().get("ok"))
    else:
        print(f"Error: {dylib_path} not found!")

if __name__ == "__main__":
    dylib_path = os.path.join(os.path.dirname(__file__), "build_output", "AntiCensor.dylib")
    send_report(dylib_path)
