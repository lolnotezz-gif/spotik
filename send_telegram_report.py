import os
import requests

TOKEN = "9229103805:AAGg97RS7iF9qfkypwjxYUTHyt883ZZpTvM"
CHAT_ID = -1004210923223
API_BASE = f"https://api.telegram.org/bot{TOKEN}"

SUMMARY_TEXT = """🔥 <b>AntiCensor iOS v5.5.7-OTA: МГНОВЕННЫЙ ПРЫЖОК ПО ТЕКСТУ В СПОТИФАЕ!</b> 🔥

Теперь при нажатии на ЛЮБОЙ фрагмент/строку текста в Спотифае — трек с SoundCloud или с мобилы моментально откидывает ровно в эту секунду!

══════════════════════════════
🛠 <b>ЧТО РЕАЛИЗОВАНО И ПОФИКШЕНО:</b>

1. 🎯 <b>МГНОВЕННЫЙ ПЕРЕХОД ПО НАЖАТИЮ НА ТЕКСТ В СПОТИФАЕ:</b>
   • Раньше в коде стояла глухая блокировка <code>if (!ourAudioPlayer)</code>, из-за которой Спотифай при тапе на строчку текста пытался перемотать песню, но наш плеер тупо игнорировал команду и играл дальше!
   • <b>Сделано:</b> Теперь твик на лету перехватывает тапы по тексту из Спотифая (скачки времени > 0.8 сек) через <code>NowPlayingInfo</code> и системные события.
   • Нажал на любую строчку текста в Спотифае — <b>трек с СК / с мобилы мгновенно откидывает ровно на этот фрагмент!</b>

2. 🔄 <b>НЕПРЕРЫВНАЯ СИНХРОНИЗАЦИЯ ТЕКСТА 1:1:</b>
   • В фоновом цикле каждые 0.5 сек системный ползунок Спотифая синхронизируется с точностью до миллисекунды под аудио нашего плеера.
   • Подсветка строк текста в Спотифае больше не убегает вперед и не отстает от звука!

3. 🛡 <b>ЗАЩИТА СТАРТА ПЕСНИ (С 0:00):</b>
   • Добавлен умный фильтр шума первых двух секунд — начало трека больше никогда не срезается, а реальные клики по тексту срабатывают моментально в любой точке трека!

══════════════════════════════
📦 <b>Файл AntiCensor.dylib (v5.5.7-OTA, Build 2026110720) прикреплён ниже!</b>"""

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
                "caption": "🚀 <b>AntiCensor.dylib (v5.5.7-OTA, Build 2026110720)</b>\nТап по тексту в Спотифае мгновенно откидывает трек с СК/мобилы • Синхрон 1:1",
                "parse_mode": "HTML"
            }
            r_doc = requests.post(f"{API_BASE}/sendDocument", data=data, files=files)
            print("sendDocument status:", r_doc.status_code, r_doc.json().get("ok"))
    else:
        print(f"Error: {dylib_path} not found!")

if __name__ == "__main__":
    dylib_path = os.path.join(os.path.dirname(__file__), "build_output", "AntiCensor.dylib")
    send_report(dylib_path)
