import os
import sys
import json
import re
import time
import hashlib
import unicodedata
import urllib.request
import urllib.parse
import subprocess
import threading
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn

PORT = int(os.environ.get("PORT", 8080))
CACHE_DIR = os.environ.get("CACHE_DIR", os.path.expanduser("~/.anticensor_cache"))
AUDIO_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "audio")
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
PUBLIC_BASE_URL = os.environ.get("RENDER_EXTERNAL_URL", "https://spotik-in4b.onrender.com").rstrip("/")

# Per-URL locks prevent concurrent ffmpeg corruption on the same SoundCloud track
url_locks_guard = threading.Lock()
url_locks = {}

def get_url_lock(clean_url):
    with url_locks_guard:
        lock = url_locks.get(clean_url)
        if lock is None:
            lock = threading.Lock()
            url_locks[clean_url] = lock
        return lock

# Reentrant lock prevents ANY self-deadlock between load/save/merge/auto_cache!
SYNC_DB_FILE = os.path.join(CACHE_DIR, "sync_database.json")
sync_lock = threading.RLock()
_sync_db_cache = None

def normalize_sync_key(key):
    if not isinstance(key, str):
        return ""
    s = key.strip().lower()
    s = unicodedata.normalize("NFC", s)
    s = re.sub(r'[…•·—–\u00a0]+|\.\.\.', ' ', s)
    s = re.sub(r'\s+', ' ', s).strip()
    if s.endswith(" - remastered"):
        s = s[:-len(" - remastered")].strip()
    return s

def _tombstone_variants(raw_key):
    """Все варианты ключа, которыми трек мог быть сохранён (uri/id/title/artist-title)."""
    if not isinstance(raw_key, str):
        return []
    base = raw_key.strip()
    if len(base) < 2:
        return []
    variants = {base, normalize_sync_key(base)}
    low = base.lower()
    if low.startswith("spotify:track:"):
        tid = base.split(":")[-1].strip()
        if len(tid) >= 10:
            variants.add(tid)
            variants.add(tid.lower())
    return [v for v in variants if isinstance(v, str) and len(v) >= 2]

def _scrub_tombstoned(mapping, tombstones):
    """Удаляет из mapping все ключи, помеченные как удалённые (включая builtin)."""
    if not tombstones:
        return 0
    removed = 0
    for k in list(mapping.keys()):
        if k in tombstones or normalize_sync_key(k) in tombstones:
            del mapping[k]
            removed += 1
    return removed

def get_target_path(clean_url, bitrate=192):
    slug = re.sub(r'[^a-zA-Z0-9]', '_', clean_url)[-50:].strip('_')
    return os.path.join(AUDIO_DIR, f"sc_{slug}_{bitrate}.mp3")

def auto_cache_sc_track(track_key, sc_url):
    try:
        if not sc_url or not isinstance(sc_url, str):
            return
        if sc_url.startswith("local://") or "/audio/" in sc_url:
            return
        mp3_path = resolve_sc_to_file(sc_url)
        if mp3_path and os.path.exists(mp3_path) and os.path.getsize(mp3_path) > 30000:
            filename = os.path.basename(mp3_path)
            cloud_url = f"{PUBLIC_BASE_URL}/audio/{filename}"
            with sync_lock:
                db = load_sync_db()
                changed = False
                # Update track_key and any sibling keys pointing to the same SoundCloud URL
                if track_key and db["overrides"].get(track_key) in (None, sc_url):
                    db["overrides"][track_key] = cloud_url
                    changed = True
                for k, v in list(db["overrides"].items()):
                    if v == sc_url:
                        db["overrides"][k] = cloud_url
                        changed = True
                if changed:
                    db["updated_at"] = time.time()
                    save_sync_db(db)
            print(f"[AntiCensor] Auto-cached {track_key} -> {cloud_url}", flush=True)
    except Exception as e:
        print(f"[AntiCensor] Auto-cache error for {track_key}: {e}", flush=True)

def resolve_kugou_to_file(song_hash):
    clean_h = re.sub(r'[^a-zA-Z0-9]', '', song_hash).lower()
    target_mp3 = os.path.join(CACHE_DIR, f"kugou_{clean_h}.mp3")
    if os.path.exists(target_mp3) and os.path.getsize(target_mp3) > 50000:
        return target_mp3
    with get_url_lock(f"kugou:{clean_h}"):
        if os.path.exists(target_mp3) and os.path.getsize(target_mp3) > 50000:
            return target_mp3
        try:
            url = f"http://m.kugou.com/app/i/getSongInfo.php?cmd=playInfo&hash={clean_h}"
            req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
            with urllib.request.urlopen(req, timeout=10) as resp:
                data = json.loads(resp.read().decode('utf-8'))
                dl_url = data.get('url')
                if dl_url:
                    tmp_out = f"{target_mp3}.{threading.get_ident()}.tmp.mp3"
                    dl_req = urllib.request.Request(dl_url, headers={'User-Agent': 'Mozilla/5.0'})
                    with urllib.request.urlopen(dl_req, timeout=20) as dl_resp:
                        with open(tmp_out, 'wb') as f:
                            f.write(dl_resp.read())
                    if os.path.exists(tmp_out) and os.path.getsize(tmp_out) > 50000:
                        os.replace(tmp_out, target_mp3)
                        print(f"[AntiCensor] KuGou cached: {target_mp3}", flush=True)
                        return target_mp3
                    elif os.path.exists(tmp_out):
                        try:
                            os.remove(tmp_out)
                        except OSError:
                            pass
        except Exception as e:
            print(f"[AntiCensor] KuGou resolve error for {clean_h}: {e}", flush=True)
    return None

def is_real_mp3(path):
    """Verify file is a real MP3 stream (NOT an MP4/AAC container disguised as .mp3!)."""
    try:
        if not os.path.exists(path) or os.path.getsize(path) < 15000:
            return False
        with open(path, 'rb') as f:
            head = f.read(16)
        # Reject MP4/M4A ('ftyp'), Ogg, RIFF/WAV disguised as .mp3
        if b'ftyp' in head or head.startswith((b'OggS', b'RIFF', b'fLaC')):
            return False
        return True
    except Exception:
        return False

def detect_content_type(path):
    try:
        with open(path, 'rb') as f:
            head = f.read(16)
        if b'ftyp' in head:
            return 'audio/mp4'
        if head.startswith(b'OggS'):
            return 'audio/ogg'
        if head.startswith(b'RIFF'):
            return 'audio/wav'
        if head.startswith(b'fLaC'):
            return 'audio/flac'
        if head.startswith(b'\xff\xd8\xff'):
            return 'image/jpeg'
        if head.startswith(b'\x89PNG'):
            return 'image/png'
    except Exception:
        pass
    if path.endswith(('.jpg', '.jpeg')):
        return 'image/jpeg'
    if path.endswith('.png'):
        return 'image/png'
    return 'audio/mpeg'

