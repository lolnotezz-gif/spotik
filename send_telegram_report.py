import os
import requests

TOKEN = "9229103805:AAGg97RS7iF9qfkypwjxYUTHyt883ZZpTvM"
CHAT_ID = -1004210923223
API_BASE = f"https://api.telegram.org/bot{TOKEN}"

SUMMARY_TEXT = """🔥 <b>AntiCensor iOS v5.5.8-OTA: ИЗОЛЯЦИЯ ТЕКСТА И ФИКС ЛОЖНЫХ ПЕРЕХОДОВ!</b> 🔥

Пофиксил баг, когда нажатие на строчку текста в песне переключало на совершенно другой трек (например, на ЧЁТНЫЙ)!

══════════════════════════════
🛠 <b>В ЧЁМ БЫЛ БАГ И ЧТО СДЕЛАНО:</b>

1. 🚫 <b>УБРАНО ЛОЖНОЕ СОВПАДЕНИЕ ПО СЛОВАМ ИЗ ТЕКСТА:</b>
   • В распознавателе треков альбома стояло совпадение по слову <code>"эйфория"</code>.
   • В песне <b>Кишлак — «Кодировка»</b> есть строчка: <i>«Я уже трезвый неделю, и у меня от этого началась эйфория»</i>.
   • Когда ты нажимал на эту строчку текста — твик ошибочно думал, что ты нажал на трек <b>«ЧЁТНЫЙ - Bonus Track»</b>, и переключал воспроизведение на него!
   • <b>Сделано:</b> Вырезал все случайные слова. Добавил строжайший лимит длины названия трека (макс 35 символов) — ни одна строка текста песни больше физически не сможет совпасть с названием трека!

2. 🛡 <b>СТРОЖАЙШАЯ ИЗОЛЯЦИЯ ЭКРАНА ТЕКСТА:</b>
   • Ячейки экрана текста (Lyrics) и экрана Now Playing теперь <b>наглухо защищены</b> от перехвата жестов альбома.
   • Обработка нажатий альбома теперь включается <b>ТОЛЬКО</b> на самом экране альбома <code>Coll. of $hiTт</code> и никогда не лезет в текст песен!

3. 🎯 <b>ПЕРЕХОД ПО ТЕКСТУ РАБОТАЕТ В ШТАТНОМ РЕЖИМЕ:</b>
   • Тап по любой строчке текста песни перематывает трек ровно в эту секунду, не переключая саму песню!

══════════════════════════════
📦 <b>Файл AntiCensor.dylib (v5.5.8-OTA, Build 2026110801) прикреплён ниже!</b>"""

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
                "caption": "🚀 <b>AntiCensor.dylib (v5.5.8-OTA, Build 2026110801)</b>\nФикс ложного переключения по тексту • Изоляция текста от ячеек альбома",
                "parse_mode": "HTML"
            }
            r_doc = requests.post(f"{API_BASE}/sendDocument", data=data, files=files)
            print("sendDocument status:", r_doc.status_code, r_doc.json().get("ok"))
    else:
        print(f"Error: {dylib_path} not found!")

if __name__ == "__main__":
    dylib_path = os.path.join(os.path.dirname(__file__), "build_output", "AntiCensor.dylib")
    send_report(dylib_path)
