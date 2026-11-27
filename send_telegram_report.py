import os
import requests

TOKEN = "9229103805:AAGg97RS7iF9qfkypwjxYUTHyt883ZZpTvM"
CHAT_ID = -1004210923223
API_BASE = f"https://api.telegram.org/bot{TOKEN}"

SUMMARY_TEXT = """⚡️ <b>AntiCensor v5.6.13-OTA: ФИКС ВЫЛЕТА ЧЕРЕЗ 10 СЕКУНД</b> ⚡️

══════════════════════════════
🛠 <b>ЧТО БЫЛО И ЧТО ПОФИКШЕНО:</b>

1. 💥 <b>Вылет через ~10 секунд после старта трека</b>
   • Виноват мой экспорт HLS в .m4a через AVAssetExportSession: он запускался на 12-й секунде и валил приложение.
   • Полностью убрал AVAssetExportSession. Теперь HLS сохраняется вручную: плейлист → последовательная загрузка сегментов → склейка в один .ts/.mp4 на диске.
   • Всё обёрнуто в @try, лимит 120 МБ на трек, при ошибке — просто не кэшируем, без падений.

2. 💾 <b>Оффлайн-кэш теперь по-настоящему работает</b>
   • После первого прослушивания трек лежит на телефоне и играет без интернета.
   • mp3 — файлом, HLS — склейкой сегментов (без перекодирования на телефоне).

3. 🛡 <b>Аварийный выключатель</b>
   • В меню AntiCensor появился пункт «💾 Оффлайн-кэш: ВКЛ/ВЫКЛ» (показывает размер кэша).
   • Если что-то снова пойдёт не так — выключаешь кэш одним тапом, звук остаётся рабочим.

4. 🐞 <b>Ещё фикс:</b> убрал самозахватывающийся блок в логике кэширования (неопределённое поведение, могло тоже стрелять).

══════════════════════════════
📦 <b>Файл AntiCensor.dylib (v5.6.13-OTA, Build 2026112111) прикреплён ниже!</b>

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
                "caption": "🚀 <b>AntiCensor.dylib (v5.6.13-OTA, Build 2026112111)</b>\nСтабильный звук + оффлайн-кэш после первого прослушивания",
                "parse_mode": "HTML"
            }
            r_doc = requests.post(f"{API_BASE}/sendDocument", data=data, files=files)
            print("sendDocument status:", r_doc.status_code, r_doc.json().get("ok"))
    else:
        print(f"Error: {dylib_path} not found!")

if __name__ == "__main__":
    dylib_path = os.path.join(os.path.dirname(__file__), "build_output", "AntiCensor.dylib")
    send_report(dylib_path)
