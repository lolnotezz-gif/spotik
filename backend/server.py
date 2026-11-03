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
os.makedirs(CACHE_DIR, exist_ok=True)

# Find ffmpeg binary
FFMPEG = "ffmpeg"
try:
    import imageio_ffmpeg
    FFMPEG = imageio_ffmpeg.get_ffmpeg_exe()
except Exception:
    pass

SC_CLIENT_ID = os.environ.get("SC_CLIENT_ID", "2yeWkbX88QhTzS3OtZp8cLGaJRrOAWwF")

in_progress_lock = threading.Lock()
in_progress_urls = set()

def get_target_path(clean_url):
    slug = re.sub(r'[^a-zA-Z0-9]', '_', clean_url)[-50:]
    return os.path.join(CACHE_DIR, f"{slug}.mp3")

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

    clean_url = url.split("?")[0].strip()
    target_mp3 = get_target_path(clean_url)

    if os.path.exists(target_mp3) and os.path.getsize(target_mp3) > 100000:
        return target_mp3

    with in_progress_lock:
        if clean_url not in in_progress_urls:
            in_progress_urls.add(clean_url)

    try:
        # Check if already resolved by another concurrent worker
        if os.path.exists(target_mp3) and os.path.getsize(target_mp3) > 100000:
            return target_mp3

        # Resolve track metadata via SoundCloud API v2
        api_url = f"https://api-v2.soundcloud.com/resolve?url={urllib.parse.quote(clean_url)}&client_id={SC_CLIENT_ID}"
        req = urllib.request.Request(api_url, headers={'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'})
        track_data = json.loads(urllib.request.urlopen(req, timeout=12).read().decode('utf-8'))

        trans = track_data.get('media', {}).get('transcodings', [])
        if not trans:
            return None

        prog = next((x for x in trans if x.get('format', {}).get('protocol') == 'progressive'), None)
        hls_trans = next((x for x in trans if x.get('format', {}).get('protocol') == 'hls'), trans[0])

        chosen = prog or hls_trans
        stream_api = chosen['url'] + ('&' if '?' in chosen['url'] else '?') + f'client_id={SC_CLIENT_ID}'
        if track_data.get('track_authorization'):
            stream_api += f"&track_authorization={track_data['track_authorization']}"

        stream_info = json.loads(urllib.request.urlopen(urllib.request.Request(stream_api, headers={'User-Agent': 'Mozilla/5.0'}), timeout=12).read().decode('utf-8'))
        media_url = stream_info['url']

        tmp_out = target_mp3 + ".tmp.mp3"
        cmd = [FFMPEG, "-y", "-i", media_url, "-c:a", "libmp3lame", "-q:a", "2", tmp_out]
        subprocess.run(cmd, check=True, capture_output=True)
        if os.path.exists(tmp_out):
            os.replace(tmp_out, target_mp3)
            print(f"[AntiCensor] Successfully converted & cached: {target_mp3}")
            return target_mp3
    except Exception as e:
        print(f"[AntiCensor] Resolve error for {clean_url}: {e}")
    finally:
        with in_progress_lock:
            in_progress_urls.discard(clean_url)

    if os.path.exists(target_mp3) and os.path.getsize(target_mp3) > 100000:
        return target_mp3
    return None

class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True

class AudioHandler(BaseHTTPRequestHandler):
    def send_cors(self):
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, HEAD, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Range, Content-Type')

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_cors()
        self.end_headers()

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        params = urllib.parse.parse_qs(parsed.query)

        if parsed.path == '/health' or parsed.path == '/':
            self.send_response(200)
            self.send_cors()
            self.send_header('Content-Type', 'text/plain')
            self.end_headers()
            self.wfile.write(b"AntiCensor Cloud Bridge: OK")
            return

        if parsed.path == '/preload' and 'url' in params:
            sc_url = params['url'][0]
            threading.Thread(target=resolve_sc_to_file, args=(sc_url,), daemon=True).start()
            self.send_response(200)
            self.send_cors()
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
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
            self.wfile.write(json.dumps({"ready": bool(is_ready)}).encode('utf-8'))
            return

        file_to_stream = None
        if parsed.path == '/sc' and 'url' in params:
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
                    self.send_header('Content-Type', 'audio/mpeg')
                    self.send_header('Content-Range', f'bytes {start}-{end}/{file_size}')
                    self.send_header('Content-Length', str(length))
                    self.send_header('Accept-Ranges', 'bytes')
                    self.end_headers()

                    with open(file_to_stream, 'rb') as f:
                        f.seek(start)
                        self.wfile.write(f.read(length))
                    return

            self.send_response(200)
            self.send_cors()
            self.send_header('Content-Type', 'audio/mpeg')
            self.send_header('Content-Length', str(file_size))
            self.send_header('Accept-Ranges', 'bytes')
            self.end_headers()

            with open(file_to_stream, 'rb') as f:
                self.wfile.write(f.read())
        except (ConnectionResetError, BrokenPipeError, ConnectionAbortedError):
            pass

if __name__ == '__main__':
    server = ThreadedHTTPServer(('0.0.0.0', PORT), AudioHandler)
    print(f"[AntiCensor] Cloud Bridge listening on 0.0.0.0:{PORT}")
    server.serve_forever()