def save_uploaded_audio_to_mp3(raw_bytes, ext_hint="mp3"):
    """Save uploaded audio bytes (MP3/WAV/M4A/FLAC/OGG) as universal real MP3 in AUDIO_DIR."""
    digest = hashlib.sha256(raw_bytes).hexdigest()[:16]
    filename = f"upload_{digest}.mp3"
    target_mp3 = os.path.join(AUDIO_DIR, filename)
    if is_real_mp3(target_mp3):
        return filename, target_mp3

    clean_ext = re.sub(r'[^a-zA-Z0-9]', '', str(ext_hint or 'mp3').lower())[:6] or 'bin'
    tmp_in = os.path.join(CACHE_DIR, f"up_{digest}_{threading.get_ident()}.{clean_ext}")
    tmp_mp3 = os.path.join(AUDIO_DIR, f"{filename}.{threading.get_ident()}.tmp.mp3")
    try:
        with open(tmp_in, 'wb') as f:
            f.write(raw_bytes)
        # If already valid MP3 (ID3 tag or MPEG sync frame), store directly without re-encoding
        head = raw_bytes[:16]
        is_mp3_bytes = (head.startswith(b'ID3') or (len(head) >= 2 and head[0] == 0xFF and (head[1] & 0xE0) == 0xE0)) and (b'ftyp' not in head)
        if is_mp3_bytes and len(raw_bytes) > 10000:
            os.replace(tmp_in, target_mp3)
            print(f"[AntiCensor] Uploaded direct MP3 saved: {filename} ({len(raw_bytes)} bytes)", flush=True)
            return filename, target_mp3

        # Convert WAV/M4A/AAC/OGG/FLAC to universal 192kbps MP3 (works in Spotify Desktop CEF + iOS AVPlayer!)
        cmd = [FFMPEG, "-y", "-i", tmp_in, "-vn", "-c:a", "libmp3lame", "-b:a", "192k", "-f", "mp3", tmp_mp3]
        subprocess.run(cmd, check=True, capture_output=True, timeout=90)
        if is_real_mp3(tmp_mp3):
            os.replace(tmp_mp3, target_mp3)
            print(f"[AntiCensor] Uploaded audio converted to MP3: {filename}", flush=True)
            return filename, target_mp3
    finally:
        for p in (tmp_in, tmp_mp3):
            if os.path.exists(p):
                try:
                    os.remove(p)
                except OSError:
                    pass
    return None, None

# --- Instant-start streaming helpers -------------------------------------
_sc_cid_cache = {"id": None, "ts": 0.0}


def get_sc_client_id(force_refresh=False):
    """SoundCloud client_id соскабливается с сайта и кэшируется на час.

    Захардкоженный id рано или поздно протухает — тогда ЛЮБОЙ трек перестаёт
    резолвиться. Принудительный refresh спасает без пересборки приложения.
    """
    now = time.time()
    if not force_refresh:
        cached = _sc_cid_cache.get("id")
        if cached and now - _sc_cid_cache.get("ts", 0) < 3600:
            return cached
        return cached or SC_CLIENT_ID
    try:
        req = urllib.request.Request("https://soundcloud.com/", headers={'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'})
        html = urllib.request.urlopen(req, timeout=8).read().decode('utf-8', errors='ignore')
        m = re.search(r'"client_id"\s*:\s*"([A-Za-z0-9]{20,40})"', html)
        if m:
            _sc_cid_cache["id"] = m.group(1)
            _sc_cid_cache["ts"] = now
            print(f"[AntiCensor] refreshed SoundCloud client_id: {m.group(1)[:8]}...", flush=True)
            return m.group(1)
    except Exception as e:
        print(f"[AntiCensor] client_id refresh failed: {e}", flush=True)
    return _sc_cid_cache.get("id") or SC_CLIENT_ID


_sc_stream_cache = {}
# cache_path -> {"part": path, "done": Event}: allows Range requests to attach to a
# running transcode instead of starting a duplicate (or blocking for a minute).
_sc_active_transcodes = {}
_sc_active_lock = threading.Lock()
_sc_stream_lock = threading.Lock()
SC_STREAM_TTL = 20 * 60  # media URLs are signed; keep them short-lived


def find_cached_sc_file(raw_url, bitrate=192):
    """Return an already fully transcoded MP3 for this URL (never blocks)."""
    url = raw_url.split("?")[0].strip().replace("m.soundcloud.com", "soundcloud.com")
    for br in (bitrate, 192, 128, 96, 64):
        target = get_target_path(url, br)
        if is_real_mp3(target):
            return target
    slug = re.sub(r'[^a-zA-Z0-9]', '_', url)[-50:].strip('_')
    legacy = os.path.join(CACHE_DIR, f"{slug}.mp3")
    if is_real_mp3(legacy):
        return legacy
    return None


