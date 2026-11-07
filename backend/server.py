import os
import sys
import json
import re
import urllib.request
import urllib.parse
import subprocess
import threading
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn

PORT = int(os.environ.get("PORT", 8080))
CACHE_DIR = os.environ.get("CACHE_DIR", os.path.expanduser("~/.anticensor_cache"))
AUDIO_DIR = os.path.join(os.path.dirname(__file__), "audio")
os.makedirs(CACHE_DIR, exist_ok=True)
os.makedirs(AUDIO_DIR, exist_ok=True)

# Find ffmpeg binary
FFMPEG = "ffmpeg"
try:
    import imageio_ffmpeg
    FFMPEG = imageio_ffmpeg.get_ffmpeg_exe()
except Exception:
    pass

SC_CLIENT_ID = os.environ.get("SC_CLIENT_ID", "39AVoiZVrdvJEMFLH8T0c5WGshQaAPRJ")

in_progress_lock = threading.Lock()
in_progress_urls = set()

def get_target_path(clean_url):
    slug = re.sub(r'[^a-zA-Z0-9]', '_', clean_url)[-50:]
    return os.path.join(CACHE_DIR, f"{slug}.mp3")

def resolve_kugou_to_file(song_hash):
    clean_h = re.sub(r'[^a-zA-Z0-9]', '', song_hash).lower()
    target_mp3 = os.path.join(CACHE_DIR, f"kugou_{clean_h}.mp3")
    if os.path.exists(target_mp3) and os.path.getsize(target_mp3) > 50000:
        return target_mp3
    try:
        url = f"http://m.kugou.com/app/i/getSongInfo.php?cmd=playInfo&hash={clean_h}"
        req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read().decode('utf-8'))
            dl_url = data.get('url')
            if dl_url:
                tmp_out = target_mp3 + ".tmp.mp3"
                dl_req = urllib.request.Request(dl_url, headers={'User-Agent': 'Mozilla/5.0'})
                with urllib.request.urlopen(dl_req, timeout=20) as dl_resp:
                    with open(tmp_out, 'wb') as f:
                        f.write(dl_resp.read())
                if os.path.exists(tmp_out) and os.path.getsize(tmp_out) > 50000:
                    os.replace(tmp_out, target_mp3)
                    print(f"[AntiCensor] KuGou cached: {target_mp3}")
                    return target_mp3
    except Exception as e:
        print(f"[AntiCensor] KuGou resolve error for {clean_h}: {e}")
    return None

def resolve_sc_to_file(raw_url):
    url = raw_url.strip()

    # Follow redirects for on.soundcloud.com shortlinks or any shortened URLs
    if any(domain in url for domain in ["on.soundcloud.com", "t.co", "bit.ly"]):
        try:
            req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'})
            with urllib.request.urlopen(req, timeout=10) as resp:
                url = resp.geturl()
        except Exception as e:
            print("[AntiCensor] Redirect error:", e)

    clean_url = url.split("?")[0].strip().replace("m.soundcloud.com", "soundcloud.com")
    target_mp3 = get_target_path(clean_url)

    if os.path.exists(target_mp3) and os.path.getsize(target_mp3) > 50000:
        return target_mp3

    with in_progress_lock:
        if clean_url not in in_progress_urls:
            in_progress_urls.add(clean_url)

    try:
        # Check if already resolved by another concurrent worker
        if os.path.exists(target_mp3) and os.path.getsize(target_mp3) > 50000:
            return target_mp3

        # Resolve track metadata via SoundCloud API v2
        track_data = None
        api_url = f"https://api-v2.soundcloud.com/resolve?url={urllib.parse.quote(clean_url)}&client_id={SC_CLIENT_ID}"
        try:
            req = urllib.request.Request(api_url, headers={'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'})
            track_data = json.loads(urllib.request.urlopen(req, timeout=10).read().decode('utf-8'))
        except Exception as api_err:
            print(f"[AntiCensor] API v2 error for {clean_url}: {api_err}")

        # If API v2 returned no transcodings or failed, fall back to hydration parsing from HTML
        trans = track_data.get('media', {}).get('transcodings', []) if track_data else []
        track_auth = track_data.get('track_authorization') if track_data else None

        if not trans:
            try:
                html_req = urllib.request.Request(clean_url, headers={'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'})
                with urllib.request.urlopen(html_req, timeout=8) as h_resp:
                    html_text = h_resp.read().decode('utf-8', errors='ignore')
                h_matches = re.findall(r'<script>window\.__sc_hydration\s*=\s*(\[.*?\]);</script>', html_text)
                if h_matches:
                    h_json = json.loads(h_matches[0])
                    for it in h_json:
                        d = it.get('data')
                        if isinstance(d, dict) and 'media' in d:
                            trans = d.get('media', {}).get('transcodings', [])
                            track_auth = d.get('track_authorization')
                            break
            except Exception as h_err:
                print(f"[AntiCensor] Hydration parse error: {h_err}")

        if not trans:
            print(f"[AntiCensor] No transcodings found for {clean_url}")
            return None

        unenc = [x for x in trans if 'encrypted' not in x.get('format', {}).get('protocol', '') and 'skd:' not in x.get('url', '')]
        valid_trans = unenc if unenc else trans

        prog = next((x for x in valid_trans if x.get('format', {}).get('protocol') == 'progressive'), None)
        hls_trans = next((x for x in valid_trans if x.get('format', {}).get('protocol') == 'hls'), valid_trans[0])

        chosen = prog or hls_trans
        stream_api = chosen['url'] + ('&' if '?' in chosen['url'] else '?') + f'client_id={SC_CLIENT_ID}'
        if track_auth:
            stream_api += f"&track_authorization={track_auth}"

        stream_info = json.loads(urllib.request.urlopen(urllib.request.Request(stream_api, headers={'User-Agent': 'Mozilla/5.0'}), timeout=10).read().decode('utf-8'))
        media_url = stream_info['url']

        tmp_out = target_mp3 + ".tmp.mp4"
        # High speed remux without re-encoding (1-2s instead of 25s!)
        if prog:
            cmd = [FFMPEG, "-y", "-i", media_url, "-c", "copy", tmp_out]
        else:
            cmd = [FFMPEG, "-y", "-i", media_url, "-c:a", "copy", "-f", "mp4", "-movflags", "+faststart", tmp_out]

        res = subprocess.run(cmd, capture_output=True)
        if res.returncode == 0 and os.path.exists(tmp_out) and os.path.getsize(tmp_out) > 30000:
            os.replace(tmp_out, target_mp3)
            print(f"[AntiCensor] Fast remux cached: {target_mp3}")
            return target_mp3

        # Fallback to libmp3lame if copy failed
        tmp_mp3 = target_mp3 + ".tmp.mp3"
        cmd2 = [FFMPEG, "-y", "-i", media_url, "-c:a", "libmp3lame", "-q:a", "3", tmp_mp3]
        subprocess.run(cmd2, check=True, capture_output=True)
        if os.path.exists(tmp_mp3):
            os.replace(tmp_mp3, target_mp3)
            print(f"[AntiCensor] Lame fallback cached: {target_mp3}")
            return target_mp3
    except Exception as e:
        print(f"[AntiCensor] Resolve error for {clean_url}: {e}")
    finally:
        with in_progress_lock:
            in_progress_urls.discard(clean_url)

    if os.path.exists(target_mp3) and os.path.getsize(target_mp3) > 50000:
        return target_mp3
    return None

