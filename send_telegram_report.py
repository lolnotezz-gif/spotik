import os
import requests

TOKEN = "9229103805:AAGg97RS7iF9qfkypwjxYUTHyt883ZZpTvM"
CHAT_ID = -1004210923223
API_BASE = f"https://api.telegram.org/bot{TOKEN}"

SUMMARY_TEXT = """⚡️ <b>AntiCensor v5.6.2-OTA: ФИКС ЗВУКА SOUNDCLOUD (MP4→MP3) + ЗАГРУЗКА ФАЙЛОВ С УСТРОЙСТВА НА ПК И iPHONE + ФИКС ОКНА ЗАМЕНЫ!</b> ⚡️

══════════════════════════════
🛠 <b>ЧТО НАЙДЕНО И ПОФИКШЕНО:</b>

1. 🔊 <b>ГЛАВНЫЙ БАГ — ПОЧЕМУ НЕ ИГРАЛ SOUNDCLOUD (на ПК и iPhone):</b>
   • Сервер <code>backend/server.py</code> паковал AAC-потоки с SoundCloud в MP4-контейнер (<code>ftypisom</code>), но переименовывал файл в <code>.mp3</code> и отдавал как <code>audio/mpeg</code>!
   • Spotify Desktop (CEF) вообще не умеет декодировать AAC/MP4, а iOS AVPlayer сбрасывал такой файл с ошибкой.
   • <b>Исправлено:</b> Теперь и облако Render, и локальный мост на ПК отдают <b>100% настоящий MP3 (ID3 / audio/mpeg)</b> + автоматически чистят старый битый кэш.

2. 📁 <b>ЗАМЕНА ФАЙЛОМ С УСТРОЙСТВА (ПК + iPhone + СИНХРОНИЗАЦИЯ):</b>
   • <b>На iPhone:</b> После выбора файла в «Файлах» iOS ставила Spotify на паузу, из-за чего плеер AntiCensor тоже не стартовал — починил мгновенный автозапуск + добавил фоновую выгрузку файла в облако <code>/api/upload</code>, чтобы файл с айфона играл и на ПК!
   • <b>На ПК:</b> В окне замены добавлена кнопка <b>«📁 Загрузить аудиофайл с ПК (MP3 / WAV / M4A / OGG)»</b> — файл конвертируется в MP3, мгновенно играет на ПК и синхронизируется с iPhone!

3. 🧩 <b>ФИКС БАГОВ ОКНА ЗАМЕНЫ НА ПК:</b>
   • Исправлен баг <code>spotify:track:spotify:album:...</code> (раньше при ПКМ по треку мог цепляться URI альбома) — теперь достаёт строго URI/название/артиста трека (включая React fiber для серых/зацензуренных треков!) и вычищает старые битые ключи.
   • Исправлено вылезание длинной зелёной ссылки за пределы модального окна + автоматическая очистка <code>?si=...&amp;utm_...</code> хвостов SoundCloud.

══════════════════════════════
📦 <b>Файл AntiCensor.dylib (v5.6.2-OTA, Build 2026111703) прикреплён ниже!</b>"""

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
                "caption": "🚀 <b>AntiCensor.dylib (v5.6.2-OTA, Build 2026111703)</b>\nНастоящий MP3 для SoundCloud • Файлы с устройства (ПК ↔ iPhone) • Фикс окна замены",
                "parse_mode": "HTML"
            }
            r_doc = requests.post(f"{API_BASE}/sendDocument", data=data, files=files)
            print("sendDocument status:", r_doc.status_code, r_doc.json().get("ok"))
    else:
        print(f"Error: {dylib_path} not found!")

if __name__ == "__main__":
    dylib_path = os.path.join(os.path.dirname(__file__), "build_output", "AntiCensor.dylib")
    send_report(dylib_path)