def resolve_sc_stream_info(raw_url, bitrate=192, force_refresh=False):
    """Resolve SoundCloud -> direct media URL WITHOUT downloading/transcoding.

    Picks the variant closest to `bitrate` (weak mobile -> lower preset).
    Returns dict(url=..., progressive=bool, preset=int) or None.
    """
    url = raw_url.strip()
    if any(d in url for d in ("on.soundcloud.com", "t.co", "bit.ly")):
        try:
            req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'})
            with urllib.request.urlopen(req, timeout=6) as resp:
                url = resp.geturl()
        except Exception as e:
            print("[AntiCensor] shortlink error:", e, flush=True)

    clean = url.split("?")[0].strip().replace("m.soundcloud.com", "soundcloud.com")
    target_br = max(64, min(320, int(bitrate or 128)))
    cache_key = f"{clean}|{target_br}"
    now = time.time()
    with _sc_stream_lock:
        hit = _sc_stream_cache.get(cache_key)
        if hit and now - hit["ts"] < SC_STREAM_TTL:
            return hit

    track_data = None
    cid = get_sc_client_id(force_refresh=force_refresh)
    api = f"https://api-v2.soundcloud.com/resolve?url={urllib.parse.quote(clean)}&client_id={cid}"
    try:
        req = urllib.request.Request(api, headers={'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'})
        track_data = json.loads(urllib.request.urlopen(req, timeout=8).read().decode('utf-8'))
    except Exception as e:
        print(f"[AntiCensor] fast resolve API error ({clean}): {e}", flush=True)

    trans = track_data.get('media', {}).get('transcodings', []) if track_data else []
    auth = track_data.get('track_authorization') if track_data else None

    if not trans:
        try:
            hreq = urllib.request.Request(clean, headers={'User-Agent': 'Mozilla/5.0 AppleWebKit/537.36'})
            with urllib.request.urlopen(hreq, timeout=6) as h:
                html = h.read().decode('utf-8', errors='ignore')
            m = re.findall(r'<script>window\.__sc_hydration\s*=\s*(\[.*?\]);</script>', html)
            if m:
                for it in json.loads(m[0]):
                    d = it.get('data')
                    if isinstance(d, dict) and 'media' in d:
                        trans = d.get('media', {}).get('transcodings', [])
                        auth = d.get('track_authorization')
                        break
        except Exception as e:
            print(f"[AntiCensor] fast hydration error: {e}", flush=True)

    if not trans:
        return None

    def usable(t):
        f = t.get('format', {}) or {}
        url = t.get('url') or ''
        if 'encrypted' in (f.get('protocol') or '') or 'skd:' in url:
            return False
        # audio/mpegurl — это не аудио, а плейлист-индекс; прямой запрос отдаёт 404
        if 'mpegurl' in (f.get('mime_type') or ''):
            return False
        return True

    def mime(t):
        return ((t.get('format', {}) or {}).get('mime_type') or '')

    def preset_kbps(t):
        # preset бывает пустым, но битрейт всегда виден в URL: .../aac_160k/...
        f = (t.get('format', {}) or {})
        raw = str(f.get('preset') or '')
        m = re.search(r'(\d{2,3})\s*k', raw) or re.search(r'aac_(\d{2,3})k', t.get('url') or '')
        if m:
            try:
                return int(m.group(1))
            except Exception:
                return 0
        return 0

    candidates = [t for t in trans if usable(t)]
    target = max(64, min(320, int(bitrate or 128)))

    def kbps_of_media(url, fallback=0):
        m = re.search(r'aac_(\d{2,3})k', url or '') or re.search(r'mp3_(\d{2,3})k', url or '')
        if m:
            try:
                return int(m.group(1))
            except Exception:
                return fallback
        return fallback

    # Резолвим до 4 вариантов и выбираем ближайший к запрошенному битрейту:
    # на слабом мобильном интернете 96k стартует заметно быстрее, чем 160k.
    resolved = []
    seen_media = set()
    for chosen in candidates[:5]:
        stream_api = chosen['url'] + ('&' if '?' in chosen['url'] else '?') + f'client_id={cid}'
        if auth:
            stream_api += f"&track_authorization={auth}"
        try:
            req = urllib.request.Request(stream_api, headers={'User-Agent': 'Mozilla/5.0'})
            info = json.loads(urllib.request.urlopen(req, timeout=8).read().decode('utf-8'))
            media = info.get('url')
        except Exception as e:
            print(f"[AntiCensor] stream-url candidate failed ({mime(chosen)}): {e}", flush=True)
            media = None
        if not media or media in seen_media:
            continue
        seen_media.add(media)
        kbps = kbps_of_media(media, preset_kbps(chosen) or 0)
        progressive = ((chosen.get('format', {}) or {}).get('protocol') == 'progressive')
        resolved.append({"url": media, "kbps": kbps, "progressive": progressive})
        if len(resolved) >= 4:
            break

    if not resolved:
        return None

    def pick_score(item):
        # 1) progressive mp3 (кэшируется и точно сикается) 2) не выше target 3) ближе к target
        proto = 0 if item["progressive"] else 1
        above = 0 if (item["kbps"] or target) <= target else 1
        return (proto, above, abs((item["kbps"] or target) - target))

    best = sorted(resolved, key=pick_score)[0]
    result = {"url": best["url"], "progressive": bool(best["progressive"]), "ts": now,
              "preset": best["kbps"], "cache_path": get_target_path(clean, target)}
    with _sc_stream_lock:
        _sc_stream_cache[cache_key] = result
    return result


def _mp3_head_ok(chunk):
    return chunk.startswith(b'ID3') or (len(chunk) >= 2 and chunk[0] == 0xFF and (chunk[1] & 0xE0) == 0xE0)


def stream_progressive_proxy(handler, media_url, range_header=None, cache_path=None):
    """Pipe SoundCloud's own progressive MP3 to the client 1:1 (zero transcode).

    Also tees the full (non-range) stream into cache_path for instant replay.
    """
    headers = {'User-Agent': 'Mozilla/5.0'}
    if range_header:
        headers['Range'] = range_header
    up = urllib.request.urlopen(urllib.request.Request(media_url, headers=headers), timeout=15)
    try:
        status = getattr(up, 'status', 200)
        if status not in (200, 206):
            return False
        first = up.read(4096)
        if not _mp3_head_ok(first):
            print("[AntiCensor] upstream is not raw MP3, falling back to transcode", flush=True)
            return False
        ctype = up.headers.get('Content-Type', 'audio/mpeg')
        clen = up.headers.get('Content-Length')
        crange = up.headers.get('Content-Range')

        handler.send_response(206 if status == 206 else 200)
        handler.send_cors()
        handler.send_header('Content-Type', 'audio/mpeg' if 'mpeg' in (ctype or '') else ctype)
        if crange:
            handler.send_header('Content-Range', crange)
        if clen:
            handler.send_header('Content-Length', clen)
        else:
            handler.send_header('Connection', 'close')
            handler.close_connection = True
        handler.send_header('Accept-Ranges', 'bytes')
        handler.send_header('Cache-Control', 'no-store')
        handler.end_headers()
        handler.wfile.write(first)
        fh = None
        tmp = None
        if cache_path and not range_header and (not clen or int(clen) > 50000):
            tmp = f"{cache_path}.{threading.get_ident()}.part.mp3"
            try:
                fh = open(tmp, "wb")
                fh.write(first)
            except OSError:
                fh = None
        completed = False
        while True:
            chunk = up.read(65536)
            if not chunk:
                completed = True
                break
            handler.wfile.write(chunk)
            if fh:
                try:
                    fh.write(chunk)
                except OSError:
                    pass
        handler.wfile.flush()
        if fh:
            try:
                fh.close()
                # Кэшируем ТОЛЬКО полностью скачанный трек: обрыв клиента не должен
                # оставлять в кэше обрезанный mp3 (иначе трек будет «кончаться» на середине).
                expected = int(clen) if (clen and str(clen).isdigit()) else 0
                size_ok = expected == 0 or os.path.getsize(tmp) >= expected
                if completed and size_ok and os.path.getsize(tmp) > 50000:
                    os.replace(tmp, cache_path)
                    print(f"[AntiCensor] progressive proxy cached: {cache_path}", flush=True)
                elif os.path.exists(tmp):
                    os.remove(tmp)
            except OSError:
                pass
        return True
    except (ConnectionResetError, BrokenPipeError, ConnectionAbortedError):
        return True
    finally:
        try:
            up.close()
        except Exception:
            pass