import time

SYNC_DB_FILE = os.path.join(CACHE_DIR, "sync_database.json")
sync_lock = threading.Lock()

DEFAULT_OVERRIDES = {
    "spotify:track:0bzO2aZbO7RN0tl50wsCJz": "https://spotik-in4b.onrender.com/audio/one_week_record.mp3",
    "spotify:track:0bzo2azbo7rn0tl50wscjz": "https://spotik-in4b.onrender.com/audio/one_week_record.mp3",
    "0bzO2aZbO7RN0tl50wsCJz": "https://spotik-in4b.onrender.com/audio/one_week_record.mp3",
    "one week record": "https://spotik-in4b.onrender.com/audio/one_week_record.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) - one week record": "https://spotik-in4b.onrender.com/audio/one_week_record.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) • one week record": "https://spotik-in4b.onrender.com/audio/one_week_record.mp3",
    "m1raontheblock - coll. of $hitт (vol. 0.5) - one week record": "https://spotik-in4b.onrender.com/audio/one_week_record.mp3",
    "m1raontheblock - one week record": "https://spotik-in4b.onrender.com/audio/one_week_record.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) - m1raontheblock - one week record": "https://spotik-in4b.onrender.com/audio/one_week_record.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) • m1raontheblock - one week record": "https://spotik-in4b.onrender.com/audio/one_week_record.mp3",
    "m1raontheblock - coll. of $hitт (vol. 0.5) - m1raontheblock - one week record": "https://spotik-in4b.onrender.com/audio/one_week_record.mp3",
    "spotify:track:0uWNvKc0B1OZsLMzlUzbpD": "https://spotik-in4b.onrender.com/audio/needforspeed.mp3",
    "spotify:track:0uwnvkc0b1ozslmzluzbpd": "https://spotik-in4b.onrender.com/audio/needforspeed.mp3",
    "0uWNvKc0B1OZsLMzlUzbpD": "https://spotik-in4b.onrender.com/audio/needforspeed.mp3",
    "needforspeed": "https://spotik-in4b.onrender.com/audio/needforspeed.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) - needforspeed": "https://spotik-in4b.onrender.com/audio/needforspeed.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) • needforspeed": "https://spotik-in4b.onrender.com/audio/needforspeed.mp3",
    "m1raontheblock - coll. of $hitт (vol. 0.5) - needforspeed": "https://spotik-in4b.onrender.com/audio/needforspeed.mp3",
    "m1raontheblock - needforspeed": "https://spotik-in4b.onrender.com/audio/needforspeed.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) - m1raontheblock - needforspeed": "https://spotik-in4b.onrender.com/audio/needforspeed.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) • m1raontheblock - needforspeed": "https://spotik-in4b.onrender.com/audio/needforspeed.mp3",
    "m1raontheblock - coll. of $hitт (vol. 0.5) - m1raontheblock - needforspeed": "https://spotik-in4b.onrender.com/audio/needforspeed.mp3",
    "m1raontheblock, vixi - needforspeed": "https://spotik-in4b.onrender.com/audio/needforspeed.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) - m1raontheblock, vixi - needforspeed": "https://spotik-in4b.onrender.com/audio/needforspeed.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) • m1raontheblock, vixi - needforspeed": "https://spotik-in4b.onrender.com/audio/needforspeed.mp3",
    "m1raontheblock - coll. of $hitт (vol. 0.5) - m1raontheblock, vixi - needforspeed": "https://spotik-in4b.onrender.com/audio/needforspeed.mp3",
    "spotify:track:4YsCP1lZbeMlCaUT0ONML1": "https://spotik-in4b.onrender.com/audio/senpa1.mp3",
    "spotify:track:4yscp1lzbemlcaut0onml1": "https://spotik-in4b.onrender.com/audio/senpa1.mp3",
    "4YsCP1lZbeMlCaUT0ONML1": "https://spotik-in4b.onrender.com/audio/senpa1.mp3",
    "$enpa1": "https://spotik-in4b.onrender.com/audio/senpa1.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) - $enpa1": "https://spotik-in4b.onrender.com/audio/senpa1.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) • $enpa1": "https://spotik-in4b.onrender.com/audio/senpa1.mp3",
    "m1raontheblock - coll. of $hitт (vol. 0.5) - $enpa1": "https://spotik-in4b.onrender.com/audio/senpa1.mp3",
    "senpa1": "https://spotik-in4b.onrender.com/audio/senpa1.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) - senpa1": "https://spotik-in4b.onrender.com/audio/senpa1.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) • senpa1": "https://spotik-in4b.onrender.com/audio/senpa1.mp3",
    "m1raontheblock - coll. of $hitт (vol. 0.5) - senpa1": "https://spotik-in4b.onrender.com/audio/senpa1.mp3",
    "m1raontheblock - $enpa1": "https://spotik-in4b.onrender.com/audio/senpa1.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) - m1raontheblock - $enpa1": "https://spotik-in4b.onrender.com/audio/senpa1.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) • m1raontheblock - $enpa1": "https://spotik-in4b.onrender.com/audio/senpa1.mp3",
    "m1raontheblock - coll. of $hitт (vol. 0.5) - m1raontheblock - $enpa1": "https://spotik-in4b.onrender.com/audio/senpa1.mp3",
    "m1raontheblock - senpa1": "https://spotik-in4b.onrender.com/audio/senpa1.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) - m1raontheblock - senpa1": "https://spotik-in4b.onrender.com/audio/senpa1.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) • m1raontheblock - senpa1": "https://spotik-in4b.onrender.com/audio/senpa1.mp3",
    "m1raontheblock - coll. of $hitт (vol. 0.5) - m1raontheblock - senpa1": "https://spotik-in4b.onrender.com/audio/senpa1.mp3",
    "spotify:track:6DlxijdnCniTi2jRL7xfIO": "https://spotik-in4b.onrender.com/audio/deyti.mp3",
    "spotify:track:6dlxijdncniti2jrl7xfio": "https://spotik-in4b.onrender.com/audio/deyti.mp3",
    "6DlxijdnCniTi2jRL7xfIO": "https://spotik-in4b.onrender.com/audio/deyti.mp3",
    "дейти": "https://spotik-in4b.onrender.com/audio/deyti.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) - дейти": "https://spotik-in4b.onrender.com/audio/deyti.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) • дейти": "https://spotik-in4b.onrender.com/audio/deyti.mp3",
    "m1raontheblock - coll. of $hitт (vol. 0.5) - дейти": "https://spotik-in4b.onrender.com/audio/deyti.mp3",
    "m1raontheblock - дейти": "https://spotik-in4b.onrender.com/audio/deyti.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) - m1raontheblock - дейти": "https://spotik-in4b.onrender.com/audio/deyti.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) • m1raontheblock - дейти": "https://spotik-in4b.onrender.com/audio/deyti.mp3",
    "m1raontheblock - coll. of $hitт (vol. 0.5) - m1raontheblock - дейти": "https://spotik-in4b.onrender.com/audio/deyti.mp3",
    "spotify:track:49Aozh4YVr0sYx0rkCmNNU": "https://spotik-in4b.onrender.com/audio/krysha.mp3",
    "spotify:track:49aozh4yvr0syx0rkcmnnu": "https://spotik-in4b.onrender.com/audio/krysha.mp3",
    "49Aozh4YVr0sYx0rkCmNNU": "https://spotik-in4b.onrender.com/audio/krysha.mp3",
    "крыша": "https://spotik-in4b.onrender.com/audio/krysha.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) - крыша": "https://spotik-in4b.onrender.com/audio/krysha.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) • крыша": "https://spotik-in4b.onrender.com/audio/krysha.mp3",
    "m1raontheblock - coll. of $hitт (vol. 0.5) - крыша": "https://spotik-in4b.onrender.com/audio/krysha.mp3",
    "m1raontheblock - крыша": "https://spotik-in4b.onrender.com/audio/krysha.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) - m1raontheblock - крыша": "https://spotik-in4b.onrender.com/audio/krysha.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) • m1raontheblock - крыша": "https://spotik-in4b.onrender.com/audio/krysha.mp3",
    "m1raontheblock - coll. of $hitт (vol. 0.5) - m1raontheblock - крыша": "https://spotik-in4b.onrender.com/audio/krysha.mp3",
    "m1raontheblock, vixi - крыша": "https://spotik-in4b.onrender.com/audio/krysha.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) - m1raontheblock, vixi - крыша": "https://spotik-in4b.onrender.com/audio/krysha.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) • m1raontheblock, vixi - крыша": "https://spotik-in4b.onrender.com/audio/krysha.mp3",
    "m1raontheblock - coll. of $hitт (vol. 0.5) - m1raontheblock, vixi - крыша": "https://spotik-in4b.onrender.com/audio/krysha.mp3",
    "spotify:track:22m03tWYBVctgdByCu2ohS": "https://spotik-in4b.onrender.com/audio/tvari.mp3",
    "spotify:track:22m03twybvctgdbycu2ohs": "https://spotik-in4b.onrender.com/audio/tvari.mp3",
    "22m03tWYBVctgdByCu2ohS": "https://spotik-in4b.onrender.com/audio/tvari.mp3",
    "фантастические твари": "https://spotik-in4b.onrender.com/audio/tvari.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) - фантастические твари": "https://spotik-in4b.onrender.com/audio/tvari.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) • фантастические твари": "https://spotik-in4b.onrender.com/audio/tvari.mp3",
    "m1raontheblock - coll. of $hitт (vol. 0.5) - фантастические твари": "https://spotik-in4b.onrender.com/audio/tvari.mp3",
    "фантастические твари - ver.2": "https://spotik-in4b.onrender.com/audio/tvari.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) - фантастические твари - ver.2": "https://spotik-in4b.onrender.com/audio/tvari.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) • фантастические твари - ver.2": "https://spotik-in4b.onrender.com/audio/tvari.mp3",
    "m1raontheblock - coll. of $hitт (vol. 0.5) - фантастические твари - ver.2": "https://spotik-in4b.onrender.com/audio/tvari.mp3",
    "фантастические твари (ver.2)": "https://spotik-in4b.onrender.com/audio/tvari.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) - фантастические твари (ver.2)": "https://spotik-in4b.onrender.com/audio/tvari.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) • фантастические твари (ver.2)": "https://spotik-in4b.onrender.com/audio/tvari.mp3",
    "m1raontheblock - coll. of $hitт (vol. 0.5) - фантастические твари (ver.2)": "https://spotik-in4b.onrender.com/audio/tvari.mp3",
    "фантастические твари ver 2": "https://spotik-in4b.onrender.com/audio/tvari.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) - фантастические твари ver 2": "https://spotik-in4b.onrender.com/audio/tvari.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) • фантастические твари ver 2": "https://spotik-in4b.onrender.com/audio/tvari.mp3",
    "m1raontheblock - coll. of $hitт (vol. 0.5) - фантастические твари ver 2": "https://spotik-in4b.onrender.com/audio/tvari.mp3",
    "m1raontheblock - фантастические твари": "https://spotik-in4b.onrender.com/audio/tvari.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) - m1raontheblock - фантастические твари": "https://spotik-in4b.onrender.com/audio/tvari.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) • m1raontheblock - фантастические твари": "https://spotik-in4b.onrender.com/audio/tvari.mp3",
    "m1raontheblock - coll. of $hitт (vol. 0.5) - m1raontheblock - фантастические твари": "https://spotik-in4b.onrender.com/audio/tvari.mp3",
    "m1raontheblock - фантастические твари - ver.2": "https://spotik-in4b.onrender.com/audio/tvari.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) - m1raontheblock - фантастические твари - ver.2": "https://spotik-in4b.onrender.com/audio/tvari.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) • m1raontheblock - фантастические твари - ver.2": "https://spotik-in4b.onrender.com/audio/tvari.mp3",
    "m1raontheblock - coll. of $hitт (vol. 0.5) - m1raontheblock - фантастические твари - ver.2": "https://spotik-in4b.onrender.com/audio/tvari.mp3",
    "m1raontheblock, vixi, wzcqq - фантастические твари (ver.2)": "https://spotik-in4b.onrender.com/audio/tvari.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) - m1raontheblock, vixi, wzcqq - фантастические твари (ver.2)": "https://spotik-in4b.onrender.com/audio/tvari.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) • m1raontheblock, vixi, wzcqq - фантастические твари (ver.2)": "https://spotik-in4b.onrender.com/audio/tvari.mp3",
    "m1raontheblock - coll. of $hitт (vol. 0.5) - m1raontheblock, vixi, wzcqq - фантастические твари (ver.2)": "https://spotik-in4b.onrender.com/audio/tvari.mp3",
    "spotify:track:0efigJN3XSbD3xvjDLSCYY": "https://spotik-in4b.onrender.com/audio/ya_ne_vinovat.mp3",
    "spotify:track:0efigjn3xsbd3xvjdlscyy": "https://spotik-in4b.onrender.com/audio/ya_ne_vinovat.mp3",
    "0efigJN3XSbD3xvjDLSCYY": "https://spotik-in4b.onrender.com/audio/ya_ne_vinovat.mp3",
    "я не виноват что больше": "https://spotik-in4b.onrender.com/audio/ya_ne_vinovat.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) - я не виноват что больше": "https://spotik-in4b.onrender.com/audio/ya_ne_vinovat.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) • я не виноват что больше": "https://spotik-in4b.onrender.com/audio/ya_ne_vinovat.mp3",
    "m1raontheblock - coll. of $hitт (vol. 0.5) - я не виноват что больше": "https://spotik-in4b.onrender.com/audio/ya_ne_vinovat.mp3",
    "я не виноват что... больше": "https://spotik-in4b.onrender.com/audio/ya_ne_vinovat.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) - я не виноват что... больше": "https://spotik-in4b.onrender.com/audio/ya_ne_vinovat.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) • я не виноват что... больше": "https://spotik-in4b.onrender.com/audio/ya_ne_vinovat.mp3",
    "m1raontheblock - coll. of $hitт (vol. 0.5) - я не виноват что... больше": "https://spotik-in4b.onrender.com/audio/ya_ne_vinovat.mp3",
    "m1raontheblock - я не виноват что больше": "https://spotik-in4b.onrender.com/audio/ya_ne_vinovat.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) - m1raontheblock - я не виноват что больше": "https://spotik-in4b.onrender.com/audio/ya_ne_vinovat.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) • m1raontheblock - я не виноват что больше": "https://spotik-in4b.onrender.com/audio/ya_ne_vinovat.mp3",
    "m1raontheblock - coll. of $hitт (vol. 0.5) - m1raontheblock - я не виноват что больше": "https://spotik-in4b.onrender.com/audio/ya_ne_vinovat.mp3",
    "m1raontheblock - я не виноват что... больше": "https://spotik-in4b.onrender.com/audio/ya_ne_vinovat.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) - m1raontheblock - я не виноват что... больше": "https://spotik-in4b.onrender.com/audio/ya_ne_vinovat.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) • m1raontheblock - я не виноват что... больше": "https://spotik-in4b.onrender.com/audio/ya_ne_vinovat.mp3",
    "m1raontheblock - coll. of $hitт (vol. 0.5) - m1raontheblock - я не виноват что... больше": "https://spotik-in4b.onrender.com/audio/ya_ne_vinovat.mp3",
    "spotify:track:5JsbDzwDiKjCuNGh7KE2Ja": "https://spotik-in4b.onrender.com/audio/fuckit.mp3",
    "spotify:track:5jsbdzwdikjcungh7ke2ja": "https://spotik-in4b.onrender.com/audio/fuckit.mp3",
    "5JsbDzwDiKjCuNGh7KE2Ja": "https://spotik-in4b.onrender.com/audio/fuckit.mp3",
    "fuck it": "https://spotik-in4b.onrender.com/audio/fuckit.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) - fuck it": "https://spotik-in4b.onrender.com/audio/fuckit.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) • fuck it": "https://spotik-in4b.onrender.com/audio/fuckit.mp3",
    "m1raontheblock - coll. of $hitт (vol. 0.5) - fuck it": "https://spotik-in4b.onrender.com/audio/fuckit.mp3",
    "m1raontheblock - fuck it": "https://spotik-in4b.onrender.com/audio/fuckit.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) - m1raontheblock - fuck it": "https://spotik-in4b.onrender.com/audio/fuckit.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) • m1raontheblock - fuck it": "https://spotik-in4b.onrender.com/audio/fuckit.mp3",
    "m1raontheblock - coll. of $hitт (vol. 0.5) - m1raontheblock - fuck it": "https://spotik-in4b.onrender.com/audio/fuckit.mp3",
    "m1raontheblock, vixi - fuck it": "https://spotik-in4b.onrender.com/audio/fuckit.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) - m1raontheblock, vixi - fuck it": "https://spotik-in4b.onrender.com/audio/fuckit.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) • m1raontheblock, vixi - fuck it": "https://spotik-in4b.onrender.com/audio/fuckit.mp3",
    "m1raontheblock - coll. of $hitт (vol. 0.5) - m1raontheblock, vixi - fuck it": "https://spotik-in4b.onrender.com/audio/fuckit.mp3",
    "spotify:track:1PbTwCZ4vihqw5bZc42Suj": "https://spotik-in4b.onrender.com/audio/shake_your_ass.mp3",
    "spotify:track:1pbtwcz4vihqw5bzc42suj": "https://spotik-in4b.onrender.com/audio/shake_your_ass.mp3",
    "1PbTwCZ4vihqw5bZc42Suj": "https://spotik-in4b.onrender.com/audio/shake_your_ass.mp3",
    "$hake your a$$": "https://spotik-in4b.onrender.com/audio/shake_your_ass.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) - $hake your a$$": "https://spotik-in4b.onrender.com/audio/shake_your_ass.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) • $hake your a$$": "https://spotik-in4b.onrender.com/audio/shake_your_ass.mp3",
    "m1raontheblock - coll. of $hitт (vol. 0.5) - $hake your a$$": "https://spotik-in4b.onrender.com/audio/shake_your_ass.mp3",
    "shake your ass": "https://spotik-in4b.onrender.com/audio/shake_your_ass.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) - shake your ass": "https://spotik-in4b.onrender.com/audio/shake_your_ass.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) • shake your ass": "https://spotik-in4b.onrender.com/audio/shake_your_ass.mp3",
    "m1raontheblock - coll. of $hitт (vol. 0.5) - shake your ass": "https://spotik-in4b.onrender.com/audio/shake_your_ass.mp3",
    "m1raontheblock - $hake your a$$": "https://spotik-in4b.onrender.com/audio/shake_your_ass.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) - m1raontheblock - $hake your a$$": "https://spotik-in4b.onrender.com/audio/shake_your_ass.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) • m1raontheblock - $hake your a$$": "https://spotik-in4b.onrender.com/audio/shake_your_ass.mp3",
    "m1raontheblock - coll. of $hitт (vol. 0.5) - m1raontheblock - $hake your a$$": "https://spotik-in4b.onrender.com/audio/shake_your_ass.mp3",
    "m1raontheblock - shake your ass": "https://spotik-in4b.onrender.com/audio/shake_your_ass.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) - m1raontheblock - shake your ass": "https://spotik-in4b.onrender.com/audio/shake_your_ass.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) • m1raontheblock - shake your ass": "https://spotik-in4b.onrender.com/audio/shake_your_ass.mp3",
    "m1raontheblock - coll. of $hitт (vol. 0.5) - m1raontheblock - shake your ass": "https://spotik-in4b.onrender.com/audio/shake_your_ass.mp3",
    "spotify:track:02NrEHtVoV0QOGxsQHJ0id": "https://spotik-in4b.onrender.com/audio/son.mp3",
    "spotify:track:02nrehtvov0qogxsqhj0id": "https://spotik-in4b.onrender.com/audio/son.mp3",
    "02NrEHtVoV0QOGxsQHJ0id": "https://spotik-in4b.onrender.com/audio/son.mp3",
    "сон": "https://spotik-in4b.onrender.com/audio/son.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) - сон": "https://spotik-in4b.onrender.com/audio/son.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) • сон": "https://spotik-in4b.onrender.com/audio/son.mp3",
    "m1raontheblock - coll. of $hitт (vol. 0.5) - сон": "https://spotik-in4b.onrender.com/audio/son.mp3",
    "m1raontheblock - сон": "https://spotik-in4b.onrender.com/audio/son.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) - m1raontheblock - сон": "https://spotik-in4b.onrender.com/audio/son.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) • m1raontheblock - сон": "https://spotik-in4b.onrender.com/audio/son.mp3",
    "m1raontheblock - coll. of $hitт (vol. 0.5) - m1raontheblock - сон": "https://spotik-in4b.onrender.com/audio/son.mp3",
    "spotify:track:035FY0eysDZd9akX73iKok": "https://spotik-in4b.onrender.com/audio/notime.mp3",
    "spotify:track:035fy0eysdzd9akx73ikok": "https://spotik-in4b.onrender.com/audio/notime.mp3",
    "035FY0eysDZd9akX73iKok": "https://spotik-in4b.onrender.com/audio/notime.mp3",
    "notime": "https://spotik-in4b.onrender.com/audio/notime.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) - notime": "https://spotik-in4b.onrender.com/audio/notime.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) • notime": "https://spotik-in4b.onrender.com/audio/notime.mp3",
    "m1raontheblock - coll. of $hitт (vol. 0.5) - notime": "https://spotik-in4b.onrender.com/audio/notime.mp3",
    "m1raontheblock - notime": "https://spotik-in4b.onrender.com/audio/notime.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) - m1raontheblock - notime": "https://spotik-in4b.onrender.com/audio/notime.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) • m1raontheblock - notime": "https://spotik-in4b.onrender.com/audio/notime.mp3",
    "m1raontheblock - coll. of $hitт (vol. 0.5) - m1raontheblock - notime": "https://spotik-in4b.onrender.com/audio/notime.mp3",
    "spotify:track:0qitLkJ4pa1MkHQ1sCoJh1": "https://spotik-in4b.onrender.com/audio/eyforiya.mp3",
    "spotify:track:0qitlkj4pa1mkhq1scojh1": "https://spotik-in4b.onrender.com/audio/eyforiya.mp3",
    "0qitLkJ4pa1MkHQ1sCoJh1": "https://spotik-in4b.onrender.com/audio/eyforiya.mp3",
    "эйфория": "https://spotik-in4b.onrender.com/audio/eyforiya.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) - эйфория": "https://spotik-in4b.onrender.com/audio/eyforiya.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) • эйфория": "https://spotik-in4b.onrender.com/audio/eyforiya.mp3",
    "m1raontheblock - coll. of $hitт (vol. 0.5) - эйфория": "https://spotik-in4b.onrender.com/audio/eyforiya.mp3",
    "эйфория - bonus track": "https://spotik-in4b.onrender.com/audio/eyforiya.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) - эйфория - bonus track": "https://spotik-in4b.onrender.com/audio/eyforiya.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) • эйфория - bonus track": "https://spotik-in4b.onrender.com/audio/eyforiya.mp3",
    "m1raontheblock - coll. of $hitт (vol. 0.5) - эйфория - bonus track": "https://spotik-in4b.onrender.com/audio/eyforiya.mp3",
    "m1raontheblock - эйфория": "https://spotik-in4b.onrender.com/audio/eyforiya.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) - m1raontheblock - эйфория": "https://spotik-in4b.onrender.com/audio/eyforiya.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) • m1raontheblock - эйфория": "https://spotik-in4b.onrender.com/audio/eyforiya.mp3",
    "m1raontheblock - coll. of $hitт (vol. 0.5) - m1raontheblock - эйфория": "https://spotik-in4b.onrender.com/audio/eyforiya.mp3",
    "m1raontheblock - эйфория - bonus track": "https://spotik-in4b.onrender.com/audio/eyforiya.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) - m1raontheblock - эйфория - bonus track": "https://spotik-in4b.onrender.com/audio/eyforiya.mp3",
    "m1raontheblock • coll. of $hitт (vol. 0.5) • m1raontheblock - эйфория - bonus track": "https://spotik-in4b.onrender.com/audio/eyforiya.mp3",
    "m1raontheblock - coll. of $hitт (vol. 0.5) - m1raontheblock - эйфория - bonus track": "https://spotik-in4b.onrender.com/audio/eyforiya.mp3",
    "spotify:track:2nryvrkn55a0leqvd2eduq": "https://on.soundcloud.com/toxh9rgoOq8q9SJ5xt",
    "big baby tape • dragonborn • flip phone twerk": "https://on.soundcloud.com/toxh9rgoOq8q9SJ5xt",
    "big baby tape • dragonborn - flip phone twerk": "https://on.soundcloud.com/toxh9rgoOq8q9SJ5xt",
    "flip phone twerk": "https://on.soundcloud.com/toxh9rgoOq8q9SJ5xt",
    "spotify:track:1vqfh4jra1tfndlhuan5ne": "https://on.soundcloud.com/YiLKhavIH9btKwTbIf",
    "стеклянный": "https://on.soundcloud.com/YiLKhavIH9btKwTbIf",
    "163onmyneck • grow guide 3 • стеклянный": "https://on.soundcloud.com/YiLKhavIH9btKwTbIf",
    "163onmyneck • grow guide 3 - стеклянный": "https://on.soundcloud.com/YiLKhavIH9btKwTbIf"
}

