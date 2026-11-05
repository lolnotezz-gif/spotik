(function () {
  const DEFAULT_CLOUD_SERVER = "https://spotik-in4b.onrender.com";
  const LOCAL_BRIDGE = "http://127.0.0.1:8989";
  let activeServerUrl = DEFAULT_CLOUD_SERVER;
  const ALBUM_COVER_URL = `${DEFAULT_CLOUD_SERVER}/audio/cover.jpg`;

  const VOLUME_KEY = "anticensor_user_volume";
  const OVERRIDES_KEY = "anticensor_overrides";
  const BLACKLIST_KEY = "anticensor_blacklist";
  const SERVER_CONFIG_KEY = "anticensor_server_url";
  const LYRICS_KEY = "anticensor_lyrics";

  const ru = {
    replaced: "🟢 Трек заменен на версию без цензуры!",
    saved: "Замена сохранена! Подключаем аудио...",
    removed: "Замена удалена",
    disabled: "Замена отключена для этого трека",
    menuReplace: "⚡ Заменить на версию без цензуры (MP3 или SoundCloud)",
    menuRemove: "❌ Удалить замену без цензуры",
    promptLabel: "Вставьте ссылку на SoundCloud или прямую ссылку на .mp3:",
    loading: "⚡ SoundCloud: загрузка трека...",
    waking: "⚡ AntiCensor: сервер подготавливает трек, подождите...",
    error: "AntiCensor: ошибка воспроизведения аудио",
  };

  const en = {
    replaced: "🟢 Track replaced with uncensored version!",
    saved: "Replacement saved! Connecting audio...",
    removed: "Replacement removed",
    disabled: "Replacement disabled for this track",
    menuReplace: "⚡ Replace with uncensored version (MP3 or SoundCloud)",
    menuRemove: "❌ Remove uncensored replacement",
    promptLabel: "Paste SoundCloud track URL or direct .mp3 link:",
    loading: "⚡ SoundCloud: downloading track...",
    waking: "⚡ AntiCensor: preparing track, retrying...",
    error: "AntiCensor: audio playback error",
  };

  const t = (navigator.language || "").toLowerCase().startsWith("ru") ? ru : en;

  // --- BUILT-IN ALBUM & TRACK OVERRIDES ---
  const BUILTIN_ALBUM_TRACKS = [
    { num: 1, id: "0bzO2aZbO7RN0tl50wsCJz", uri: "spotify:track:0bzO2aZbO7RN0tl50wsCJz", title: "ONE WEEK RECORD", duration: 141, file: "one_week_record.mp3", aliases: ["one week record"] },
    { num: 2, id: "0uWNvKc0B1OZsLMzlUzbpD", uri: "spotify:track:0uWNvKc0B1OZsLMzlUzbpD", title: "NeedForSpeed", duration: 125, file: "needforspeed.mp3", aliases: ["needforspeed"] },
    { num: 3, id: "4YsCP1lZbeMlCaUT0ONML1", uri: "spotify:track:4YsCP1lZbeMlCaUT0ONML1", title: "$enpa1", duration: 173, file: "senpa1.mp3", aliases: ["$enpa1", "senpa1"] },
    { num: 4, id: "6DlxijdnCniTi2jRL7xfIO", uri: "spotify:track:6DlxijdnCniTi2jRL7xfIO", title: "ХУЛИЁУ", duration: 122, file: "deyti.mp3", aliases: ["хулиёу", "дейти"] },
    { num: 5, id: "49Aozh4YVr0sYx0rkCmNNU", uri: "spotify:track:49Aozh4YVr0sYx0rkCmNNU", title: "КРЫША", duration: 138, file: "krysha.mp3", aliases: ["крыша"] },
    { num: 6, id: "22m03tWYBVctgdByCu2ohS", uri: "spotify:track:22m03tWYBVctgdByCu2ohS", title: "ФАНТАСТИЧЕСКИЕ ТВАРИ - ver.2", duration: 104, file: "tvari.mp3", aliases: ["фантастические твари - ver.2", "фантастические твари", "фантастические твари ver 2"] },
    { num: 7, id: "0efigJN3XSbD3xvjDLSCYY", uri: "spotify:track:0efigJN3XSbD3xvjDLSCYY", title: "Я не виноват что... Больше", duration: 116, file: "ya_ne_vinovat.mp3", aliases: ["я не виноват что больше", "я не виноват что... больше"] },
    { num: 8, id: "5JsbDzwDiKjCuNGh7KE2Ja", uri: "spotify:track:5JsbDzwDiKjCuNGh7KE2Ja", title: "FUCK IT", duration: 127, file: "fuckit.mp3", aliases: ["fuck it"] },
    { num: 9, id: "1PbTwCZ4vihqw5bZc42Suj", uri: "spotify:track:1PbTwCZ4vihqw5bZc42Suj", title: "$HAKE YOUR A$$", duration: 178, file: "shake_your_ass.mp3", aliases: ["$hake your a$$", "shake your ass"] },
    { num: 10, id: "02NrEHtVoV0QOGxsQHJ0id", uri: "spotify:track:02NrEHtVoV0QOGxsQHJ0id", title: "МРАЗОТИК", duration: 107, file: "son.mp3", aliases: ["мразотик", "сон"] },
    { num: 11, id: "035FY0eysDZd9akX73iKok", uri: "spotify:track:035FY0eysDZd9akX73iKok", title: "NOTIME", duration: 107, file: "notime.mp3", aliases: ["notime"] },
    { num: 12, id: "0qitLkJ4pa1MkHQ1sCoJh1", uri: "spotify:track:0qitLkJ4pa1MkHQ1sCoJh1", title: "ЧЁТНЫЙ - Bonus Track", duration: 83, file: "eyforiya.mp3", aliases: ["чётный", "чётный - bonus track", "эйфория", "эйфория - bonus track"] }
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
    BUILTIN_OVERRIDES[normalizeKey(tr.title)] = url;
    BUILTIN_OVERRIDES[normalizeKey(`m1raontheblock - ${tr.title}`)] = url;
    for (const a of tr.aliases) {
      BUILTIN_OVERRIDES[normalizeKey(a)] = url;
      BUILTIN_OVERRIDES[normalizeKey(`m1raontheblock - ${a}`)] = url;
    }
  }
  BUILTIN_OVERRIDES["spotify:track:2nryvrkn55a0leqvd2eduq"] = "https://on.soundcloud.com/toxh9rgoOq8q9SJ5xt";
  BUILTIN_OVERRIDES["flip phone twerk"] = "https://on.soundcloud.com/toxh9rgoOq8q9SJ5xt";
  BUILTIN_OVERRIDES["spotify:track:1vqfh4jra1tfndlhuan5ne"] = "https://on.soundcloud.com/YiLKhavIH9btKwTbIf";
  BUILTIN_OVERRIDES[normalizeKey("стеклянный")] = "https://on.soundcloud.com/YiLKhavIH9btKwTbIf";

  // --- UN-GREY DISABLED TRACKS VIA CSS INJECTION ---
  function injectAntiCensorStyles() {
    if (document.getElementById("anticensor-css")) return;
    const style = document.createElement("style");
    style.id = "anticensor-css";
    style.textContent = `
      /* AntiCensor: Un-grey all disabled/unplayable album tracks */
      [data-testid="tracklist-row"],
      [data-testid="tracklist-row"][aria-disabled="true"],
      .main-trackList-rowDisabled,
      .main-trackList-rowDisabled * {
        opacity: 1 !important;
        cursor: pointer !important;
        pointer-events: auto !important;
      }
      /* ONLY non-active tracks are pure white */
      [data-testid="tracklist-row"]:not([data-anticensor-active="true"]) [data-encore-id="text"],
      [data-testid="tracklist-row"]:not([data-anticensor-active="true"]) div[dir="auto"],
      [data-testid="tracklist-row"]:not([data-anticensor-active="true"]) .standalone-ellipsis-one-line,
      [data-testid="tracklist-row"]:not([data-anticensor-active="true"]) [class*="title"],
      .main-trackList-rowDisabled:not([data-anticensor-active="true"]) [data-encore-id="text"] {
        color: #ffffff !important;
      }
      /* Subtitles / artists */
      [data-testid="tracklist-row"] [data-encore-id="textSecondary"],
      [data-testid="tracklist-row"] a[href*="/artist/"],
      [data-testid="tracklist-row"] span[class*="artist"],
      .main-trackList-rowDisabled [data-encore-id="textSecondary"] {
        color: #b3b3b3 !important;
      }
      [data-testid="tracklist-row"]:hover {
        background-color: hsla(0, 0%, 100%, .1) !important;
      }
      /* ONLY actively playing track is green */
      [data-testid="tracklist-row"][data-anticensor-active="true"] [data-encore-id="text"],
      [data-testid="tracklist-row"][data-anticensor-active="true"] div[dir="auto"],
      [data-testid="tracklist-row"][data-anticensor-active="true"] .standalone-ellipsis-one-line,
      [data-testid="tracklist-row"][data-anticensor-active="true"] [class*="title"] {
        color: #1db954 !important;
      }
    `;
    (document.head || document.documentElement).appendChild(style);
  }

  function cleanTracklistRows() {
    injectAntiCensorStyles();
    const rows = document.querySelectorAll('[data-testid="tracklist-row"], [role="row"], .main-trackList-rowDisabled');
    for (const r of rows) {
      if (r.getAttribute("aria-disabled") === "true") {
        r.removeAttribute("aria-disabled");
      }
      if (r.classList.contains("main-trackList-rowDisabled")) {
        r.classList.remove("main-trackList-rowDisabled");
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
      const titleKey = normalizeKey(info.title);
      if (ov[titleKey]) return ov[titleKey];
    }

    return undefined;
  }

  function trackIdFromUri(uri) {
    if (!uri || typeof uri !== "string") return null;
    const clean = uri.split("?")[0].trim();
    const parts = clean.split(":");
    return (parts[0] === "spotify" && parts[1] === "track" && parts[2]) ? parts[2] : clean;
  }

  // --- Audio State ---
  let ourAudio = null;
  let isAntiCensorPlaying = false;
  let activeSessionId = 0;
  let currentPlayingTrackId = null;
  let currentPlayingTrackIndex = -1;
  let currentPlayingTrackTitle = "";
  let userVolume = 1.0;
  let progressInterval = null;

  try {
    const saved = localStorage.getItem(VOLUME_KEY);
    if (saved !== null && !isNaN(parseFloat(saved))) {
      const parsed = parseFloat(saved);
      if (parsed > 0.05 && parsed <= 1) userVolume = parsed;
    }
  } catch (_) {}

  function setUserVolume(vol) {
    if (typeof vol !== "number" || isNaN(vol)) return;
    if (vol > 0.01) {
      userVolume = Math.min(1, vol);
      try { localStorage.setItem(VOLUME_KEY, userVolume.toString()); } catch (_) {}
    }
    if (ourAudio) {
      ourAudio.volume = userVolume;
    }
  }

  function stopReplacement() {
    activeSessionId++;
    currentPlayingTrackId = null;
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

    updateUIForPlayback(false, "", "");
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

  function playNextAlbumTrack() {
    if (currentPlayingTrackIndex >= 0 && currentPlayingTrackIndex < BUILTIN_ALBUM_TRACKS.length - 1) {
      const nextTr = BUILTIN_ALBUM_TRACKS[currentPlayingTrackIndex + 1];
      const repUrl = `/audio/${nextTr.file}`;
      startReplacement(nextTr.id, repUrl, 0, nextTr.num - 1, nextTr.title);
    }
  }

  function playPrevAlbumTrack() {
    if (ourAudio && ourAudio.currentTime > 3.0) {
      ourAudio.currentTime = 0;
      updatePlayerBarUI();
      return;
    }
    if (currentPlayingTrackIndex > 0) {
      const prevTr = BUILTIN_ALBUM_TRACKS[currentPlayingTrackIndex - 1];
      const repUrl = `/audio/${prevTr.file}`;
      startReplacement(prevTr.id, repUrl, 0, prevTr.num - 1, prevTr.title);
    } else if (ourAudio) {
      ourAudio.currentTime = 0;
      updatePlayerBarUI();
    }
  }

  // --- UPDATE BOTTOM PLAYER BAR (COVER ART, TITLE, ARTIST, TIME, PROGRESS BAR) ---
  function updatePlayerBarUI() {
    if (!ourAudio) return;
    try {
      const curTime = ourAudio.currentTime || 0;
      let dur = ourAudio.duration;
      if (!dur || isNaN(dur) || dur < 1) {
        if (currentPlayingTrackIndex >= 0 && currentPlayingTrackIndex < BUILTIN_ALBUM_TRACKS.length) {
          dur = BUILTIN_ALBUM_TRACKS[currentPlayingTrackIndex].duration || 150;
        } else {
          dur = 150;
        }
      }

      // 1. Cover Art
      const imgEls = document.querySelectorAll('[data-testid="now-playing-widget"] [data-testid="cover-art-image"], [data-testid="now-playing-widget"] img, .main-coverSlotCollapsed-container img, .main-nowPlayingWidget-coverArt img');
      imgEls.forEach(img => {
        if (img.getAttribute("src") !== ALBUM_COVER_URL) {
          img.setAttribute("src", ALBUM_COVER_URL);
          img.setAttribute("srcset", "");
          img.style.display = "block";
          img.style.opacity = "1";
        }
      });

      // 2. Track Title
      const titleEls = document.querySelectorAll('[data-testid="now-playing-widget"] [data-testid="context-item-info-title"] a, [data-testid="now-playing-widget"] [data-testid="context-item-info-title"], .main-trackInfo-name a, .main-trackInfo-name');
      titleEls.forEach(el => {
        if (el.textContent !== currentPlayingTrackTitle) {
          el.textContent = currentPlayingTrackTitle;
          el.setAttribute("title", currentPlayingTrackTitle);
        }
      });

      // 3. Artist
      const artistEls = document.querySelectorAll('[data-testid="now-playing-widget"] [data-testid="context-item-info-subtitles"] a, [data-testid="now-playing-widget"] [data-testid="context-item-info-subtitles"], .main-trackInfo-artists a, .main-trackInfo-artists');
      artistEls.forEach(el => {
        if (el.textContent !== "m1raOnTheBlock") {
          el.textContent = "m1raOnTheBlock";
          el.setAttribute("title", "m1raOnTheBlock");
        }
      });

      // 4. Elapsed Time Text
      const posEl = document.querySelector('div[data-testid="playback-position"]');
      if (posEl) posEl.textContent = formatTime(curTime);

      // 5. Total Duration Text
      const durEl = document.querySelector('div[data-testid="playback-duration"]');
      if (durEl) durEl.textContent = formatTime(dur);

      // 6. Progress Slider
      const pct = Math.min(100, Math.max(0, (curTime / dur) * 100));
      const progressBar = document.querySelector('[data-testid="playback-progressbar"]');
      if (progressBar) {
        progressBar.style.setProperty("--progress-bar-transform", pct + "%");
        const sliderInner = progressBar.querySelector('.progress-bar__slider, [data-testid="progress-bar"]');
        if (sliderInner) sliderInner.style.width = pct + "%";
      }

      // 7. Play/Pause Button Icon
      const playPauseBtn = document.querySelector('[data-testid="control-button-playpause"]');
      if (playPauseBtn) {
        const isPlaying = !ourAudio.paused;
        playPauseBtn.setAttribute("aria-label", isPlaying ? "Пауза" : "Играть");
        const svg = playPauseBtn.querySelector("svg");
        if (svg) {
          if (isPlaying) {
            svg.innerHTML = '<path d="M2.7 1a.7.7 0 0 0-.7.7v12.6a.7.7 0 0 0 .7.7h2.6a.7.7 0 0 0 .7-.7V1.7a.7.7 0 0 0-.7-.7H2.7zm8 0a.7.7 0 0 0-.7.7v12.6a.7.7 0 0 0 .7.7h2.6a.7.7 0 0 0 .7-.7V1.7a.7.7 0 0 0-.7-.7h-2.6z"></path>';
          } else {
            svg.innerHTML = '<path d="M3 1.713a.7.7 0 0 1 1.05-.607l10.89 6.288a.7.7 0 0 1 0 1.212L4.05 14.894A.7.7 0 0 1 3 14.287V1.713z"></path>';
          }
        }
      }
    } catch (_) {}
  }

  // --- UPDATE TRACKLIST: ONLY CURRENTLY PLAYING TRACK IS GREEN, ALL OTHERS ARE WHITE! ---
  function updateUIForPlayback(playing, title, artist) {
    try {
      const rows = document.querySelectorAll('[data-testid="tracklist-row"], [role="row"]');
      rows.forEach((row, idx) => {
        const titleEl = row.querySelector('[data-encore-id="text"], div[dir="auto"], .standalone-ellipsis-one-line, [class*="title"], [class*="trackName"]');
        if (!titleEl) return;
        const text = titleEl.textContent.trim().toLowerCase();
        const isThisActive = playing && title && (text.includes(title.toLowerCase()) || (currentPlayingTrackIndex >= 0 && idx === currentPlayingTrackIndex));

        if (isThisActive) {
          titleEl.style.setProperty("color", "#1db954", "important");
          row.setAttribute("data-anticensor-active", "true");
          row.setAttribute("aria-selected", "true");
        } else {
          // RESET TO STANDARD SPOTIFY WHITE COLOR - DOES NOT STAY GREEN AFTER LISTENING!
          titleEl.style.removeProperty("color");
          titleEl.style.color = "#ffffff";
          row.removeAttribute("data-anticensor-active");
          row.removeAttribute("aria-selected");
        }
      });

      updatePlayerBarUI();
    } catch (_) {}
  }

  // --- SCRUBBING / REWINDING VIA PROGRESS BAR ---
  function setupProgressScrubber() {
    const progressBar = document.querySelector('[data-testid="playback-progressbar"]');
    if (!progressBar || progressBar.hasAttribute("data-anticensor-scrubber")) return;
    progressBar.setAttribute("data-anticensor-scrubber", "true");
    progressBar.style.cursor = "pointer";

    function doSeek(e) {
      if (!ourAudio) return;
      let dur = ourAudio.duration;
      if (!dur || isNaN(dur) || dur < 1) {
        if (currentPlayingTrackIndex >= 0 && currentPlayingTrackIndex < BUILTIN_ALBUM_TRACKS.length) {
          dur = BUILTIN_ALBUM_TRACKS[currentPlayingTrackIndex].duration || 150;
        } else {
          dur = 150;
        }
      }
      const rect = progressBar.getBoundingClientRect();
      const clickX = e.clientX - rect.left;
      const width = rect.width;
      if (width > 0) {
        const fraction = Math.max(0, Math.min(1, clickX / width));
        ourAudio.currentTime = fraction * dur;
        updatePlayerBarUI();
      }
    }

    progressBar.addEventListener("click", (e) => {
      if (ourAudio) {
        e.preventDefault();
        e.stopPropagation();
        doSeek(e);
      }
    }, true);

    let isDragging = false;
    progressBar.addEventListener("mousedown", (e) => {
      if (ourAudio) {
        isDragging = true;
        doSeek(e);
      }
    });
    window.addEventListener("mousemove", (e) => {
      if (isDragging && ourAudio) {
        doSeek(e);
      }
    });
    window.addEventListener("mouseup", () => {
      isDragging = false;
    });
  }

  // --- PREVIOUS / NEXT BUTTON HOOKS ---
  function setupNavButtons() {
    const skipFwdBtn = document.querySelector('button[data-testid="control-button-skip-forward"]');
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

    const skipBackBtn = document.querySelector('button[data-testid="control-button-skip-back"]');
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

    // Pause native Spotify playback so it doesn't fight
    try {
      if (Spicetify.Player.isPlaying()) {
        Spicetify.Player.pause();
      }
    } catch (_) {}

    const audio = new Audio();
    audio.crossOrigin = "anonymous";
    audio.preload = "auto";
    audio.volume = (typeof userVolume === "number" && userVolume > 0.05) ? userVolume : 1.0;
    audio.muted = false;
    ourAudio = audio;
    document.body.appendChild(audio);

    audio.addEventListener("error", (e) => {
      console.warn("[AntiCensor] Audio tag error:", audio.error, "URL:", streamUrl, "retry:", retryCount);
      if (sessionId !== activeSessionId) return;

      if (retryCount < 2) {
        Spicetify.showNotification(t.waking);
        setTimeout(() => {
          if (sessionId === activeSessionId) {
            startReplacement(trackId, url, retryCount + 1, albumIndex, explicitTitle);
          }
        }, 1500);
        return;
      }
      stopReplacement();
      Spicetify.showNotification(t.error);
    });

    audio.addEventListener("ended", () => {
      if (sessionId === activeSessionId) {
        playNextAlbumTrack();
      }
    });

    audio.addEventListener("play", () => {
      if (sessionId === activeSessionId) {
        isAntiCensorPlaying = true;
        Spicetify.showNotification(`▶ ${currentPlayingTrackTitle}`);
        updateUIForPlayback(true, currentPlayingTrackTitle, "m1raOnTheBlock");
      }
    });

    audio.addEventListener("pause", () => {
      if (sessionId === activeSessionId && audio.paused) {
        isAntiCensorPlaying = false;
        updateUIForPlayback(false, currentPlayingTrackTitle, "m1raOnTheBlock");
      }
    });

    audio.src = streamUrl;
    audio.play().then(() => {
      isAntiCensorPlaying = true;
      updateUIForPlayback(true, currentPlayingTrackTitle, "m1raOnTheBlock");
      setupProgressScrubber();
      setupNavButtons();

      // High-frequency ticker for smooth progress bar and current time
      if (progressInterval) clearInterval(progressInterval);
      progressInterval = setInterval(() => {
        if (sessionId === activeSessionId && ourAudio && !ourAudio.paused) {
          updatePlayerBarUI();
          setupProgressScrubber();
          setupNavButtons();
        }
      }, 200);
    }).catch(err => {
      console.warn("[AntiCensor] Play promise rejected:", err);
    });
  }

  // --- Click Interceptor on Tracklist Rows ---
  function handleTrackRowClick(evt) {
    const row = evt.target && evt.target.closest && evt.target.closest('[data-testid="tracklist-row"], [role="row"], .main-trackList-trackListRow');
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
    const titleCandidates = row.querySelectorAll('[data-encore-id="text"], div[dir="auto"], .standalone-ellipsis-one-line, [class*="title"], [class*="trackName"]');
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

    const currentUrl = window.location.href || "";
    const isAlbumPage = currentUrl.includes("1f1OCxkJ43A1qy9qqFNfuX") || document.title.includes("Coll. of $hiT");

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

      if (ourAudio && (currentPlayingTrackId === (id || uri || title) || (title && currentPlayingTrackTitle === title))) {
        if (ourAudio.paused) {
          ourAudio.play().catch(() => {});
          updateUIForPlayback(true, title, "m1raOnTheBlock");
        } else {
          ourAudio.pause();
          updateUIForPlayback(false, title, "m1raOnTheBlock");
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
    setInterval(cleanTracklistRows, 500);

    // Volume slider input
    document.addEventListener("input", (evt) => {
      const isVolSlider = evt.target && evt.target.closest && evt.target.closest('[data-testid="volume-bar"]');
      if (isVolSlider && evt.target.type === "range") {
        const v = parseFloat(evt.target.value);
        if (!isNaN(v)) {
          setUserVolume(v);
        }
      }
    }, true);

    // Play/Pause button in bottom bar
    document.addEventListener("click", (evt) => {
      const playPauseBtn = evt.target && evt.target.closest && evt.target.closest('[data-testid="control-button-playpause"]');
      if (playPauseBtn && ourAudio) {
        evt.preventDefault();
        evt.stopPropagation();
        if (ourAudio.paused) {
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
            ourAudio.play().catch(() => {});
          } else {
            ourAudio.pause();
          }
        }
      }
    }, true);

    // Capture click and double click on rows
    document.addEventListener("click", handleTrackRowClick, true);
    document.addEventListener("dblclick", handleTrackRowClick, true);

    setupProgressScrubber();
    setupNavButtons();
  }

  init();
})();