def stream_growing_file(handler, entry):
    """Stream a transcode that is still being written (chunked, from byte 0).

    Used when the client asks for a Range while the first transcode is running:
    better to deliver audio from the start than to block for tens of seconds.
    """
    part = entry.get("part")
    done = entry.get("done")
    waited = 0.0
    while part and not os.path.exists(part) and waited < 3.0:
        time.sleep(0.1)
        waited += 0.1
    if not part or not os.path.exists(part):
        return False
    handler.send_response(200)
    handler.send_cors()
    handler.send_header('Content-Type', 'audio/mpeg')
    handler.send_header('Transfer-Encoding', 'chunked')
    handler.send_header('Accept-Ranges', 'none')
    handler.send_header('Cache-Control', 'no-store')
    handler.end_headers()
    sent = 0
    idle = 0
    try:
        f = open(part, "rb")
    except OSError:
        return False
    try:
        while True:
            chunk = f.read(65536)
            if chunk:
                idle = 0
                handler.wfile.write(b"%x\r\n" % len(chunk))
                handler.wfile.write(chunk)
                handler.wfile.write(b"\r\n")
                handler.wfile.flush()
                sent += len(chunk)
                continue
            if done is not None and done.is_set():
                break
            idle += 1
            if idle > 150:  # ~30s without progress -> give up
                break
            time.sleep(0.2)
        handler.wfile.write(b"0\r\n\r\n")
        handler.wfile.flush()
        return True
    except (ConnectionResetError, BrokenPipeError, ConnectionAbortedError):
        return True
    finally:
        try:
            f.close()
        except Exception:
            pass


def stream_transcode_chunked(handler, media_url, bitrate, cache_path):
    """ffmpeg -> socket (chunked) while teeing into the cache file.

    First audio bytes arrive in ~1-2s instead of after a full transcode.
    """
    cmd = [FFMPEG, "-hide_banner", "-loglevel", "error", "-i", media_url, "-vn",
           "-c:a", "libmp3lame", "-b:a", f"{bitrate}k", "-f", "mp3", "pipe:1"]
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=65536)
    tmp = f"{cache_path}.{threading.get_ident()}.part.mp3"
    done_evt = threading.Event()
    with _sc_active_lock:
        _sc_active_transcodes[cache_path] = {"part": tmp, "done": done_evt}
    fh = None
    try:
        fh = open(tmp, "wb")
    except OSError:
        fh = None

    wrote_any = False
    try:
        first_chunk = proc.stdout.read(65536)
        if not first_chunk:
            handler.send_response(404)
            handler.send_cors()
            handler.send_header('Content-Length', '0')
            handler.end_headers()
            return
        if not _mp3_head_ok(first_chunk):
            print("[AntiCensor] transcode produced non-MP3 head!", flush=True)

        handler.send_response(200)
        handler.send_cors()
        handler.send_header('Content-Type', 'audio/mpeg')
        handler.send_header('Transfer-Encoding', 'chunked')
        handler.send_header('Accept-Ranges', 'none')
        handler.send_header('Cache-Control', 'no-store')
        handler.end_headers()

        chunk = first_chunk
        while chunk:
            wrote_any = True
            if fh:
                fh.write(chunk)
            handler.wfile.write(b"%x\r\n" % len(chunk))
            handler.wfile.write(chunk)
            handler.wfile.write(b"\r\n")
            handler.wfile.flush()
            chunk = proc.stdout.read(65536)
        handler.wfile.write(b"0\r\n\r\n")
        handler.wfile.flush()
    except (ConnectionResetError, BrokenPipeError, ConnectionAbortedError):
        pass
    finally:
        with _sc_active_lock:
            _sc_active_transcodes.pop(cache_path, None)
        done_evt.set()
        finished = False
        try:
            proc.wait(timeout=5)
            finished = (proc.returncode == 0)
        except Exception:
            finished = False
        try:
            proc.kill()
        except Exception:
            pass
        if fh:
            fh.close()
        try:
            # Только успешно завершённый transcode попадает в кэш
            if finished and wrote_any and fh and os.path.getsize(tmp) > 50000:
                os.replace(tmp, cache_path)
                print(f"[AntiCensor] chunked transcode cached: {cache_path}", flush=True)
            elif os.path.exists(tmp):
                os.remove(tmp)
        except OSError:
            pass