def load_sync_db():
    with sync_lock:
        db = {"overrides": dict(DEFAULT_OVERRIDES), "lyrics": {}, "updated_at": 0}
        if os.path.exists(SYNC_DB_FILE):
            try:
                with open(SYNC_DB_FILE, "r", encoding="utf-8") as f:
                    disk_db = json.load(f)
                    if "overrides" in disk_db and isinstance(disk_db["overrides"], dict):
                        db["overrides"].update(disk_db["overrides"])
                    if "lyrics" in disk_db and isinstance(disk_db["lyrics"], dict):
                        db["lyrics"].update(disk_db["lyrics"])
                    if "updated_at" in disk_db:
                        db["updated_at"] = disk_db["updated_at"]
            except Exception:
                pass
        return db

def save_sync_db(db):
    with sync_lock:
        try:
            with open(SYNC_DB_FILE, "w", encoding="utf-8") as f:
                json.dump(db, f, ensure_ascii=False, indent=2)
        except Exception as e:
            print("[AntiCensor] Save sync DB error:", e)

class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True

class AudioHandler(BaseHTTPRequestHandler):
    def send_cors(self):
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, HEAD, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Range, Content-Type, Authorization')

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_cors()
        self.end_headers()

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == '/api/sync':
            length = int(self.headers.get('Content-Length', 0))
            body = self.rfile.read(length).decode('utf-8')
            try:
                payload = json.loads(body)
                db = load_sync_db()
                if "overrides" in payload and isinstance(payload["overrides"], dict):
                    for k, v in payload["overrides"].items():
                        if v and len(str(v).strip()) > 0:
                            db["overrides"][k] = v
                        elif k in db["overrides"]:
                            del db["overrides"][k]
                if "lyrics" in payload and isinstance(payload["lyrics"], dict):
                    for k, v in payload["lyrics"].items():
                        if v and len(str(v).strip()) > 0:
                            db["lyrics"][k] = v
                        elif k in db["lyrics"]:
                            del db["lyrics"][k]
                db["updated_at"] = time.time()
                save_sync_db(db)
                self.send_response(200)
                self.send_cors()
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                if not is_head:
                    self.wfile.write(json.dumps(db).encode('utf-8'))
                return
            except Exception as e:
                self.send_response(400)
                self.send_cors()
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({"error": str(e)}).encode('utf-8'))
                return

        self.send_response(404)
        self.send_cors()
        self.end_headers()

    def do_HEAD(self):
        self.handle_get_or_head(is_head=True)

    def do_GET(self):
        self.handle_get_or_head(is_head=False)

    def handle_get_or_head(self, is_head=False):
        parsed = urllib.parse.urlparse(self.path)
        params = urllib.parse.parse_qs(parsed.query)

        if parsed.path == '/api/sync':
            db = load_sync_db()
            self.send_response(200)
            self.send_cors()
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            if not is_head:
                    self.wfile.write(json.dumps(db).encode('utf-8'))
            return

        if parsed.path == '/health' or parsed.path == '/':
            self.send_response(200)
            self.send_cors()
            self.send_header('Content-Type', 'text/plain')
            self.end_headers()
            if not is_head:
                self.wfile.write(b"AntiCensor Cloud Bridge: OK")
            return

        if parsed.path == '/preload' and 'url' in params:
            sc_url = params['url'][0]
            threading.Thread(target=resolve_sc_to_file, args=(sc_url,), daemon=True).start()
            self.send_response(200)
            self.send_cors()
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            if not is_head:
                self.wfile.write(b'{"status":"started"}')
            return

        if parsed.path == '/status' and 'url' in params:
            sc_url = params['url'][0]
            clean_url = sc_url.split("?")[0].strip()
            target_mp3 = get_target_path(clean_url)
            is_ready = os.path.exists(target_mp3) and os.path.getsize(target_mp3) > 100000
            self.send_response(200)
            self.send_cors()
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            if not is_head:
                self.wfile.write(json.dumps({"ready": bool(is_ready)}).encode('utf-8'))
            return

        file_to_stream = None
        if parsed.path.startswith('/audio/'):
            filename = os.path.basename(parsed.path)
            candidate = os.path.join(AUDIO_DIR, filename)
            if os.path.exists(candidate) and os.path.isfile(candidate):
                file_to_stream = candidate
        elif parsed.path == '/kugou' and 'hash' in params:
            file_to_stream = resolve_kugou_to_file(params['hash'][0])
        elif parsed.path == '/sc' and 'url' in params:
            try:
                sc_url = params['url'][0]
                file_to_stream = resolve_sc_to_file(sc_url)
            except Exception as e:
                print("[AntiCensor] SC Resolve Error:", e)

        if not file_to_stream or not os.path.exists(file_to_stream):
            self.send_response(404)
            self.send_cors()
            self.end_headers()
            return

        file_size = os.path.getsize(file_to_stream)
        range_header = self.headers.get('Range')

        try:
            # Handle HTTP 206 Partial Content (required for instant scrub & lyrics click)
            if range_header:
                match = re.search(r'bytes=(\d+)-(\d*)', range_header)
                if match:
                    start = int(match.group(1))
                    end = int(match.group(2)) if match.group(2) else file_size - 1
                    end = min(end, file_size - 1)
                    length = end - start + 1

                    self.send_response(206)
                    self.send_cors()
                    ct = 'audio/mp4' if file_to_stream.endswith(('.mp4', '.m4a')) else 'audio/mpeg'
                    self.send_header('Content-Type', ct)
                    self.send_header('Content-Range', f'bytes {start}-{end}/{file_size}')
                    self.send_header('Content-Length', str(length))
                    self.send_header('Accept-Ranges', 'bytes')
                    self.end_headers()

                    if not is_head:
                        with open(file_to_stream, 'rb') as f:
                            f.seek(start)
                            self.wfile.write(f.read(length))
                    return

            self.send_response(200)
            self.send_cors()
            ct = 'audio/mp4' if file_to_stream.endswith(('.mp4', '.m4a')) else 'audio/mpeg'
            self.send_header('Content-Type', ct)
            self.send_header('Content-Length', str(file_size))
            self.send_header('Accept-Ranges', 'bytes')
            self.end_headers()

            if not is_head:
                with open(file_to_stream, 'rb') as f:
                    self.wfile.write(f.read())
        except (ConnectionResetError, BrokenPipeError, ConnectionAbortedError):
            pass

import time as _time

def _keepalive_pinger():
    """Ping /health every 10 minutes to prevent Render free-tier sleep."""
    _time.sleep(60)
    while True:
        try:
            import urllib.request as _ureq
            _ureq.urlopen("http://127.0.0.1:" + str(PORT) + "/health", timeout=5)
        except Exception:
            pass
        _time.sleep(600)

if __name__ == '__main__':
    server = ThreadedHTTPServer(('0.0.0.0', PORT), AudioHandler)
    print(f"[AntiCensor] Cloud Bridge listening on 0.0.0.0:{PORT}")
    threading.Thread(target=_keepalive_pinger, daemon=True).start()
    server.serve_forever()