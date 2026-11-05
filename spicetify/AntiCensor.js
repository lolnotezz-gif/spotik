(function () {
  "use strict";

  const DEFAULT_CLOUD_SERVER = "https://spotik-in4b.onrender.com";
  let activeServerUrl = DEFAULT_CLOUD_SERVER;
  const ALBUM_COVER_URL = `${DEFAULT_CLOUD_SERVER}/audio/cover.jpg`;
  const VOLUME_KEY = "anticensor_user_volume";
  const OVERRIDES_KEY = "anticensor_overrides";

  // --- BUILT-IN ALBUM & TRACK OVERRIDES ---
  const BUILTIN_ALBUM_TRACKS = [
    { num: 1, id: "0bzO2aZbO7RN0tl50wsCJz", uri: "spotify:track:0bzO2aZbO7RN0tl50wsCJz", title: "ONE WEEK RECORD", duration: 140, file: "one_week_record.mp3", aliases: ["one week record"] },
    { num: 2, id: "0uWNvKc0B1OZsLMzlUzbpD", uri: "spotify:track:0uWNvKc0B1OZsLMzlUzbpD", title: "NeedForSpeed", duration: 123, file: "needforspeed.mp3", aliases: ["needforspeed"] },
    { num: 3, id: "4YsCP1lZbeMlCaUT0ONML1", uri: "spotify:track:4YsCP1lZbeMlCaUT0ONML1", title: "$enpa1", duration: 172, file: "senpa1.mp3", aliases: ["$enpa1", "senpa1"] },
    { num: 4, id: "6DlxijdnCniTi2jRL7xfIO", uri: "spotify:track:6DlxijdnCniTi2jRL7xfIO", title: "ХУЛИЁУ", duration: 121, file: "deyti.mp3", aliases: ["хулиёу", "дейти"] },
    { num: 5, id: "49Aozh4YVr0sYx0rkCmNNU", uri: "spotify:track:49Aozh4YVr0sYx0rkCmNNU", title: "КРЫША", duration: 135, file: "krysha.mp3", aliases: ["крыша"] },
    { num: 6, id: "22m03tWYBVctgdByCu2ohS", uri: "spotify:track:22m03tWYBVctgdByCu2ohS", title: "ФАНТАСТИЧЕСКИЕ ТВАРИ - ver.2", duration: 101, file: "tvari.mp3", aliases: ["фантастические твари - ver.2", "фантастические твари"] },
    { num: 7, id: "0efigJN3XSbD3xvjDLSCYY", uri: "spotify:track:0efigJN3XSbD3xvjDLSCYY", title: "Я не виноват что... Больше", duration: 115, file: "ya_ne_vinovat.mp3", aliases: ["я не виноват что больше", "я не виноват что... больше"] },
    { num: 8, id: "5JsbDzwDiKjCuNGh7KE2Ja", uri: "spotify:track:5JsbDzwDiKjCuNGh7KE2Ja", title: "FUCK IT", duration: 125, file: "fuckit.mp3", aliases: ["fuck it"] },
    { num: 9, id: "1PbTwCZ4vihqw5bZc42Suj", uri: "spotify:track:1PbTwCZ4vihqw5bZc42Suj", title: "$HAKE YOUR A$$", duration: 177, file: "shake_your_ass.mp3", aliases: ["$hake your a$$", "shake your ass"] },
    { num: 10, id: "02NrEHtVoV0QOGxsQHJ0id", uri: "spotify:track:02NrEHtVoV0QOGxsQHJ0id", title: "МРАЗОТИК", duration: 106, file: "son.mp3", aliases: ["мразотик", "сон"] },
    { num: 11, id: "035FY0eysDZd9akX73iKok", uri: "spotify:track:035FY0eysDZd9akX73iKok", title: "NOTIME", duration: 106, file: "notime.mp3", aliases: ["notime"] },
    { num: 12, id: "0qitLkJ4pa1MkHQ1sCoJh1", uri: "spotify:track:0qitLkJ4pa1MkHQ1sCoJh1", title: "ЧЁТНЫЙ - Bonus Track", duration: 82, file: "eyforiya.mp3", aliases: ["чётный", "чётный - bonus track", "эйфория"] }
  ];

  function normalizeKey(str) {
    if (!str || typeof str !== "string") return "";
    return str.toLowerCase().replace(/•|\.\.\./g, "").replace(/\s+/g, " ").trim();
  }

  const BUILTIN_OVERRIDES = {};
  for (const tr of BUILTIN_ALBUM_TRACKS) {
    const url = `/audio/${tr.file}`;
    BUILTIN_OVERRIDES[tr.uri] = url;
    BUILTIN_OVERRIDES[tr.uri.toLowerCase()] = url;
    BUILTIN_OVERRIDES[tr.id] = url;
    BUILTIN_OVERRIDES[normalizeKey(`m1raontheblock - ${tr.title}`)] = url;
    for (const a of tr.aliases) {
      BUILTIN_OVERRIDES[normalizeKey(`m1raontheblock - ${a}`)] = url;
    }
  }
  BUILTIN_OVERRIDES["spotify:track:2nryvrkn55a0leqvd2eduq"] = "https://on.soundcloud.com/toxh9rgoOq8q9SJ5xt";
  BUILTIN_OVERRIDES["2nryvrkn55a0leqvd2eduq"] = "https://on.soundcloud.com/toxh9rgoOq8q9SJ5xt";
  BUILTIN_OVERRIDES["flip phone twerk"] = "https://on.soundcloud.com/toxh9rgoOq8q9SJ5xt";
  BUILTIN_OVERRIDES["spotify:track:1vqfh4jra1tfndlhuan5ne"] = "https://on.soundcloud.com/YiLKhavIH9btKwTbIf";
  BUILTIN_OVERRIDES["1vqfh4jra1tfndlhuan5ne"] = "https://on.soundcloud.com/YiLKhavIH9btKwTbIf";
  BUILTIN_OVERRIDES[normalizeKey("стеклянный")] = "https://on.soundcloud.com/YiLKhavIH9btKwTbIf";

  // --- STYLING: FULL UN-GREYING & SPOTIFY NATIVE VISUALS ---
  function injectAntiCensorStyles() {
    if (document.getElementById("anticensor-css")) return;
    const style = document.createElement("style");
    style.id = "anticensor-css";
    style.textContent = `
      /* 1. COMPLETELY UN-GREY AND ENABLE ALL TRACKLIST ROWS */
      .xwwlUJUZLpjPnZByq04Y.uWhqNrxEmH2qfzeRF1d2 .bP3x1wllVQ1e_m3Zso8t>*,
      .xwwlUJUZLpjPnZByq04Y.uWhqNrxEmH2qfzeRF1d2 .VESw5vtnhlL6UMqsWdUi>*,
      .xwwlUJUZLpjPnZByq04Y.uWhqNrxEmH2qfzeRF1d2 .kuBr0neXe5GgP1fzG1G_>*,
      .xwwlUJUZLpjPnZByq04Y.uWhqNrxEmH2qfzeRF1d2 .OpUv9X6_j1GIyZLFemUL>*,
      .xwwlUJUZLpjPnZByq04Y.uWhqNrxEmH2qfzeRF1d2,
      .xwwlUJUZLpjPnZByq04Y.uWhqNrxEmH2qfzeRF1d2 *,
      .xwwlUJUZLpjPnZByq04Y,
      .xwwlUJUZLpjPnZByq04Y *,
      div[role="row"],
      div[role="row"] *,
      [aria-disabled="true"],
      [aria-disabled="true"] * {
        opacity: 1 !important;
      }

      .xwwlUJUZLpjPnZByq04Y,
      div[role="row"] {
        cursor: pointer !important;
        pointer-events: auto !important;
      }

      /* 2. NON-ACTIVE TRACK TITLES: Bright clean white (#ffffff) */
      .xwwlUJUZLpjPnZByq04Y:not(.anticensor-active) .WefHxIjXRkivXjQbBdqC,
      .xwwlUJUZLpjPnZByq04Y:not(.anticensor-active) [data-encore-id="text"],
      .xwwlUJUZLpjPnZByq04Y:not(.anticensor-active) .standalone-ellipsis-one-line,
      .xwwlUJUZLpjPnZByq04Y:not(.anticensor-active) div[dir="auto"],
      .xwwlUJUZLpjPnZByq04Y:not(.anticensor-active) a[data-testid="internal-track-link"],
      div[role="row"]:not(.anticensor-active) .WefHxIjXRkivXjQbBdqC,
      div[role="row"]:not(.anticensor-active) [data-encore-id="text"],
      div[role="row"]:not(.anticensor-active) .standalone-ellipsis-one-line,
      div[role="row"]:not(.anticensor-active) div[dir="auto"] {
        color: #ffffff !important;
        opacity: 1 !important;
      }

      /* 3. ARTIST / SUBTITLES: Standard Spotify gray (#b3b3b3) */
      .xwwlUJUZLpjPnZByq04Y .whxt7rw253OMte8aB8Je,
      .xwwlUJUZLpjPnZByq04Y .whxt7rw253OMte8aB8Je a,
      .xwwlUJUZLpjPnZByq04Y [data-encore-id="textSecondary"],
      div[role="row"] .whxt7rw253OMte8aB8Je,
      div[role="row"] .whxt7rw253OMte8aB8Je a,
      div[role="row"] [data-encore-id="textSecondary"],
      div[role="row"] a[href*="/artist/"] {
        color: #b3b3b3 !important;
        opacity: 1 !important;
      }

      /* 4. TRACK NUMBERS & DURATION: #b3b3b3 by default */
      .xwwlUJUZLpjPnZByq04Y:not(.anticensor-active) .Aa8Q1IvIum3HH4nBBx9U,
      div[role="row"]:not(.anticensor-active) .Aa8Q1IvIum3HH4nBBx9U,
      div[role="row"]:not(.anticensor-active) [class*="number"],
      .xwwlUJUZLpjPnZByq04Y [aria-colindex="3"],
      .xwwlUJUZLpjPnZByq04Y [aria-colindex="4"],
      div[role="row"] [aria-colindex="3"],
      div[role="row"] [aria-colindex="4"],
      div[role="row"] [class*="duration"] {
        color: #b3b3b3 !important;
        opacity: 1 !important;
      }

      /* 5. HOVER EFFECTS ON ROW */
      .xwwlUJUZLpjPnZByq04Y:hover,
      div[role="row"]:hover {
        background-color: hsla(0, 0%, 100%, 0.1) !important;
      }
      .xwwlUJUZLpjPnZByq04Y:hover .whxt7rw253OMte8aB8Je a,
      div[role="row"]:hover .whxt7rw253OMte8aB8Je a {
        color: #ffffff !important;
      }
      .xwwlUJUZLpjPnZByq04Y:hover .l9kmLysnmcseyWh8xf0E,
      div[role="row"]:hover .l9kmLysnmcseyWh8xf0E {
        opacity: 1 !important;
        pointer-events: auto !important;
        position: absolute !important;
        display: flex !important;
      }
      .xwwlUJUZLpjPnZByq04Y:hover .Aa8Q1IvIum3HH4nBBx9U,
      div[role="row"]:hover .Aa8Q1IvIum3HH4nBBx9U {
        display: none !important;
      }

      /* 6. ONLY CURRENTLY PLAYING/ACTIVE TRACK IS SPOTIFY GREEN (#1ed760) */
      .xwwlUJUZLpjPnZByq04Y.anticensor-active .WefHxIjXRkivXjQbBdqC,
      .xwwlUJUZLpjPnZByq04Y.anticensor-active [data-encore-id="text"],
      .xwwlUJUZLpjPnZByq04Y.anticensor-active .standalone-ellipsis-one-line,
      .xwwlUJUZLpjPnZByq04Y.anticensor-active div[dir="auto"],
      .xwwlUJUZLpjPnZByq04Y.anticensor-active a[data-testid="internal-track-link"],
      .xwwlUJUZLpjPnZByq04Y.anticensor-active .Aa8Q1IvIum3HH4nBBx9U,
      div[role="row"].anticensor-active .WefHxIjXRkivXjQbBdqC,
      div[role="row"].anticensor-active [data-encore-id="text"],
      div[role="row"].anticensor-active .standalone-ellipsis-one-line,
      div[role="row"].anticensor-active div[dir="auto"],
      div[role="row"].anticensor-active .Aa8Q1IvIum3HH4nBBx9U {
        color: #1ed760 !important;
        opacity: 1 !important;
      }

      /* 7. SCRUBBER BAR HOVER EFFECTS */
      #anticensor-progress-bg:hover #anticensor-progress-fill,
      #anticensor-progress-bg.dragging #anticensor-progress-fill {
        background-color: #1ed760 !important;
      }
      #anticensor-progress-bg:hover #anticensor-progress-thumb,
      #anticensor-progress-bg.dragging #anticensor-progress-thumb {
        display: block !important;
      }
    `;
    (document.head || document.documentElement).appendChild(style);
  }

  function cleanTracklistRows() {
    injectAntiCensorStyles();
    const rows = document.querySelectorAll('div[role="row"], .xwwlUJUZLpjPnZByq04Y, [class*="trackListRow"], div[aria-rowindex]');
    for (let idx = 0; idx < rows.length; idx++) {
      const r = rows[idx];
      if (r.classList.contains("uWhqNrxEmH2qfzeRF1d2")) {
        r.classList.remove("uWhqNrxEmH2qfzeRF1d2");
      }
      if (!r.classList.contains("ePDoBsKYsPGyHgQlcLIb")) {
        r.classList.add("ePDoBsKYsPGyHgQlcLIb");
      }
      if (r.getAttribute("aria-disabled") === "true") {
        r.removeAttribute("aria-disabled");
      }

      let rowIndex = -1;
      const ariaRowIndex = r.getAttribute("aria-rowindex");
      if (ariaRowIndex) {
        const parsed = parseInt(ariaRowIndex, 10);
        if (!isNaN(parsed) && parsed >= 2) {
          rowIndex = parsed - 2;
        }
      } else {
        rowIndex = idx;
      }

      const isCurrentActive = currentPlayingTrackIndex >= 0 && rowIndex === currentPlayingTrackIndex;
      if (isCurrentActive) {
        if (!r.classList.contains("anticensor-active")) {
          r.classList.add("anticensor-active");
        }
        if (!r.classList.contains("Q_VN_DjnfmJnnbShT4rU")) {
          r.classList.add("Q_VN_DjnfmJnnbShT4rU");
        }
      } else {
        if (r.classList.contains("anticensor-active")) {
          r.classList.remove("anticensor-active");
        }
        if (r.classList.contains("Q_VN_DjnfmJnnbShT4rU")) {
          r.classList.remove("Q_VN_DjnfmJnnbShT4rU");
        }
      }
    }
  }

  function formatTime(sec) {
    if (isNaN(sec) || sec < 0) return "0:00";
    const m = Math.floor(sec / 60);
    const s = Math.floor(sec % 60);
    return `${m}:${s < 10 ? "0" : ""}${s}`;
  }

  function getOverrides() {
    let local = {};
    try {
      const raw = localStorage.getItem(OVERRIDES_KEY);
      local = raw ? JSON.parse(raw) : {};
    } catch (_) { local = {}; }
    return Object.assign({}, BUILTIN_OVERRIDES, local);
  }

  function getReplacementUrlForInfo(info) {
    if (!info) return undefined;
    const ov = getOverrides();

    if (info.id && ov[info.id]) return ov[info.id];
    if (info.uri && ov[info.uri]) return ov[info.uri];
    if (info.uri && ov[info.uri.toLowerCase()]) return ov[info.uri.toLowerCase()];

    if (info.artist && info.title) {
      const fullKey = normalizeKey(`${info.artist} - ${info.title}`);
      if (ov[fullKey]) return ov[fullKey];
    }

    if (info.title) {
      const titleLower = normalizeKey(info.title);
      for (const tr of BUILTIN_ALBUM_TRACKS) {
        if (titleLower === normalizeKey(tr.title) || tr.aliases.some(a => titleLower === normalizeKey(a))) {
          return `/audio/${tr.file}`;
        }
      }
    }

    return undefined;
  }

  function trackIdFromUri(uri) {
    if (!uri || typeof uri !== "string") return null;
    const clean = uri.split("?")[0].trim();
    const parts = clean.split(":");
    return (parts[0] === "spotify" && parts[1] === "track" && parts[2]) ? parts[2] : clean;
  }

  function pauseAllSpotifyPlayback() {
    try { Spicetify.Player?.pause(); } catch (_) {}
    try { Spicetify.Platform?.PlayerAPI?.pause(); } catch (_) {}
    try { Spicetify.PlaybackControl?.pause(); } catch (_) {}
  }

  // --- PLAYER STATE ---
  let ourAudio = null;
  let isAntiCensorPlaying = false;
  let activeSessionId = 0;
  let currentPlayingTrackId = null;
  let currentPlayingTrackIndex = -1;
  let currentPlayingTrackTitle = "";
  let userVolume = 1.0;
  let progressInterval = null;
  let isDraggingProgress = false;

  try {
    const saved = localStorage.getItem(VOLUME_KEY);
    if (saved !== null && !isNaN(parseFloat(saved))) {
      const parsed = parseFloat(saved);
      if (parsed > 0.05 && parsed <= 1) userVolume = parsed;
    }
  } catch (_) {}

  function setUserVolume(vol) {
    if (typeof vol !== "number" || isNaN(vol)) return;
    if (vol >= 0 && vol <= 1) {
      userVolume = vol;
      try { localStorage.setItem(VOLUME_KEY, userVolume.toString()); } catch (_) {}
    }
    if (ourAudio) {
      ourAudio.volume = userVolume;
    }
  }

  function getStreamUrl(inputUrl) {
    if (!inputUrl) return null;
    const u = inputUrl.trim();
    if (u.startsWith("/audio/")) {
      return `${activeServerUrl}${u}`;
    }
    if (u.includes("/audio/")) {
      const fname = u.split("/audio/")[1];
      return `${activeServerUrl}/audio/${fname}`;
    }
    if (u.includes("soundcloud.com/") || u.includes("on.soundcloud.com/")) {
      return `${activeServerUrl}/sc?url=${encodeURIComponent(u)}`;
    }
    return u;
  }

  function stopReplacement() {
    activeSessionId++;
    currentPlayingTrackId = null;
    currentPlayingTrackIndex = -1;
    currentPlayingTrackTitle = "";
    isAntiCensorPlaying = false;

    if (progressInterval) {
      clearInterval(progressInterval);
      progressInterval = null;
    }

    if (ourAudio) {
      try {
        ourAudio.pause();
        ourAudio.removeAttribute("src");
        ourAudio.load();
        ourAudio.remove();
      } catch (_) {}
      ourAudio = null;
    }

    cleanTracklistRows();
    hideCustomPlayerUI();
    updatePlayPauseButtonIcons(false);
  }

  function playNextAlbumTrack() {
    if (currentPlayingTrackIndex >= 0 && currentPlayingTrackIndex < BUILTIN_ALBUM_TRACKS.length - 1) {
      const nextIdx = currentPlayingTrackIndex + 1;
      const nextTr = BUILTIN_ALBUM_TRACKS[nextIdx];
      startReplacement(nextTr.id, `/audio/${nextTr.file}`, 0, nextIdx, nextTr.title);
    } else if (currentPlayingTrackIndex >= BUILTIN_ALBUM_TRACKS.length - 1) {
      stopReplacement();
    }
  }

  function playPrevAlbumTrack() {
    if (ourAudio && ourAudio.currentTime > 3.0) {
      ourAudio.currentTime = 0;
      updatePlayerBarUI();
      return;
    }
    if (currentPlayingTrackIndex > 0) {
      const prevIdx = currentPlayingTrackIndex - 1;
      const prevTr = BUILTIN_ALBUM_TRACKS[prevIdx];
      startReplacement(prevTr.id, `/audio/${prevTr.file}`, 0, prevIdx, prevTr.title);
    } else if (ourAudio) {
      ourAudio.currentTime = 0;
      updatePlayerBarUI();
    }
  }

  // --- BOTTOM PLAYER BAR UI INJECTION & ISOLATION ---
  function getNowPlayingBarContainers() {
    const bar = document.querySelector('.main-nowPlayingBar-container, [data-testid="now-playing-bar"], .hoqvQKg_ytpgc8RtcA5G, .XvuTwlgQRqJ5NnVLN9ZH, aside');
    if (!bar) return { bar: null, left: null, center: null, right: null };

    const left = bar.querySelector('.main-nowPlayingBar-left') || bar.children[0]?.children?.[0] || null;
    const center = bar.querySelector('.main-nowPlayingBar-center') || bar.children[0]?.children?.[1] || null;
    const right = bar.querySelector('.main-nowPlayingBar-right') || bar.children[0]?.children?.[2] || null;

    return { bar, left, center, right };
  }

  function ensurePlayerBarElements() {
    const { bar, left, center } = getNowPlayingBarContainers();
    if (!bar) return;

    const hasOurAudio = !!ourAudio;

    // 1. Left Container: Isolate completely so NO native track overlays!
    if (left) {
      let customLeft = document.getElementById("anticensor-nowplaying-left");
      if (!customLeft) {
        customLeft = document.createElement("div");
        customLeft.id = "anticensor-nowplaying-left";
        customLeft.style.cssText = "display: flex; align-items: center; width: auto; height: 56px;";
        customLeft.innerHTML = `
          <div style="width: 56px; height: 56px; border-radius: 4px; overflow: hidden; margin-right: 12px; flex-shrink: 0; box-shadow: 0 0 10px rgba(0,0,0,0.3);">
            <img id="anticensor-cover-img" src="${ALBUM_COVER_URL}" style="width: 100%; height: 100%; object-fit: cover; display: block;" />
          </div>
          <div style="display: flex; flex-direction: column; justify-content: center; overflow: hidden; margin-right: 12px; max-width: 250px;">
            <div id="anticensor-track-title" style="color: #ffffff; font-size: 14px; font-weight: 700; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; font-family: var(--font-family, sans-serif); line-height: 1.2;"></div>
            <div id="anticensor-track-artist" style="color: #b3b3b3; font-size: 11px; margin-top: 4px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; font-family: var(--font-family, sans-serif); line-height: 1.2;">m1raOnTheBlock</div>
          </div>
          <button id="anticensor-like-btn" title="Сохранить в Любимые" style="background: none; border: none; color: #1ed760; cursor: pointer; padding: 4px; display: flex; align-items: center; flex-shrink: 0;">
            <svg role="img" height="16" width="16" viewBox="0 0 16 16" fill="currentColor">
              <path d="M15.724 4.22A4.313 4.313 0 0 0 12.192.814a4.269 4.269 0 0 0-3.622 1.13.837.837 0 0 1-1.14 0 4.272 4.272 0 0 0-3.62-1.13A4.315 4.315 0 0 0 .276 4.22c-.6 2.404.303 4.908 2.712 7.457 2.015 2.133 4.417 3.659 4.623 3.788a.72.72 0 0 0 .778 0c.206-.129 2.608-1.655 4.623-3.788 2.409-2.549 3.313-5.053 2.712-7.457z"></path>
            </svg>
          </button>
        `;
        left.appendChild(customLeft);
      }

      if (hasOurAudio) {
        customLeft.style.display = "flex";
        // Hide every other child in left column with !important
        for (let i = 0; i < left.children.length; i++) {
          const c = left.children[i];
          if (c !== customLeft) {
            c.style.setProperty("display", "none", "important");
          }
        }
      } else {
        customLeft.style.display = "none";
        for (let i = 0; i < left.children.length; i++) {
          const c = left.children[i];
          if (c !== customLeft) {
            c.style.removeProperty("display");
          }
        }
      }
    }

    // 2. Center Container: Insert scrubber INSIDE player-controls so it occupies the exact playback-bar slot
    if (center) {
      const controls = center.querySelector('[data-testid="player-controls"], ._b8eissBsp4_ca4mU_sz') || center;
      const nativePlaybackBar = controls.querySelector('.playback-bar');

      let customBar = document.getElementById("anticensor-playback-bar");
      if (!customBar) {
        customBar = document.createElement("div");
        customBar.id = "anticensor-playback-bar";
        customBar.style.cssText = "display: flex; align-items: center; width: 100%; max-width: 722px; gap: 8px; height: 24px; user-select: none;";
        customBar.innerHTML = `
          <div id="anticensor-time-pos" style="color: #a7a7a7; font-size: 11px; min-width: 40px; text-align: right; font-family: var(--font-family, sans-serif); font-variant-numeric: tabular-nums;">0:00</div>
          <div id="anticensor-progress-bg" style="position: relative; flex-grow: 1; height: 4px; background: hsla(0,0%,100%,.3); border-radius: 2px; cursor: pointer;">
            <div id="anticensor-progress-fill" style="position: absolute; left: 0; top: 0; height: 100%; width: 0%; background: #ffffff; border-radius: 2px; pointer-events: none; transition: width 0.1s linear;"></div>
            <div id="anticensor-progress-thumb" style="position: absolute; top: 50%; width: 12px; height: 12px; border-radius: 50%; background: #ffffff; transform: translate(-50%, -50%); display: none; pointer-events: none; box-shadow: 0 2px 4px rgba(0,0,0,0.5);"></div>
          </div>
          <div id="anticensor-time-dur" style="color: #a7a7a7; font-size: 11px; min-width: 40px; text-align: left; font-family: var(--font-family, sans-serif); font-variant-numeric: tabular-nums;">0:00</div>
        `;
        if (nativePlaybackBar && nativePlaybackBar.parentNode) {
          nativePlaybackBar.parentNode.insertBefore(customBar, nativePlaybackBar.nextSibling);
        } else {
          controls.appendChild(customBar);
        }
        setupScrubberListeners(customBar);
      }

      if (hasOurAudio) {
        customBar.style.display = "flex";
        if (nativePlaybackBar) {
          nativePlaybackBar.style.setProperty("display", "none", "important");
        }
      } else {
        customBar.style.display = "none";
        if (nativePlaybackBar) {
          nativePlaybackBar.style.removeProperty("display");
        }
      }
    }
  }

  function hideCustomPlayerUI() {
    const customLeft = document.getElementById("anticensor-nowplaying-left");
    if (customLeft) customLeft.style.display = "none";

    const customBar = document.getElementById("anticensor-playback-bar");
    if (customBar) customBar.style.display = "none";

    const { left, center } = getNowPlayingBarContainers();
    if (left) {
      for (let i = 0; i < left.children.length; i++) {
        const c = left.children[i];
        if (c !== customLeft) {
          c.style.removeProperty("display");
        }
      }
    }
    if (center) {
      const controls = center.querySelector('[data-testid="player-controls"], ._b8eissBsp4_ca4mU_sz') || center;
      const nativePlaybackBar = controls.querySelector('.playback-bar');
      if (nativePlaybackBar) {
        nativePlaybackBar.style.removeProperty("display");
      }
    }
  }

  function setupScrubberListeners(customBar) {
    const bg = customBar.querySelector("#anticensor-progress-bg");
    if (!bg) return;

    function seekToEvent(e) {
      if (!ourAudio) return;
      let dur = ourAudio.duration;
      if (!dur || isNaN(dur) || dur < 1) {
        if (currentPlayingTrackIndex >= 0 && currentPlayingTrackIndex < BUILTIN_ALBUM_TRACKS.length) {
          dur = BUILTIN_ALBUM_TRACKS[currentPlayingTrackIndex].duration || 140;
        } else {
          dur = 140;
        }
      }
      const rect = bg.getBoundingClientRect();
      const clickX = e.clientX - rect.left;
      const width = rect.width;
      if (width > 0) {
        const fraction = Math.max(0, Math.min(1, clickX / width));
        ourAudio.currentTime = fraction * dur;
        updatePlayerBarUI();
      }
    }

    bg.addEventListener("click", (e) => {
      e.preventDefault();
      e.stopPropagation();
      seekToEvent(e);
    });

    bg.addEventListener("mousedown", (e) => {
      isDraggingProgress = true;
      bg.classList.add("dragging");
      seekToEvent(e);
    });

    window.addEventListener("mousemove", (e) => {
      if (isDraggingProgress) {
        seekToEvent(e);
      }
    });

    window.addEventListener("mouseup", () => {
      if (isDraggingProgress) {
        isDraggingProgress = false;
        bg.classList.remove("dragging");
      }
    });
  }

  function updatePlayPauseButtonIcons(isPlaying) {
    const playPauseBtns = document.querySelectorAll('[data-testid="control-button-playpause"], .player-controls__buttons button:nth-child(3)');
    playPauseBtns.forEach(btn => {
      btn.setAttribute("aria-label", isPlaying ? "Пауза" : "Играть");
      const svg = btn.querySelector("svg");
      if (svg) {
        if (isPlaying) {
          svg.innerHTML = '<path d="M2.7 1a.7.7 0 0 0-.7.7v12.6a.7.7 0 0 0 .7.7h2.6a.7.7 0 0 0 .7-.7V1.7a.7.7 0 0 0-.7-.7H2.7zm8 0a.7.7 0 0 0-.7.7v12.6a.7.7 0 0 0 .7.7h2.6a.7.7 0 0 0 .7-.7V1.7a.7.7 0 0 0-.7-.7h-2.6z"></path>';
        } else {
          svg.innerHTML = '<path d="M3 1.713a.7.7 0 0 1 1.05-.607l10.89 6.288a.7.7 0 0 1 0 1.212L4.05 14.894A.7.7 0 0 1 3 14.287V1.713z"></path>';
        }
      }
    });

    const bigPlayBtns = document.querySelectorAll('button[data-testid="play-button"], button[data-testid="action-bar-button"], .action-bar-button');
    bigPlayBtns.forEach(btn => {
      const isAlbum = window.location.href.includes("1f1OCxkJ43A1qy9qqFNfuX") || document.title.includes("Coll. of $hiT") || document.querySelector('h1')?.textContent?.includes("Coll. of $hiT");
      if (isAlbum) {
        const svg = btn.querySelector("svg");
        if (svg) {
          if (isPlaying) {
            svg.innerHTML = '<path d="M2.7 1a.7.7 0 0 0-.7.7v12.6a.7.7 0 0 0 .7.7h2.6a.7.7 0 0 0 .7-.7V1.7a.7.7 0 0 0-.7-.7H2.7zm8 0a.7.7 0 0 0-.7.7v12.6a.7.7 0 0 0 .7.7h2.6a.7.7 0 0 0 .7-.7V1.7a.7.7 0 0 0-.7-.7h-2.6z"></path>';
          } else {
            svg.innerHTML = '<path d="M3 1.713a.7.7 0 0 1 1.05-.607l10.89 6.288a.7.7 0 0 1 0 1.212L4.05 14.894A.7.7 0 0 1 3 14.287V1.713z"></path>';
          }
        }
      }
    });
  }

  function updatePlayerBarUI() {
    if (!ourAudio) return;
    try {
      ensurePlayerBarElements();

      const curTime = ourAudio.currentTime || 0;
      let dur = ourAudio.duration;
      if (!dur || isNaN(dur) || dur < 1) {
        if (currentPlayingTrackIndex >= 0 && currentPlayingTrackIndex < BUILTIN_ALBUM_TRACKS.length) {
          dur = BUILTIN_ALBUM_TRACKS[currentPlayingTrackIndex].duration || 140;
        } else {
          dur = 140;
        }
      }

      const pct = Math.min(100, Math.max(0, (curTime / dur) * 100));

      const customTitle = document.getElementById("anticensor-track-title");
      if (customTitle && customTitle.textContent !== currentPlayingTrackTitle) {
        customTitle.textContent = currentPlayingTrackTitle;
        customTitle.setAttribute("title", currentPlayingTrackTitle);
      }

      const customPos = document.getElementById("anticensor-time-pos");
      if (customPos) customPos.textContent = formatTime(curTime);

      const customDur = document.getElementById("anticensor-time-dur");
      if (customDur) customDur.textContent = formatTime(dur);

      const customFill = document.getElementById("anticensor-progress-fill");
      if (customFill) customFill.style.width = pct + "%";

      const customThumb = document.getElementById("anticensor-progress-thumb");
      if (customThumb) customThumb.style.left = pct + "%";

      updatePlayPauseButtonIcons(!ourAudio.paused);
    } catch (_) {}
  }

  function setupNavButtons() {
    const skipFwdBtn = document.querySelector('button[data-testid="control-button-skip-forward"], .player-controls__buttons button:nth-child(4)');
    if (skipFwdBtn && !skipFwdBtn.hasAttribute("data-anticensor-nav")) {
      skipFwdBtn.setAttribute("data-anticensor-nav", "true");
      skipFwdBtn.addEventListener("click", (e) => {
        if (ourAudio || currentPlayingTrackIndex >= 0) {
          e.preventDefault();
          e.stopPropagation();
          playNextAlbumTrack();
        }
      }, true);
    }

    const skipBackBtn = document.querySelector('button[data-testid="control-button-skip-back"], .player-controls__buttons button:nth-child(2)');
    if (skipBackBtn && !skipBackBtn.hasAttribute("data-anticensor-nav")) {
      skipBackBtn.setAttribute("data-anticensor-nav", "true");
      skipBackBtn.addEventListener("click", (e) => {
        if (ourAudio || currentPlayingTrackIndex >= 0) {
          e.preventDefault();
          e.stopPropagation();
          playPrevAlbumTrack();
        }
      }, true);
    }
  }

  // --- START REPLACEMENT PLAYBACK ---
  function startReplacement(trackId, url, retryCount = 0, albumIndex = -1, explicitTitle = "") {
    const sessionId = ++activeSessionId;
    currentPlayingTrackId = trackId;

    if (albumIndex >= 0) {
      currentPlayingTrackIndex = albumIndex;
    } else {
      const foundIdx = BUILTIN_ALBUM_TRACKS.findIndex(t => t.id === trackId || t.uri === trackId || (explicitTitle && t.title.toLowerCase() === explicitTitle.toLowerCase()));
      if (foundIdx >= 0) currentPlayingTrackIndex = foundIdx;
    }

    if (currentPlayingTrackIndex >= 0 && currentPlayingTrackIndex < BUILTIN_ALBUM_TRACKS.length) {
      currentPlayingTrackTitle = explicitTitle || BUILTIN_ALBUM_TRACKS[currentPlayingTrackIndex].title;
    } else {
      currentPlayingTrackTitle = explicitTitle || trackId;
    }

    const streamUrl = getStreamUrl(url);
    if (!streamUrl) return;

    if (progressInterval) {
      clearInterval(progressInterval);
      progressInterval = null;
    }

    if (ourAudio) {
      try {
        ourAudio.pause();
        ourAudio.removeAttribute("src");
        ourAudio.load();
        ourAudio.remove();
      } catch (_) {}
      ourAudio = null;
    }

    console.log("[AntiCensor PC] Starting playback:", currentPlayingTrackTitle, "URL:", streamUrl);

    // Stop and pause ALL native / remote Spotify playback!
    pauseAllSpotifyPlayback();

    const audio = new Audio();
    audio.crossOrigin = "anonymous";
    audio.preload = "auto";
    audio.volume = (typeof userVolume === "number" && userVolume >= 0 && userVolume <= 1) ? userVolume : 1.0;
    audio.muted = false;
    ourAudio = audio;
    document.body.appendChild(audio);

    audio.addEventListener("error", (e) => {
      console.warn("[AntiCensor] Audio tag error:", audio.error, "URL:", streamUrl, "retry:", retryCount);
      if (sessionId !== activeSessionId) return;

      if (retryCount < 2) {
        setTimeout(() => {
          if (sessionId === activeSessionId) {
            startReplacement(trackId, url, retryCount + 1, albumIndex, explicitTitle);
          }
        }, 1500);
        return;
      }
      stopReplacement();
    });

    audio.addEventListener("ended", () => {
      if (sessionId === activeSessionId) {
        playNextAlbumTrack();
      }
    });

    audio.addEventListener("play", () => {
      if (sessionId === activeSessionId) {
        isAntiCensorPlaying = true;
        cleanTracklistRows();
        updatePlayerBarUI();
      }
    });

    audio.addEventListener("pause", () => {
      if (sessionId === activeSessionId) {
        isAntiCensorPlaying = false;
        cleanTracklistRows();
        updatePlayerBarUI();
      }
    });

    audio.src = streamUrl;
    audio.play().then(() => {
      isAntiCensorPlaying = true;
      cleanTracklistRows();
      setupNavButtons();
      updatePlayerBarUI();

      if (progressInterval) clearInterval(progressInterval);
      progressInterval = setInterval(() => {
        if (sessionId === activeSessionId && ourAudio && !ourAudio.paused && !isDraggingProgress) {
          updatePlayerBarUI();
          setupNavButtons();
        }
      }, 200);
    }).catch(err => {
      console.warn("[AntiCensor] Play promise rejected:", err);
    });
  }

  // --- CLICK INTERCEPTOR ---
  function handleTrackRowClick(evt) {
    // 1. Big green album play button
    const bigPlayBtn = evt.target && evt.target.closest && evt.target.closest('button[data-testid="play-button"], button[data-testid="action-bar-button"], .action-bar-button');
    if (bigPlayBtn) {
      const isAlbumPage = window.location.href.includes("1f1OCxkJ43A1qy9qqFNfuX") || document.title.includes("Coll. of $hiT") || document.querySelector('h1')?.textContent?.includes("Coll. of $hiT");
      if (isAlbumPage) {
        evt.preventDefault();
        evt.stopPropagation();
        evt.stopImmediatePropagation();
        if (ourAudio) {
          if (ourAudio.paused) {
            pauseAllSpotifyPlayback();
            ourAudio.play().catch(() => {});
          } else {
            ourAudio.pause();
          }
        } else {
          const tr = BUILTIN_ALBUM_TRACKS[0];
          startReplacement(tr.id, `/audio/${tr.file}`, 0, 0, tr.title);
        }
        return;
      }
    }

    // 2. Tracklist row
    const row = evt.target && evt.target.closest && evt.target.closest('div[role="row"], .xwwlUJUZLpjPnZByq04Y, [class*="trackListRow"], div[aria-rowindex]');
    if (!row) return;

    if (evt.target.closest('button[data-testid*="more"], button[data-testid*="context-menu"], button[aria-haspopup="menu"]')) {
      return;
    }

    let rowIndex = -1;
    const ariaRowIndex = row.getAttribute("aria-rowindex");
    if (ariaRowIndex) {
      const parsed = parseInt(ariaRowIndex, 10);
      if (!isNaN(parsed) && parsed >= 2) {
        rowIndex = parsed - 2;
      }
    }

    let title = "";
    const titleCandidates = row.querySelectorAll('.WefHxIjXRkivXjQbBdqC, [data-encore-id="text"], div[dir="auto"], .standalone-ellipsis-one-line, [class*="title"], [class*="trackName"]');
    for (const el of titleCandidates) {
      const txt = (el.textContent || "").trim();
      if (txt.length > 1 && !/^\d+$/.test(txt)) {
        title = txt;
        break;
      }
    }

    let uri = row.getAttribute("data-uri");
    let id = null;
    if (uri) {
      id = trackIdFromUri(uri);
    } else {
      const trackLink = row.querySelector('a[href*="/track/"]');
      if (trackLink) {
        const href = trackLink.getAttribute("href") || "";
        const m = href.match(/\/track\/([a-zA-Z0-9]+)/);
        if (m) {
          id = m[1];
          uri = `spotify:track:${id}`;
        }
      }
    }

    const isAlbumPage = window.location.href.includes("1f1OCxkJ43A1qy9qqFNfuX") || document.title.includes("Coll. of $hiT") || document.querySelector('h1')?.textContent?.includes("Coll. of $hiT");
    if (isAlbumPage && rowIndex >= 0 && rowIndex < BUILTIN_ALBUM_TRACKS.length) {
      const tr = BUILTIN_ALBUM_TRACKS[rowIndex];
      id = tr.id;
      uri = tr.uri;
      title = title || tr.title;
    }

    const repUrl = getReplacementUrlForInfo({ id, uri, title });
    if (repUrl) {
      evt.preventDefault();
      evt.stopPropagation();
      evt.stopImmediatePropagation();

      if (ourAudio && (currentPlayingTrackId === (id || uri || title) || (rowIndex >= 0 && rowIndex === currentPlayingTrackIndex))) {
        if (ourAudio.paused) {
          pauseAllSpotifyPlayback();
          ourAudio.play().catch(() => {});
        } else {
          ourAudio.pause();
        }
        return;
      }

      startReplacement(id || uri || title, repUrl, 0, rowIndex, title);
    }
  }

  async function waitReady() {
    while (!Spicetify?.Player?.addEventListener) {
      await new Promise(r => setTimeout(r, 100));
    }
  }

  async function init() {
    await waitReady();

    injectAntiCensorStyles();
    cleanTracklistRows();

    // High frequency cleaner for instant React virtual DOM reaction
    setInterval(cleanTracklistRows, 150);

    const observer = new MutationObserver(() => {
      cleanTracklistRows();
      if (ourAudio) {
        ensurePlayerBarElements();
      }
    });
    observer.observe(document.body, { childList: true, subtree: true });

    // Stop replacement if user plays normal Spotify music outside this album
    Spicetify.Player.addEventListener("songchange", () => {
      const track = Spicetify.Player.data?.item;
      if (track && ourAudio) {
        const rep = getReplacementUrlForInfo({ uri: track.uri, id: trackIdFromUri(track.uri), title: track.name });
        if (!rep) {
          stopReplacement();
        }
      }
    });

    // Volume slider input
    document.addEventListener("input", (evt) => {
      const isVolSlider = evt.target && evt.target.closest && evt.target.closest('[data-testid="volume-bar"], .volume-bar');
      if (isVolSlider && evt.target.type === "range") {
        const v = parseFloat(evt.target.value);
        if (!isNaN(v)) {
          setUserVolume(v);
        }
      }
    }, true);

    // Play/Pause button in bottom bar
    document.addEventListener("click", (evt) => {
      const playPauseBtn = evt.target && evt.target.closest && evt.target.closest('[data-testid="control-button-playpause"], .player-controls__buttons button:nth-child(3)');
      if (playPauseBtn && ourAudio) {
        evt.preventDefault();
        evt.stopPropagation();
        if (ourAudio.paused) {
          pauseAllSpotifyPlayback();
          ourAudio.play().catch(() => {});
        } else {
          ourAudio.pause();
        }
      }
    }, true);

    // Spacebar
    window.addEventListener("keydown", (evt) => {
      if (evt.code === "Space" && !["INPUT", "TEXTAREA"].includes(evt.target?.tagName)) {
        if (ourAudio) {
          evt.preventDefault();
          if (ourAudio.paused) {
            pauseAllSpotifyPlayback();
            ourAudio.play().catch(() => {});
          } else {
            ourAudio.pause();
          }
        }
      }
    }, true);

    // Capture click and double-click on rows
    document.addEventListener("click", handleTrackRowClick, true);
    document.addEventListener("dblclick", handleTrackRowClick, true);

    setupNavButtons();
  }

  init();
})();
