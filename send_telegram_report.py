import os
import requests

TOKEN = "9229103805:AAGg97RS7iF9qfkypwjxYUTHyt883ZZpTvM"
CHAT_ID = -1004210923223
API_BASE = f"https://api.telegram.org/bot{TOKEN}"

SUMMARY_TEXT = """⚡️ <b>AntiCensor v5.6.1-OTA: ФИКС МЁРТВОГО ДЕДЛОКА ПИТОНА + НАСТОЯЩЕЕ ДВУСТОРОННЕЕ СОПРЯЖЕНИЕ (МОБИЛКА ↔ ПК)!</b> ⚡️

══════════════════════════════
🛠 <b>ЧТО НАЙДЕНО И ПОФИКШЕНО:</b>

1. 🐍 <b>ПОЛНЫЙ АУДИТ PYTHON-БЭКЕНДА (<code>backend/server.py</code> + локальный <code>AntiCensorBridge.py</code>):</b>
   • <b>Найден критический дедлок:</b> В <code>backend/server.py</code> стоял обычный <code>threading.Lock()</code> (не реентерабельный), а функция <code>auto_cache_sc_track()</code> брала <code>sync_lock</code> и внутри вызывала <code>load_sync_db()</code>, которая снова пыталась взять тот же <code>sync_lock</code> → сервер вешал <code>/api/sync</code> намертво на 10+ минут!
   • <b>Исправлено:</b> Заменено на <code>threading.RLock()</code>, добавлены атомарные записи базы (<code>tmp + os.replace</code>), отдельные per-URL локи для SoundCloud (без порчи файлов при параллельных запросах), фильтрация <code>local://</code> и зеркалирование ключей <code>spotify:track:ID ↔ ID</code>.
   • Локальный <code>AntiCensorBridge.py</code> на ПК также полностью переписан, обновлен и перезапущен.

2. 📱➡️💻 <b>СОПРЯЖЕНИЕ МОБИЛКА → ПК:</b>
   • Раньше кнопка синхронизации на iPhone делала ТОЛЬКО скачивание (<code>GET /api/sync</code>) и НЕ отправляла твои замены на ПК! Плюс таймаут отправки был 7 сек.
   • Теперь при нажатии <b>«🌐 Сопряжение Мобилка ↔ ПК»</b>, при запуске и каждые 60 сек iPhone отправляет ВСЕ твои замены и тексты одним пакетом в облако (с таймаутом 35с и авто-ретраем).
   • На ПК исправлено сопоставление ключей по названию и «Артист - Название», а также добавлен <b>автоперехват треков по событию <code>songchange</code></b> (очередь, поиск, автоплей, Spotify Connect).

3. 💻➡️📱 <b>СОПРЯЖЕНИЕ ПК → МОБИЛКА (ОБРАТНОЕ НАПРАВЛЕНИЕ):</b>
   • При добавлении замены на ПК теперь сохраняются и отправляются в облако сразу все варианты ключей (<code>spotify:track:ID</code>, <code>ID</code>, <code>Артист - Название</code>, <code>Название</code>), чтобы iPhone находил их 100%.
   • В AntiCensor Dashboard на ПК появилась кнопка <b>«🔄 Сопряжение ПК ↔ Мобилка»</b> (отправляет все ПК-замены на iPhone и забирает все с iPhone за 1 клик) + кнопка <b>«➕ Заменить текущий трек»</b>.

══════════════════════════════
📦 <b>Файл AntiCensor.dylib (v5.6.1-OTA, Build 2026111702) прикреплён ниже!</b>"""

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
                "caption": "🚀 <b>AntiCensor.dylib (v5.6.1-OTA, Build 2026111702)</b>\nФикс дедлока Python • Двустороннее сопряжение Мобилка ↔ ПК • Автоперехват треков на ПК",
                "parse_mode": "HTML"
            }
            r_doc = requests.post(f"{API_BASE}/sendDocument", data=data, files=files)
            print("sendDocument status:", r_doc.status_code, r_doc.json().get("ok"))
    else:
        print(f"Error: {dylib_path} not found!")

if __name__ == "__main__":
    dylib_path = os.path.join(os.path.dirname(__file__), "build_output", "AntiCensor.dylib")
    send_report(dylib_path)