def resolve_sc_to_file(raw_url, bitrate=192):
    url = raw_url.strip()

    # Follow redirects for on.soundcloud.com shortlinks or any shortened URLs
    if any(domain in url for domain in ["on.soundcloud.com", "t.co", "bit.ly"]):
        try:
            req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'})
            with urllib.request.urlopen(req, timeout=10) as resp:
                url = resp.geturl()
        except Exception as e:
            print("[AntiCensor] Redirect error:", e, flush=True)

    clean_url = url.split("?")[0].strip().replace("m.soundcloud.com", "soundcloud.com")
    target_mp3 = get_target_path(clean_url, bitrate)
    slug = re.sub(r'[^a-zA-Z0-9]', '_', clean_url)[-50:].strip('_')
    legacy_mp3 = os.path.join(CACHE_DIR, f"{slug}.mp3")

    if is_real_mp3(target_mp3):
        return target_mp3
    if is_real_mp3(legacy_mp3):
        return legacy_mp3

    with get_url_lock(clean_url):
        # Double-check after acquiring per-URL lock; purge poisoned MP4-as-MP3 cache!
        if os.path.exists(target_mp3) and not is_real_mp3(target_mp3):
            try:
                os.remove(target_mp3)
                print(f"[AntiCensor] Purged poisoned non-MP3 cache: {target_mp3}", flush=True)
            except OSError:
                pass
        if is_real_mp3(target_mp3):
            return target_mp3
        if is_real_mp3(legacy_mp3):
            return legacy_mp3

        tmp_mp3 = f"{target_mp3}.{threading.get_ident()}.tmp.mp3"
        try:
            # Resolve track metadata via SoundCloud API v2
            track_data = None
            api_url = f"https://api-v2.soundcloud.com/resolve?url={urllib.parse.quote(clean_url)}&client_id={get_sc_client_id()}"
            try:
                req = urllib.request.Request(api_url, headers={'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'})
                track_data = json.loads(urllib.request.urlopen(req, timeout=10).read().decode('utf-8'))
            except Exception as api_err:
                print(f"[AntiCensor] API v2 error for {clean_url}: {api_err}", flush=True)

            # Fallback to hydration parsing from HTML
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
                    print(f"[AntiCensor] Hydration parse error: {h_err}", flush=True)

            if not trans:
                print(f"[AntiCensor] No transcodings found for {clean_url}", flush=True)
                return None

            unenc = [x for x in trans if 'encrypted' not in x.get('format', {}).get('protocol', '') and 'skd:' not in x.get('url', '')]
            valid_trans = unenc if unenc else trans

            # Priority: 1) progressive audio/mpeg (instant), 2) hls audio/mpeg (fast copy), 3) any progressive, 4) any hls (transcode to real MP3)
            prog_mp3 = next((x for x in valid_trans if x.get('format', {}).get('protocol') == 'progressive' and 'mpeg' in x.get('format', {}).get('mime_type', '')), None)
            hls_mp3 = next((x for x in valid_trans if x.get('format', {}).get('protocol') == 'hls' and 'mpeg' in x.get('format', {}).get('mime_type', '') and 'mpegurl' not in x.get('format', {}).get('mime_type', '')), None)
            prog_any = next((x for x in valid_trans if x.get('format', {}).get('protocol') == 'progressive'), None)
            hls_any = next((x for x in valid_trans if x.get('format', {}).get('protocol') == 'hls'), valid_trans[0])

            chosen = prog_mp3 or hls_mp3 or prog_any or hls_any
            is_native_mp3 = (chosen in (prog_mp3, hls_mp3))
            stream_api = chosen['url'] + ('&' if '?' in chosen['url'] else '?') + f'client_id={get_sc_client_id()}'
            if track_auth:
                stream_api += f"&track_authorization={track_auth}"

            stream_info = json.loads(urllib.request.urlopen(urllib.request.Request(stream_api, headers={'User-Agent': 'Mozilla/5.0'}), timeout=10).read().decode('utf-8'))
            media_url = stream_info['url']

            # If native audio/mpeg AND high bitrate requested, copy directly (~1s)
            if is_native_mp3 and bitrate >= 192:
                cmd = [FFMPEG, "-y", "-i", media_url, "-vn", "-c:a", "copy", "-f", "mp3", tmp_mp3]
                res = subprocess.run(cmd, capture_output=True, timeout=60)
                if res.returncode == 0 and is_real_mp3(tmp_mp3):
                    os.replace(tmp_mp3, target_mp3)
                    print(f"[AntiCensor] Fast native MP3 cached: {target_mp3}", flush=True)
                    return target_mp3

            # Transcode to requested bitrate MP3 (weak internet -> lower bitrate; default 192k)
            cmd2 = [FFMPEG, "-y", "-i", media_url, "-vn", "-c:a", "libmp3lame", "-b:a", f"{bitrate}k", "-f", "mp3", tmp_mp3]
            subprocess.run(cmd2, check=True, capture_output=True, timeout=90)
            if is_real_mp3(tmp_mp3):
                os.replace(tmp_mp3, target_mp3)
                print(f"[AntiCensor] Real MP3 transcoded & cached: {target_mp3}", flush=True)
                return target_mp3
        except Exception as e:
            print(f"[AntiCensor] Resolve error for {clean_url}: {e}", flush=True)
        finally:
            if os.path.exists(tmp_mp3):
                try:
                    os.remove(tmp_mp3)
                except OSError:
                    pass

    if is_real_mp3(target_mp3):
        return target_mp3
    return None

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
    global _sync_db_cache
    with sync_lock:
        if _sync_db_cache is not None:
            return _sync_db_cache
        db = {
            "overrides": dict(DEFAULT_OVERRIDES),
            "lyrics": {},
            "deleted_overrides": [],
            "deleted_lyrics": [],
            "updated_at": 0,
        }
        if os.path.exists(SYNC_DB_FILE):
            try:
                with open(SYNC_DB_FILE, "r", encoding="utf-8") as f:
                    disk_db = json.load(f)
                    if isinstance(disk_db, dict):
                        if isinstance(disk_db.get("overrides"), dict):
                            for k, v in disk_db["overrides"].items():
                                if isinstance(v, str) and v.strip() and not v.strip().startswith("local://"):
                                    db["overrides"][k] = v.strip()
                        if isinstance(disk_db.get("lyrics"), dict):
                            for k, v in disk_db["lyrics"].items():
                                if isinstance(v, str) and v.strip():
                                    db["lyrics"][k] = v
                        for tomb_key in ("deleted_overrides", "deleted_lyrics"):
                            if isinstance(disk_db.get(tomb_key), list):
                                db[tomb_key] = [normalize_sync_key(x) for x in disk_db[tomb_key] if isinstance(x, str) and len(x) >= 2]
                        if isinstance(disk_db.get("updated_at"), (int, float)):
                            db["updated_at"] = disk_db["updated_at"]
            except Exception as e:
                print("[AntiCensor] Load sync DB error:", e, flush=True)
        # Гробницы применяются и к builtin-дефолтам: удалённая замена не воскресает
        _apply_tombstones(db)
        _sync_db_cache = db
        return _sync_db_cache

def _apply_tombstones(db):
    gone_o = set(db.get("deleted_overrides") or [])
    gone_l = set(db.get("deleted_lyrics") or [])
    _scrub_tombstoned(db["overrides"], gone_o)
    _scrub_tombstoned(db["lyrics"], gone_l)

def save_sync_db(db):
    global _sync_db_cache
    with sync_lock:
        _sync_db_cache = db
        tmp_path = f"{SYNC_DB_FILE}.{threading.get_ident()}.tmp"
        try:
            with open(tmp_path, "w", encoding="utf-8") as f:
                json.dump(db, f, ensure_ascii=False, indent=2)
            os.replace(tmp_path, SYNC_DB_FILE)
        except Exception as e:
            print("[AntiCensor] Save sync DB error:", e, flush=True)
            if os.path.exists(tmp_path):
                try:
                    os.remove(tmp_path)
                except OSError:
                    pass

def _mark_tombstones(db, raw_keys, for_lyrics):
    """Помечает ключи удалёнными НАВСЕГДА и сразу вычищает их из базы."""
    tomb_key = "deleted_lyrics" if for_lyrics else "deleted_overrides"
    gone = set(db.get(tomb_key) or [])
    for raw in raw_keys:
        for v in _tombstone_variants(raw):
            gone.add(normalize_sync_key(v))
    db[tomb_key] = sorted(gone)
    _scrub_tombstoned(db["lyrics" if for_lyrics else "overrides"], gone)

