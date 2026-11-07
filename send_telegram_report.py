import os
import requests

TOKEN = "9229103805:AAGg97RS7iF9qfkypwjxYUTHyt883ZZpTvM"
CHAT_ID = -1004210923223
API_BASE = f"https://api.telegram.org/bot{TOKEN}"

SUMMARY_TEXT = """🔥 <b>ЕБАТЬ, ВСЁ ИДЁТ ПО ПЛАНУ! РАЗЪЁБ AntiCensor iOS v5.5.3-OTA</b> 🔥

«Всё летит в пизду» отменяется, нахуй! Пофиксил оба лютых бага, из-за которых треки затыкались, а SoundCloud ебал мозги 10-секундными задержками!

══════════════════════════════
💥 <b>ЧТО БЫЛО СЛОМАНО И КАК ВЫЛЕЧЕНО:</b>

1. 🚫 <b>ПОЧЕМУ ТРЕКИ НЕ ИГРАЛИ В v5.5.2:</b>
   • <i>В чём был пиздец:</i> Когда ты тапал по треку в Спотике, Spotify сначала слал пакет метаданных (название, артист) ВООБЩЕ БЕЗ <code>playbackRate</code>. Из-за параноидальной защиты от автозапуска код видел <code>!isPlaying</code>, сохранял ключ трека и молча дропал запуск плеера! Плеер оставался в <code>nil</code> и тупо молчал как рыба об лёд.
   • <i>ФИКС:</i> Ввёл жёсткое разделение — защита от автоплея теперь действует <b>строго первые 2.5 секунды при запуске приложения</b> (<code>g_isAppLaunching</code>). После старта любой клик по треку <b>сходу врубает воспроизведение без тормозов</b>! А пауза срабатывает только тогда, когда ты реально нажал на стоп!

2. ⚡ <b>СКОРОСТЬ SOUNDCLOUD (С 10 СЕКУНД ДО 1 СЕКУНДЫ):</b>
   • <i>В чём был пиздец:</i> На телефоне в РФ SoundCloud заблокирован РКН. Твик тужился и 5-7 секунд ждал ответа от дохлого <code>api-v2.soundcloud.com</code>, ловил таймаут и только потом шёл на Render. А на сервере трек ещё и заново качался без кэша в облачную папку. Итог — конские 10+ секунд задержки!
   • <i>ФИКС:</i>
     1) <b>Выкинули нахуй локальные таймауты:</b> твик теперь моментально шлёт запрос на облачный мост Render, у которого в Европе гигабитный интернет без блокировок.
     2) <b>Автосохранение в облако (Cloud Caching):</b> когда ты вставляешь ссылку с SC или когда идёт синк — сервер в фоне автоматически скачивает трек в постоянное облачное хранилище <code>/audio/sc_xxx.mp3</code> и заменяет ссылку на прямой MP3!
     3) <b>HTTP 206 Partial Content:</b> трек стримится мгновенно за 0.5–1 секунду точно так же, как и 12 треков из альбома Миры!

3. 📡 <b>ПО ПОВОДУ ОБНОВ ПО ВОЗДУХУ (OTA):</b>
   • В бесплатном Sideloadly песочница iOS блокирует загрузку чужих неподписанных dylib через <code>dlopen</code> (защита AMFI Apple). Чтобы обновляться без кабеля — в Sideloadly включи галочку <b>Wi-Fi Sideloading</b>, и комп сам зальёт свежий dylib по воздуху!

══════════════════════════════
📦 <b>Свежий AntiCensor.dylib (v5.5.3-OTA, Build 2026110716) прикреплён ниже!</b>"""

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
                "caption": "🚀 <b>AntiCensor.dylib (v5.5.3-OTA, Build 2026110716)</b>\nТреки играют моментально • SC кэшируется в облако • Старт за 1 секунду",
                "parse_mode": "HTML"
            }
            r_doc = requests.post(f"{API_BASE}/sendDocument", data=data, files=files)
            print("sendDocument status:", r_doc.status_code, r_doc.json().get("ok"))
    else:
        print(f"Error: {dylib_path} not found!")

if __name__ == "__main__":
    dylib_path = os.path.join(os.path.dirname(__file__), "build_output", "AntiCensor.dylib")
    send_report(dylib_path)
