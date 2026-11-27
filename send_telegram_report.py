import os
import requests

TOKEN = "9229103805:AAGg97RS7iF9qfkypwjxYUTHyt883ZZpTvM"
CHAT_ID = -1004210923223
API_BASE = f"https://api.telegram.org/bot{TOKEN}"

SUMMARY_TEXT = """⚡️ <b>AntiCensor v5.6.8-OTA: ПОЛНОЕ УДАЛЕНИЕ ЗАМЕН + ЧУЖИЕ ТРЕКИ + МГНОВЕННЫЙ ТАП ПО ТЕКСТУ!</b> ⚡️

══════════════════════════════
🛠 <b>ЧТО ПОФИКШЕНО:</b>

1. 🗑 <b>ЗАМЕНУ ТЕПЕРЬ МОЖНО УДАЛИТЬ:</b>
   • Замены с SoundCloud/файла раньше «возвращались» после удаления (встроенные и облачные правила воскрешали их).
   • Добавлен persistent-блоклист: удалённая замена больше не восстанавливается.

2. 🎯 <b>ЧУЖИЕ ЗАМЕНЫ НЕ ПОДВЯЗЫВАЮТСЯ:</b>
   • К трекам, которые ты не менял, больше не цепляется замена по совпадению названия — её можно удалить, и она не возвращается.

3. 📝 <b>ТЕКСТЫ СРАЗУ ПЕРЕМАТЫВАЮТ:</b>
   • Тап по строке текста мгновенно прыгает на нужный тайминг (убрана 2-сек блокировка при открытии экрана + быстрее seek).

══════════════════════════════
📦 <b>Файл AntiCensor.dylib (v5.6.8-OTA, Build 2026112106) прикреплён ниже!</b>"""

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
                "caption": "🚀 <b>AntiCensor.dylib (v5.6.8-OTA, Build 2026112106)</b>\nУдаление замен навсегда, без чужих привязок, мгновенная перемотка по тексту",
                "parse_mode": "HTML"
            }
            r_doc = requests.post(f"{API_BASE}/sendDocument", data=data, files=files)
            print("sendDocument status:", r_doc.status_code, r_doc.json().get("ok"))
    else:
        print(f"Error: {dylib_path} not found!")

if __name__ == "__main__":
    dylib_path = os.path.join(os.path.dirname(__file__), "build_output", "AntiCensor.dylib")
    send_report(dylib_path)