def _delete_key_variants(mapping, raw_key):
    if not isinstance(raw_key, str) or not raw_key.strip():
        return
    variants = set(_tombstone_variants(raw_key))
    for k in list(mapping.keys()):
        if k in variants or k.lower() in variants or normalize_sync_key(k) in variants:
            del mapping[k]

def merge_sync_payload(payload):
    """Atomically merge incoming overrides/lyrics from Mobile or PC and return full snapshot."""
    with sync_lock:
        db = load_sync_db()
        pushed_overrides = 0
        pushed_lyrics = 0
        changed = False

        # Гробницы из клиента (iOS/PC удалили замену или текст)
        if isinstance(payload.get("deleted_overrides"), list) and payload["deleted_overrides"]:
            _mark_tombstones(db, payload["deleted_overrides"], for_lyrics=False)
            changed = True
        if isinstance(payload.get("deleted_lyrics"), list) and payload["deleted_lyrics"]:
            _mark_tombstones(db, payload["deleted_lyrics"], for_lyrics=True)
            changed = True

        # Клиент может снова ЯВНО задать замену — снимаем её с гробницы.
        # Важно: обычная синхронизация (push локальной базы) НЕ должна воскрешать
        # удалённое, иначе ПК с устаревшим localStorage вернёт замену назад.
        if isinstance(payload.get("restored_overrides"), list) and payload["restored_overrides"]:
            gone_o = set(db.get("deleted_overrides") or [])
            before = len(gone_o)
            for raw_k in payload["restored_overrides"]:
                for v in _tombstone_variants(raw_k):
                    gone_o.discard(normalize_sync_key(v))
            if len(gone_o) != before:
                db["deleted_overrides"] = sorted(gone_o)
                changed = True
        if isinstance(payload.get("restored_lyrics"), list) and payload["restored_lyrics"]:
            gone_l = set(db.get("deleted_lyrics") or [])
            before = len(gone_l)
            for raw_k in payload["restored_lyrics"]:
                for v in _tombstone_variants(raw_k):
                    gone_l.discard(normalize_sync_key(v))
            if len(gone_l) != before:
                db["deleted_lyrics"] = sorted(gone_l)
                changed = True

        if isinstance(payload.get("overrides"), dict):
            for raw_k, raw_v in payload["overrides"].items():
                if not isinstance(raw_k, str):
                    continue
                k = raw_k.strip()
                if len(k) < 2:
                    continue
                # Reject corrupted album/double-prefix keys
                low_k = k.lower()
                if "spotify:track:spotify:" in low_k or low_k.startswith(("spotify:album:", "spotify:playlist:", "spotify:artist:")):
                    _delete_key_variants(db["overrides"], k)
                    _mark_tombstones(db, [k], for_lyrics=False)
                    changed = True
                    continue
                val = str(raw_v).strip() if raw_v is not None else ""
                if not val:
                    # Пустое значение = удаление: ставим вечную гробницу, иначе builtin вернёт замену
                    _mark_tombstones(db, [k], for_lyrics=False)
                    changed = True
                    continue
                # Never sync device-local iOS file paths to cloud
                if val.startswith("local://"):
                    continue
                # Удалённую замену нельзя вернуть обычной синхронизацией (только restored_overrides)
                gone_now = set(db.get("deleted_overrides") or [])
                if any(normalize_sync_key(v) in gone_now for v in _tombstone_variants(k)) or normalize_sync_key(k) in gone_now:
                    continue
                # Strip SoundCloud tracking query params (?si=...&utm_...)
                if "soundcloud.com/" in val and "?" in val and "on.soundcloud.com" not in val:
                    val = val.split("?")[0].strip()
                # Store exact key + normalized lowercase + bare track ID for 100% Mobile <-> PC compatibility
                if db["overrides"].get(k) != val:
                    db["overrides"][k] = val
                    pushed_overrides += 1
                    changed = True
                norm_k = normalize_sync_key(k)
                if norm_k and norm_k != k and db["overrides"].get(norm_k) != val:
                    db["overrides"][norm_k] = val
                    changed = True
                if low_k.startswith("spotify:track:"):
                    parts = k.split(":")
                    if len(parts) == 3 and len(parts[2]) >= 10:
                        tid = parts[2]
                        if db["overrides"].get(tid) != val:
                            db["overrides"][tid] = val
                            changed = True
                        if db["overrides"].get(tid.lower()) != val:
                            db["overrides"][tid.lower()] = val
                            changed = True

        if isinstance(payload.get("lyrics"), dict):
            for raw_k, raw_v in payload["lyrics"].items():
                if not isinstance(raw_k, str):
                    continue
                k = raw_k.strip()
                if len(k) < 2:
                    continue
                val = str(raw_v) if raw_v is not None else ""
                if not val.strip():
                    _mark_tombstones(db, [k], for_lyrics=True)
                    changed = True
                    continue
                if db["lyrics"].get(k) != val:
                    db["lyrics"][k] = val
                    pushed_lyrics += 1
                    changed = True
                norm_k = normalize_sync_key(k)
                if norm_k and norm_k != k and db["lyrics"].get(norm_k) != val:
                    db["lyrics"][norm_k] = val
                    changed = True

        if changed:
            db["updated_at"] = time.time()
            save_sync_db(db)

        return {
            "overrides": dict(db["overrides"]),
            "lyrics": dict(db["lyrics"]),
            "deleted_overrides": list(db.get("deleted_overrides") or []),
            "deleted_lyrics": list(db.get("deleted_lyrics") or []),
            "updated_at": db["updated_at"],
            "pushed_overrides": pushed_overrides,
            "pushed_lyrics": pushed_lyrics,
            "server_time": time.time(),
        }

def get_sync_snapshot():
    with sync_lock:
        db = load_sync_db()
        return {
            "overrides": dict(db["overrides"]),
            "lyrics": dict(db["lyrics"]),
            "deleted_overrides": list(db.get("deleted_overrides") or []),
            "deleted_lyrics": list(db.get("deleted_lyrics") or []),
            "updated_at": db["updated_at"],
            "server_time": time.time(),
        }

class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

class AudioHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):
        sys.stdout.write("[AntiCensor HTTP] %s - %s\n" % (self.address_string(), format % args))
        sys.stdout.flush()

    def send_cors(self):
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, HEAD, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Range, Content-Type, Authorization, Cache-Control')

    def send_json(self, status_code, obj, is_head=False):
        raw = json.dumps(obj, ensure_ascii=False).encode('utf-8')
        self.send_response(status_code)
        self.send_cors()
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Cache-Control', 'no-store, no-cache, must-revalidate')
        self.send_header('Content-Length', str(len(raw)))
        self.end_headers()
        if not is_head:
            self.wfile.write(raw)

    def read_json_body(self):
        raw_len = self.headers.get('Content-Length', '0')
        try:
            length = int(raw_len)
        except ValueError:
            length = 0
        if length < 0 or length > 5 * 1024 * 1024:
            raise ValueError("Invalid Content-Length")
        if length == 0:
            return {}
        body = self.rfile.read(length).decode('utf-8', errors='replace')
        if not body.strip():
            return {}
        data = json.loads(body)
        if not isinstance(data, dict):
            raise ValueError("JSON payload must be an object")
        return data

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_cors()
        self.send_header('Content-Length', '0')
        self.end_headers()

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == '/api/sync':
            try:
                payload = self.read_json_body()
                snapshot = merge_sync_payload(payload)
                self.send_json(200, snapshot)
                return
            except Exception as e:
                self.send_json(400, {"error": str(e)})
                return

        if parsed.path == '/api/add_track':
            try:
                payload = self.read_json_body()
                key = payload.get("key")
                url = payload.get("url")
                if key and url:
                    threading.Thread(target=auto_cache_sc_track, args=(key, url), daemon=True).start()
                    clean_url = str(url).split("?")[0].strip().replace("m.soundcloud.com", "soundcloud.com")
                    slug = re.sub(r'[^a-zA-Z0-9]', '_', clean_url)[-50:].strip('_')
                    predicted_cloud = f"{PUBLIC_BASE_URL}/audio/sc_{slug}.mp3"
                    self.send_json(200, {"status": "caching_started", "cloud_url": predicted_cloud})
                    return
                self.send_json(400, {"error": "Missing key or url"})
                return
            except Exception as e:
                self.send_json(400, {"error": str(e)})
                return

        if parsed.path == '/api/upload':
            try:
                raw_len = self.headers.get('Content-Length', '0')
                length = int(raw_len)
                if length <= 0 or length > 35 * 1024 * 1024:
                    self.send_json(400, {"error": "Invalid file size (max 35MB)"})
                    return
                raw_bytes = self.rfile.read(length)
                params = urllib.parse.parse_qs(parsed.query)
                fname_param = params.get('filename', ['audio.mp3'])[0]
                ext_hint = os.path.splitext(fname_param)[1].lstrip('.') or 'mp3'
                saved_name, saved_path = save_uploaded_audio_to_mp3(raw_bytes, ext_hint)
                if not saved_name or not saved_path:
                    self.send_json(500, {"error": "Failed to process uploaded audio"})
                    return
                self.send_json(200, {
                    "status": "ok",
                    "filename": saved_name,
                    "local_url": f"/audio/{saved_name}",
                    "url": f"{PUBLIC_BASE_URL}/audio/{saved_name}",
                    "size": os.path.getsize(saved_path)
                })
                return
            except Exception as e:
                print("[AntiCensor] Upload error:", e, flush=True)
                self.send_json(500, {"error": str(e)})
                return

        self.send_json(404, {"error": "Not found"})

    def do_HEAD(self):
        self.handle_get_or_head(is_head=True)

    def do_GET(self):
        self.handle_get_or_head(is_head=False)

    def handle_get_or_head(self, is_head=False):
        parsed = urllib.parse.urlparse(self.path)
        params = urllib.parse.parse_qs(parsed.query)

        if parsed.path == '/api/sync':
            snapshot = get_sync_snapshot()
            self.send_json(200, snapshot, is_head=is_head)
            return

        if parsed.path == '/api/status':
            snapshot = get_sync_snapshot()
            self.send_json(200, {
                "status": "ok",
                "overrides_count": len(snapshot["overrides"]),
                "lyrics_count": len(snapshot["lyrics"]),
                "deleted_overrides_count": len(snapshot.get("deleted_overrides") or []),
                "deleted_lyrics_count": len(snapshot.get("deleted_lyrics") or []),
                "updated_at": snapshot["updated_at"],
                "server_time": snapshot["server_time"],
            }, is_head=is_head)
            return

        if parsed.path == '/health' or parsed.path == '/':
            body = b"AntiCensor Cloud Bridge: OK"
            self.send_response(200)
            self.send_cors()
            self.send_header('Content-Type', 'text/plain; charset=utf-8')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            if not is_head:
                self.wfile.write(body)
            return

        if parsed.path == '/resolve' and 'url' in params:
            # Только резолв: отдаём прямой CDN-URL SoundCloud, чтобы телефон качал
            # аудио напрямую (мгновенный старт), а не через transcode на сервере.
            sc_url = params['url'][0]
            try:
                br = int(params.get('br', ['128'])[0])
            except (ValueError, TypeError):
                br = 128
            br = max(64, min(320, br))
            fresh = (params.get('fresh', ['0'])[0] == '1')
            if fresh:
                with _sc_stream_lock:
                    for k in list(_sc_stream_cache.keys()):
                        if k.startswith(sc_url.split('?')[0].strip()):
                            _sc_stream_cache.pop(k, None)
            info = None
            try:
                info = resolve_sc_stream_info(sc_url, br, force_refresh=fresh)
                if not info:
                    # Возможно, протух client_id — обновляем и пробуем ещё раз
                    info = resolve_sc_stream_info(sc_url, br, force_refresh=True)
                if info and info.get('url'):
                    self.send_json(200, {
                        "url": info['url'],
                        "progressive": bool(info.get('progressive')),
                        "preset": info.get('preset', 0),
                    }, is_head=is_head)
                else:
                    self.send_json(404, {"error": "not resolved"}, is_head=is_head)
            except Exception as e:
                self.send_json(500, {"error": str(e)}, is_head=is_head)
            return

        if parsed.path == '/debug' and 'url' in params:
            # Диагностика: синхронно повторяем путь /sc и отдаём ошибку текстом
            out = {"ok": False, "stage": "start"}
            try:
                sc_url = params['url'][0]
                try:
                    br = int(params.get('br', ['96'])[0])
                except (ValueError, TypeError):
                    br = 96
                out["stage"] = "cached"
                cached = find_cached_sc_file(sc_url, br)
                out["cached"] = bool(cached)
                out["stage"] = "stream_info"
                info = resolve_sc_stream_info(sc_url, br)
                out["info"] = bool(info)
                if info:
                    out["progressive"] = bool(info.get("progressive"))
                    out["preset"] = info.get("preset")
                out["stage"] = "transcode"
                path = resolve_sc_to_file(sc_url, br)
                out["path"] = path
                out["size"] = os.path.getsize(path) if path else 0
                out["ok"] = bool(path)
            except Exception as e:
                import traceback
                out["error"] = f"{type(e).__name__}: {e}"
                out["trace"] = traceback.format_exc()[-800:]
            self.send_json(200, out, is_head=is_head)
            return

        if parsed.path == '/warm' and 'url' in params:
            # Готовим серверный MP3 заранее (в фоне), чтобы аварийный переход
            # на сервер был мгновенным. Стрим клиенту не отдаётся.
            try:
                sc_url = params['url'][0]
                try:
                    br = int(params.get('br', ['128'])[0])
                except (ValueError, TypeError):
                    br = 128
                br = max(64, min(320, br))
                if find_cached_sc_file(sc_url, br):
                    self.send_json(200, {"status": "cached"}, is_head=is_head)
                else:
                    threading.Thread(target=resolve_sc_to_file, args=(sc_url, br), daemon=True).start()
                    self.send_json(200, {"status": "warming"}, is_head=is_head)
            except Exception as e:
                self.send_json(500, {"error": str(e)}, is_head=is_head)
            return

        if parsed.path == '/preload' and 'url' in params:
            # Только резолв (без ffmpeg): раньше /preload запускал полный transcode
            # для каждого трека и перегружал free-инстанс (502/503).
            sc_url = params['url'][0]
            try:
                br = int(params.get('br', ['128'])[0])
            except (ValueError, TypeError):
                br = 128
            threading.Thread(target=resolve_sc_stream_info, args=(sc_url, br), daemon=True).start()
            self.send_json(200, {"status": "resolving"}, is_head=is_head)
            return

        if parsed.path == '/api/add_track' and 'url' in params and 'key' in params:
            key = params['key'][0]
            sc_url = params['url'][0]
            threading.Thread(target=auto_cache_sc_track, args=(key, sc_url), daemon=True).start()
            clean_url = sc_url.split("?")[0].strip().replace("m.soundcloud.com", "soundcloud.com")
            slug = re.sub(r'[^a-zA-Z0-9]', '_', clean_url)[-50:].strip('_')
            predicted_cloud = f"{PUBLIC_BASE_URL}/audio/sc_{slug}.mp3"
            self.send_json(200, {"status": "caching_started", "cloud_url": predicted_cloud}, is_head=is_head)
            return

        if parsed.path == '/status' and 'url' in params:
            sc_url = params['url'][0]
            clean_url = sc_url.split("?")[0].strip()
            target_mp3 = get_target_path(clean_url)
            is_ready = os.path.exists(target_mp3) and os.path.getsize(target_mp3) > 30000
            self.send_json(200, {"ready": bool(is_ready)}, is_head=is_head)
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
            # СТАБИЛЬНЫЙ путь: отдаём готовый файл (кэш) или перекодируем целиком.
            # Чанк-стриминг оставлен только по явному ?stream=1 — Render free-план
            # рвёт длинные стримы (502), из-за чего треки «вообще не грузились».
            try:
                sc_url = params['url'][0]
                try:
                    bitrate = int(params.get('br', ['128'])[0])
                except (ValueError, TypeError):
                    bitrate = 128
                bitrate = max(64, min(320, bitrate))
                range_header = self.headers.get('Range')
                want_stream = (params.get('stream', ['0'])[0] == '1')

                file_to_stream = find_cached_sc_file(sc_url, bitrate)
                if not file_to_stream and not is_head:
                    info = resolve_sc_stream_info(sc_url, bitrate)
                    if info and want_stream and not range_header:
                        with get_url_lock(sc_url.split("?")[0]):
                            stream_transcode_chunked(self, info['url'], bitrate, info['cache_path'])
                        return
                    if info and info.get('progressive'):
                        if stream_progressive_proxy(self, info['url'], range_header, info.get('cache_path')):
                            return
                    file_to_stream = resolve_sc_to_file(sc_url, bitrate)
            except Exception as e:
                print("[AntiCensor] SC Resolve Error:", e, flush=True)

        if not file_to_stream or not os.path.exists(file_to_stream):
            self.send_response(404)
            self.send_cors()
            self.send_header('Content-Length', '0')
            self.end_headers()
            return

        file_size = os.path.getsize(file_to_stream)
        range_header = self.headers.get('Range')
        ct = detect_content_type(file_to_stream)

        try:
            # Handle HTTP 206 Partial Content (required for instant scrub & lyrics click)
            if range_header:
                match = re.search(r'bytes=(\d+)-(\d*)', range_header)
                if match:
                    start = int(match.group(1))
                    end = int(match.group(2)) if match.group(2) else file_size - 1
                    end = min(end, file_size - 1)
                    if start >= file_size or start > end:
                        self.send_response(416)
                        self.send_cors()
                        self.send_header('Content-Range', f'bytes */{file_size}')
                        self.send_header('Content-Length', '0')
                        self.end_headers()
                        return
                    length = end - start + 1

                    self.send_response(206)
                    self.send_cors()
                    self.send_header('Content-Type', ct)
                    self.send_header('Content-Range', f'bytes {start}-{end}/{file_size}')
                    self.send_header('Content-Length', str(length))
                    self.send_header('Accept-Ranges', 'bytes')
                    self.end_headers()

                    if not is_head:
                        with open(file_to_stream, 'rb') as f:
                            f.seek(start)
                            remaining = length
                            while remaining > 0:
                                chunk = f.read(min(65536, remaining))
                                if not chunk:
                                    break
                                self.wfile.write(chunk)
                                remaining -= len(chunk)
                    return

            self.send_response(200)
            self.send_cors()
            self.send_header('Content-Type', ct)
            self.send_header('Content-Length', str(file_size))
            self.send_header('Accept-Ranges', 'bytes')
            self.end_headers()

            if not is_head:
                with open(file_to_stream, 'rb') as f:
                    while True:
                        chunk = f.read(65536)
                        if not chunk:
                            break
                        self.wfile.write(chunk)
        except (ConnectionResetError, BrokenPipeError, ConnectionAbortedError):
            pass

def _keepalive_pinger():
    """Ping /health every 10 minutes to reduce Render free-tier sleep."""
    time.sleep(60)
    while True:
        for url in (f"{PUBLIC_BASE_URL}/health", f"http://127.0.0.1:{PORT}/health"):
            try:
                urllib.request.urlopen(url, timeout=8).read()
                break
            except Exception:
                pass
        time.sleep(600)

if __name__ == '__main__':
    server = ThreadedHTTPServer(('0.0.0.0', PORT), AudioHandler)
    print(f"[AntiCensor] Cloud Bridge listening on 0.0.0.0:{PORT}", flush=True)

    threading.Thread(target=_keepalive_pinger, daemon=True).start()
    server.serve_forever()