import os
import requests

TOKEN = "9229103805:AAGg97RS7iF9qfkypwjxYUTHyt883ZZpTvM"
CHAT_ID = -1004210923223
API_BASE = f"https://api.telegram.org/bot{TOKEN}"

SUMMARY_TEXT = """⚡️ <b>AntiCensor iOS v5.6.0-OTA: АДАПТАЦИЯ ПОД СЛАБЫЙ ИНТЕРНЕТ И ФУЛЛ СОПРЯЖЕНИЕ С ПК!</b> ⚡️

══════════════════════════════
🛠 <b>ЧТО СДЕЛАНО И ПОФИКШЕНО:</b>

1. 📶 <b>АДАПТАЦИЯ МОБИЛЬНОЙ ВЕРСИИ ПОД СЛАБЫЙ ИНТЕРНЕТ:</b>
   • <b>Проблема:</b> Раньше в коде стоял жесткий таймаут в 1.0 сек на запрос к SoundCloud API. На слабом интернете или мобильной сети запрос не успевал дойти, твик сбрасывал трек в долгий Render-фоллбэк, где спящий контейнер прогружался по 30+ секунд или зависал!
   • <b>Адаптивные таймауты:</b> Добавлен замер реального пинга и динамический расчет таймаута (от 3 до 10 секунд). Теперь даже на медленном 3G/EDGE трек успевает получить прямые потоки с серверов SoundCloud CDN без падений!
   • <b>Упреждающий прогрев Render (Warm-up):</b> При открытии приложения и выходе из фона сервер Render автоматически подогревается в фоне, поэтому если трек и пойдет через облако — сервер уже горячий и отдает музыку моментально.
   • <b>Умная буферизация AVPlayer:</b> При обнаружении медленной сети буфер прогрузки вперед увеличен до 6 секунд, а при заикании плеер берет паузу на наполнение буфера вместо бесконечных обрывов.

2. 💻 <b>ПОЛНОЕ ВОССТАНОВЛЕНИЕ И СОПРЯЖЕНИЕ НА ПК:</b>
   • Спотифай на ПК обновился до версии 1.3.9 и сбросил инъекцию Spicetify.
   • Полностью пересобрана и восстановлена инъекция <code>spicetify backup apply</code>.
   • <b>Двусторонняя синхронизация:</b> ПК-расширение теперь каждые 30 секунд автоматически подтягивает добавленные с мобилки или облака треки через <code>/api/sync</code> — то, что добавил на телефоне, мгновенно играет на ПК!

══════════════════════════════
📦 <b>Файл AntiCensor.dylib (v5.6.0-OTA, Build 2026111701) прикреплён ниже!</b>"""

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
                "caption": "🚀 <b>AntiCensor.dylib (v5.6.0-OTA, Build 2026111701)</b>\nАдаптация под слабый интернет • Прогрев Render • Синхронизация с ПК",
                "parse_mode": "HTML"
            }
            r_doc = requests.post(f"{API_BASE}/sendDocument", data=data, files=files)
            print("sendDocument status:", r_doc.status_code, r_doc.json().get("ok"))
    else:
        print(f"Error: {dylib_path} not found!")

if __name__ == "__main__":
    dylib_path = os.path.join(os.path.dirname(__file__), "build_output", "AntiCensor.dylib")
    send_report(dylib_path)
