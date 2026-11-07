import os
import requests

TOKEN = "9229103805:AAGg97RS7iF9qfkypwjxYUTHyt883ZZpTvM"
CHAT_ID = -1004210923223
API_BASE = f"https://api.telegram.org/bot{TOKEN}"

SUMMARY_TEXT = """⚡️ <b>AntiCensor iOS v5.5.4-OTA: ПОЛНЫЙ ФИКС И ОТКАТ ТОРМОЗОВ!</b> ⚡️

Брат, всё исправил! Откатил нахуй весь этот медленный геморрой с Render для SC и починил автоплей со скипом начала трека!

══════════════════════════════
🛠 <b>ЧТО СДЕЛАНО:</b>

1. ⚡️ <b>ВОЗВРАЩЕНА СКОРОСТЬ SOUNDCLOUD (1-2 СЕКУНДЫ ВМЕСТО 20):</b>
   • Убрал принудительный прогон через Render, который засыпал на бесплатном тарифе и давал 20 секунд задержки.
   • Твик снова резолвит SoundCloud напрямую с телефона через <code>api-v2.soundcloud.com</code> — аудиопоток подхватывается напрямую с серверов SoundCloud CDN за <b>1-2 секунды</b>, как и было раньше!
   • База данных больше не уродует ссылки в обход SC.

2. 🔇 <b>ФИКС САМОПРОИЗВОЛЬНОГО ВОСПРОИЗВЕДЕНИЯ ПРИ ПЕРЕЗАХОДЕ:</b>
   • В чём была беда: при заходе в Спотифай код ошибочно думал, что раз трек открылся — значит его надо играть, и врубал звук даже когда кнопка паузы была выключена!
   • Теперь плеер <b>железно молчит</b>, пока ты сам лично не нажмёшь Play или не тапнешь трек! При перезаходе в приложение никакой самодеятельности.

3. ⏪ <b>ФИКС ПРОПУСКА НАЧАЛА ТРЕКА:</b>
   • В чём был косяк: фоновый плеер Спотифая слал свои старые секунды, и твик перематывал наш плеер на 10-20 секунд вперёд, обрезая вступление песни!
   • Полностью вырезал этот паразитный сдвиг. Трек теперь <b>всегда начинает играть строго с 0:00</b> без необходимости кликать по первой строчке текста!

══════════════════════════════
📦 <b>Файл AntiCensor.dylib (v5.5.4-OTA, Build 2026110717) прикреплён ниже!</b>"""

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
                "caption": "🚀 <b>AntiCensor.dylib (v5.5.4-OTA, Build 2026110717)</b>\nSC играет за 1-2 сек • Без автоплея на старте • Начало трека не режется",
                "parse_mode": "HTML"
            }
            r_doc = requests.post(f"{API_BASE}/sendDocument", data=data, files=files)
            print("sendDocument status:", r_doc.status_code, r_doc.json().get("ok"))
    else:
        print(f"Error: {dylib_path} not found!")

if __name__ == "__main__":
    dylib_path = os.path.join(os.path.dirname(__file__), "build_output", "AntiCensor.dylib")
    send_report(dylib_path)
