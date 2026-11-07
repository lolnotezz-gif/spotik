import os
import sys
import time
import requests
import zipfile
import io

TOKEN = os.environ.get("GITHUB_TOKEN", "")
REPO = "lolnotezz-gif/spotik"
HEADERS = {
    "Authorization": f"Bearer {TOKEN}",
    "Accept": "application/vnd.github.v3+json",
    "User-Agent": "AntiCensor-Checker"
}

def check_runs():
    url = f"https://api.github.com/repos/{REPO}/actions/runs?per_page=5"
    r = requests.get(url, headers=HEADERS)
    if r.status_code != 200:
        print(f"Error fetching runs: {r.status_code} {r.text}")
        return None
    data = r.json()
    runs = data.get("workflow_runs", [])
    if not runs:
        print("No workflow runs found.")
        return None
    latest = runs[0]
    print(f"Run ID: {latest['id']} | Status: {latest['status']} | Conclusion: {latest['conclusion']} | Commit: {latest['head_commit']['id'][:7]} - {latest['head_commit']['message']}")
    return latest

def download_artifact(run_id, out_dir):
    url = f"https://api.github.com/repos/{REPO}/actions/runs/{run_id}/artifacts"
    r = requests.get(url, headers=HEADERS)
    if r.status_code != 200:
        print(f"Error fetching artifacts: {r.status_code}")
        return False
    artifacts = r.json().get("artifacts", [])
    if not artifacts:
        print("No artifacts found for this run.")
        return False
    
    target_art = next((a for a in artifacts if a["name"] == "AntiCensor.dylib"), artifacts[0])
    dl_url = target_art["archive_download_url"]
    print(f"Found artifact: {target_art['name']} ({target_art['size_in_bytes']} bytes). Downloading from {dl_url}...")
    
    # Download with redirect handling (strip Auth header for Azure Blob)
    session = requests.Session()
    # Initial request to GitHub
    resp = session.get(dl_url, headers=HEADERS, allow_redirects=False)
    if resp.status_code in (301, 302, 307):
        redirect_url = resp.headers["Location"]
        # Azure blob doesn't like github bearer token
        resp2 = requests.get(redirect_url)
        content = resp2.content
    else:
        content = resp.content
        
    os.makedirs(out_dir, exist_ok=True)
    with zipfile.ZipFile(io.BytesIO(content)) as z:
        z.extractall(out_dir)
        print(f"Extracted artifact to {out_dir}: {z.namelist()}")
    return True

if __name__ == "__main__":
    print("Checking GitHub Actions...")
    for _ in range(30):
        latest = check_runs()
        if latest and latest["status"] == "completed":
            if latest["conclusion"] == "success":
                out_dir = os.path.join(os.path.dirname(__file__), "build_output")
                download_artifact(latest["id"], out_dir)
                sys.exit(0)
            else:
                print(f"Build failed with conclusion: {latest['conclusion']}")
                sys.exit(1)
        time.sleep(10)

