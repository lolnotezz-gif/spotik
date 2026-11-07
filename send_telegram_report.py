import os
import requests

TOKEN = "9229103805:AAGg97RS7iF9qfkypwjxYUTHyt883ZZpTvM"
CHAT_ID = -1004210923223
API_BASE = f"https://api.telegram.org/bot{TOKEN}"

SUMMARY_TEXT = """🔥 <b>AntiCensor iOS v5.5.6-OTA: ТОТАЛЬНЫЙ ФИКС КЕША И СИНХРОНИЗАЦИИ!</b> 🔥

Все косяки устранены под корень: старый кеш вычищен автоматом, треки стартуют с 0:00 без скипов, текст синхронен 1:1!

══════════════════════════════
🛠 <b>ЧТО ПОФИКШЕНО И СДЕЛАНО:</b>

1. ⚡️ <b>АВТОМАТИЧЕСКАЯ ОЧИСТКА ОТРАВЛЕННОГО ДИСКОВОГО КЕША:</b>
   • В v5.5.3 старые треки сохранили Render-ссылки на диск с TTL 2 часа — из-за этого они висели на задержке, пока их вручную не передобавишь!
   • <b>Сделано:</b> Теперь твик при старте и чтении автоматически и начисто вычищает любые Render-ссылки из памяти и файла на диске. <b>Все ранее добавленные треки играют моментально (1–1.5 сек) БЕЗ ручного передобавления!</b>
   • Render больше НИКОГДА не сохраняется на диск.

2. 🔊 <b>УБРАН БАГ САМОВОЛЬНОГО ВОСПРОИЗВЕДЕНИЯ:</b>
   • Раньше при перезаходе в Spotify плеер твика мог принудительно включить Play, даже если трек был на паузе.
   • Теперь твик строго уважает состояние паузы Спотифая!

3. ⏱ <b>ПОФИКШЕН ПРОПУСК НАЧАЛА ТРЕКА (С 0:00!):</b>
   • Spotify слал программные тики слайдера во время загрузки, из-за чего твик перематывал первые секунды.
   • Добавлена проверка касания пальцем (<code>slider.isTracking</code>) — программные события игнорируются, трек играет <b>с самой первой миллисекунды 0:00!</b>

4. 🎤 <b>СИНХРОНИЗАЦИЯ ТЕКСТА 1:1 И МГНОВЕННЫЙ ПЕРЕХОД:</b>
   • Длительность трека теперь динамически считывается из <code>MPMediaItemPropertyPlaybackDuration</code> и AVPlayerItem — текст больше не убегает и не отстает на нестандартных песнях!
   • Подсветка строк и тайминги бегут в идеальном унисоне.
   • Тап по любой строке текста мгновенно перематывает трек ровно в эту секунду без задержек!

══════════════════════════════
📦 <b>Файл AntiCensor.dylib (v5.5.6-OTA, Build 2026110719) прикреплён ниже!</b>"""

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
                "caption": "🚀 <b>AntiCensor.dylib (v5.5.6-OTA, Build 2026110719)</b>\nАвтоочистка кеша • Старт с 0:00 • Текст синхронен 1:1 • Без фантомного плея",
                "parse_mode": "HTML"
            }
            r_doc = requests.post(f"{API_BASE}/sendDocument", data=data, files=files)
            print("sendDocument status:", r_doc.status_code, r_doc.json().get("ok"))
    else:
        print(f"Error: {dylib_path} not found!")

if __name__ == "__main__":
    dylib_path = os.path.join(os.path.dirname(__file__), "build_output", "AntiCensor.dylib")
    send_report(dylib_path)
