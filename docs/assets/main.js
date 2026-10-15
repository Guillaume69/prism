// Prism, la page du projet : tout ce qui bouge en dehors de la scène d'ouverture.
(() => {
  "use strict";
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => [...r.querySelectorAll(s)];
  const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const fine = matchMedia("(hover: hover) and (pointer: fine)").matches;

  // ── Navigation : apparaît après la scène d'ouverture, suit la section en cours ──
  const nav = $("#nav");
  const hero = $("#top");
  new IntersectionObserver(([e]) => nav.classList.toggle("is-on", !e.isIntersecting), { rootMargin: "-80px 0px 0px 0px" }).observe(hero);
  const navLinks = $$(".nav-links a");
  const sections = navLinks.map((a) => $(a.getAttribute("href")));
  const spectrumIds = ["rouge", "orange", "jaune", "vert", "bleu", "violet"];
  const sectionObserver = new IntersectionObserver((entries) => {
    entries.forEach((e) => {
      if (!e.isIntersecting) return;
      let id = e.target.id;
      if (spectrumIds.includes(id)) id = "spectre";
      navLinks.forEach((a) => a.classList.toggle("is-active", a.getAttribute("href") === "#" + id));
    });
  }, { rootMargin: "-45% 0px -50% 0px" });
  [...sections, ...spectrumIds.map((id) => document.getElementById(id))].forEach((s) => s && sectionObserver.observe(s));

  // ── Apparitions au défilement ──
  const revealer = new IntersectionObserver((entries) => {
    entries.forEach((e) => { if (e.isIntersecting) { e.target.classList.add("is-in"); revealer.unobserve(e.target); } });
  }, { rootMargin: "0px 0px -12% 0px" });
  $$(".reveal").forEach((el) => revealer.observe(el));

  // ── Reflet qui suit le pointeur (cartes, captures) ──
  if (fine) {
    $$(".card").forEach((card) => card.addEventListener("pointermove", (e) => {
      const r = card.getBoundingClientRect();
      card.style.setProperty("--mx", `${e.clientX - r.left}px`);
      card.style.setProperty("--my", `${e.clientY - r.top}px`);
    }));
    $$(".tilt").forEach((stage) => {
      const shot = $(".window-shot", stage);
      stage.addEventListener("pointermove", (e) => {
        const r = stage.getBoundingClientRect();
        const x = (e.clientX - r.left) / r.width, y = (e.clientY - r.top) / r.height;
        shot.style.setProperty("--ry", `${(x - 0.5) * 7}deg`);
        shot.style.setProperty("--rx", `${(0.5 - y) * 5}deg`);
        shot.style.setProperty("--gx", `${x * 100}%`);
        shot.style.setProperty("--gy", `${y * 100}%`);
      });
      stage.addEventListener("pointerleave", () => { shot.style.setProperty("--rx", "0deg"); shot.style.setProperty("--ry", "0deg"); });
    });
  }

  // ── La vidéo de la barre et ses chapitres ──
  const CHAPTERS = [
    { start: 0, end: 1.4, label: "⌥ Espace", note: "Prism s’ouvre au-dessus de tout" },
    { start: 1.4, end: 5.21, label: "saf", note: "Apps et commandes, recherche floue · ⌘K pour les actions" },
    { start: 5.21, end: 8.7, label: "100 usd en eur", note: "Devises au taux du jour" },
    { start: 8.7, end: 12.01, label: "heure à tokyo", note: "Fuseaux horaires" },
    { start: 12.01, end: 14.76, label: "20% off 80", note: "Pourcentages à la Soulver" },
    { start: 14.76, end: 17.25, label: "#ff6161", note: "Couleurs dans tous les formats" },
    { start: 17.25, end: 20.98, label: "bonjour en anglais", note: "Traduction sur l’appareil" },
    { start: 20.98, end: 26.63, label: "Tab", note: "Quick AI : la question part à l’IA" },
  ];
  const video = $("#launcher-video");
  const list = $("#chapters");
  const bar = $("#video-progress");
  if (video && list) {
    list.innerHTML = CHAPTERS.map((c, i) => `<li><button type="button" data-i="${i}"><b>${c.label}</b><span>${c.note}</span><i></i></button></li>`).join("");
    const buttons = $$("button", list);
    buttons.forEach((b) => b.addEventListener("click", () => {
      video.currentTime = CHAPTERS[+b.dataset.i].start + 0.01;
      video.play().catch(() => {});
    }));
    let current = -1;
    const tick = () => {
      const t = video.currentTime;
      const i = CHAPTERS.findIndex((c) => t >= c.start && t < c.end);
      if (i !== current) {
        buttons.forEach((b, j) => b.classList.toggle("is-on", j === i));
        current = i;
      }
      if (i >= 0) {
        const c = CHAPTERS[i];
        $("i", buttons[i]).style.width = `${((t - c.start) / (c.end - c.start)) * 100}%`;
        buttons.forEach((b, j) => { if (j !== i) $("i", b).style.width = "0"; });
      }
      if (bar && video.duration) bar.style.width = `${(t / video.duration) * 100}%`;
      if (!video.paused) requestAnimationFrame(tick);
    };
    video.addEventListener("play", () => requestAnimationFrame(tick));
    video.addEventListener("seeked", tick);
    if (!reduce) {
      new IntersectionObserver(([e]) => {
        if (e.isIntersecting) { video.preload = "auto"; video.play().catch(() => {}); } else video.pause();
      }, { threshold: 0.35 }).observe(video);
    } else {
      video.controls = true;
    }
  }

  // ── Console de la calculatrice : de vraies réponses, tapées une à une ──
  const CALC = [
    ["10 ft in m", "3,048 m", "Résultat"],
    ["20% off 80", "64", "Après remise"],
    ["5pm ldn in sf", "09:00", "San Francisco"],
    ["#ff6161", "rgb(255 97 97)", "Couleur"],
    ["255 in hex", "0xFF", "Hexadécimal"],
    ["lundi dans 3 semaines", "lundi 9 novembre 2026", "Dans 25 jours"],
    ["145 min en durée", "2 h 25 min", "Durée"],
    ["1 btc en eur", "72 190,11 €", "Taux du 15 oct."],
  ];
  const calcBox = $("#calc-lines");
  if (calcBox) {
    const esc = (s) => s.replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]));
    const line = (q, r, cap, typed, done) =>
      `<div class="console-line"><span class="q">${esc(typed)}${done ? "" : '<span class="caret"></span>'}</span><span class="r">${done ? `${esc(r)}<em>${esc(cap)}</em>` : ""}</span></div>`;
    if (reduce) {
      calcBox.innerHTML = CALC.map(([q, r, c]) => line(q, r, c, q, true)).join("");
    } else {
      let started = false;
      const run = async () => {
        const sleep = (ms) => new Promise((res) => setTimeout(res, ms));
        for (;;) {
          calcBox.innerHTML = "";
          for (const [q, r, cap] of CALC) {
            const row = document.createElement("div");
            calcBox.appendChild(row);
            for (let i = 1; i <= q.length; i++) {
              row.innerHTML = line(q, r, cap, q.slice(0, i), false);
              await sleep(38 + Math.random() * 45);
            }
            await sleep(240);
            row.innerHTML = line(q, r, cap, q, true);
            await sleep(520);
          }
          await sleep(4200);
        }
      };
      new IntersectionObserver(([e], obs) => {
        if (e.isIntersecting && !started) { started = true; obs.disconnect(); run(); }
      }, { threshold: 0.3 }).observe(calcBox);
    }
  }

  // ── Bureau animé : une fenêtre rangée par les commandes de Prism ──
  const desk = $("#desk");
  if (desk) {
    const win = $("#win-main"), label = $("#desk-command");
    // Positions en % de l'écran, sous la barre des menus (3,4 %).
    const top = 5, full = 93.5, gap = 1;
    const L = [
      ["Moitié gauche", [gap, top, 49 - gap, full]],
      ["Premier tiers", [gap, top, 33.3 - gap, full]],
      ["Deux derniers tiers", [33.3 + gap / 2, top, 66.7 - gap * 1.5, full]],
      ["Quart supérieur droit", [50 + gap / 2, top, 50 - gap * 1.5, full / 2 - gap / 2]],
      ["Sixième inférieur central", [33.3 + gap / 2, top + full / 2 + gap / 2, 33.3 - gap, full / 2 - gap / 2]],
      ["Agrandir", [gap, top, 100 - gap * 2, full]],
      ["Centrer", [20, 16, 60, 70]],
    ];
    const bar = $(".desk-bar", desk), screen = $(".desk-screen", desk);
    let i = 0, paused = false, resumeTimer = 0, zTop = 3;
    const move = ([x, y, w, h]) => Object.assign(win.style, { left: `${x}%`, top: `${y}%`, width: `${w}%`, height: `${h}%` });
    const step = () => {
      if (paused) return;
      const [name, box] = L[i];
      label.textContent = name;
      bar.classList.add("is-on");
      setTimeout(() => { if (paused) return; bar.classList.remove("is-on"); move(box); }, 750);
      i = (i + 1) % L.length;
    };
    move(L[L.length - 1][1]);
    if (reduce) { bar.classList.add("is-on"); label.textContent = L[0][0]; move(L[0][1]); }
    else {
      let timer = 0;
      new IntersectionObserver(([e]) => {
        clearInterval(timer);
        if (e.isIntersecting) { step(); timer = setInterval(step, 2000); }
      }, { threshold: 0.3 }).observe(desk);
    }
    // Les fenêtres se déplacent à la souris (au doigt : par la barre de titre). La démo reprend six secondes après.
    $$(".win", desk).forEach((w) => {
      w.addEventListener("pointerdown", (e) => {
        if (e.button !== 0 || (e.pointerType !== "mouse" && !e.target.closest(".win-top"))) return;
        e.preventDefault();
        paused = true;
        clearTimeout(resumeTimer);
        bar.classList.remove("is-on");
        const r = screen.getBoundingClientRect(), b = w.getBoundingClientRect();
        const ox = e.clientX - b.left, oy = e.clientY - b.top;
        w.style.zIndex = String(++zTop);
        w.classList.add("is-dragging");
        w.setPointerCapture(e.pointerId);
        const drag = (ev) => {
          const x = Math.min(Math.max(ev.clientX - r.left - ox, -b.width * 0.7), r.width - b.width * 0.3);
          const y = Math.min(Math.max(ev.clientY - r.top - oy, r.height * 0.034), r.height - 24);
          w.style.left = `${(x / r.width) * 100}%`;
          w.style.top = `${(y / r.height) * 100}%`;
        };
        const drop = () => {
          w.removeEventListener("pointermove", drag);
          w.classList.remove("is-dragging");
          resumeTimer = setTimeout(() => { paused = false; }, 6000);
        };
        w.addEventListener("pointermove", drag);
        w.addEventListener("pointerup", drop, { once: true });
        w.addEventListener("pointercancel", drop, { once: true });
      });
    });
  }

  // ── Éventail des thèmes ──
  const THEMES = [
    ["prism-dark", "Prism sombre", "#FF6161"], ["midnight", "Minuit", "#7C8CFF"], ["dracula", "Dracula", "#FF79C6"],
    ["nord", "Nord", "#88C0D0"], ["tokyo-night", "Tokyo Night", "#7AA2F7"], ["catppuccin", "Catppuccin Mocha", "#CBA6F7"],
    ["gruvbox", "Gruvbox", "#FE8019"], ["solarized-dark", "Solarized sombre", "#B58900"], ["forest", "Forêt", "#4CC38A"],
    ["prism-light", "Prism clair", "#FF6161"], ["paper", "Papier", "#0A84FF"], ["sakura", "Sakura", "#E5508E"],
    ["rose-pine-dawn", "Rosé Pine Dawn", "#D7827E"], ["solarized-light", "Solarized clair", "#CB4B16"],
  ];
  const deck = $("#deck"), deckName = $("#deck-name");
  if (deck) {
    deck.innerHTML = THEMES.map(([id, name, accent], i) =>
      `<figure style="--glow:${accent}66" data-i="${i}"><img src="img/themes/${id}.jpg" alt="L’historique du presse-papiers avec le thème ${name}" width="960" height="601" loading="lazy" draggable="false"></figure>`).join("");
    const cards = $$("figure", deck);
    let active = 0, auto = 0;
    // La carte active au centre, les autres de part et d'autre, tournées comme dans Cover Flow.
    const layout = () => {
      const n = cards.length, gap = Math.min(innerWidth * 0.11, 170);
      cards.forEach((c, i) => {
        let k = i - active;
        if (k > n / 2) k -= n;
        if (k < -n / 2) k += n;
        const far = Math.abs(k), side = Math.sign(k);
        c.style.setProperty("--tx", `${side * (far ? gap * 0.9 + far * gap * 0.55 : 0)}px`);
        c.style.setProperty("--tz", `${far ? -140 - far * 60 : 40}px`);
        c.style.setProperty("--ry", `${-side * (far ? 42 : 0)}deg`);
        c.style.setProperty("--o", far > 4 ? "0" : String(1 - far * 0.12));
        c.style.zIndex = String(40 - far);
        c.style.pointerEvents = far > 4 ? "none" : "";
        c.classList.toggle("is-on", k === 0);
      });
      deckName.textContent = THEMES[active][1];
      deckName.style.color = THEMES[active][2];
    };
    const chips = $("#deck-chips");
    chips.innerHTML = THEMES.map(([id, name, accent], i) =>
      `<button type="button" data-i="${i}" style="--accent:${accent}" aria-pressed="false"><i></i>${name}</button>`).join("");
    const chipButtons = $$("button", chips);
    const select = (i) => {
      active = (i + cards.length) % cards.length;
      layout();
      chipButtons.forEach((b, j) => b.setAttribute("aria-pressed", String(j === active)));
      // Sur téléphone, la liste défile : le thème choisi reste visible.
      const chip = chipButtons[active];
      if (chips.scrollWidth > chips.clientWidth) chips.scrollTo({ left: chip.offsetLeft - chips.clientWidth / 2 + chip.offsetWidth / 2, behavior: reduce ? "auto" : "smooth" });
    };
    // Défilement automatique, suspendu dix secondes après chaque geste.
    let idle = 0, visible = false;
    const restart = () => { clearInterval(auto); if (!reduce && visible) auto = setInterval(() => select(active + 1), 2200); };
    const touched = () => { clearInterval(auto); clearTimeout(idle); idle = setTimeout(restart, 10000); };
    const choose = (i) => { select(i); touched(); };
    cards.forEach((c, i) => c.addEventListener("click", () => { if (!swiped) choose(i); }));
    chipButtons.forEach((b, i) => b.addEventListener("click", () => choose(i)));
    $$("[data-deck]").forEach((b) => b.addEventListener("click", () => choose(active + Number(b.dataset.deck))));
    deck.addEventListener("keydown", (e) => {
      if (e.key === "ArrowRight") { choose(active + 1); e.preventDefault(); }
      if (e.key === "ArrowLeft") { choose(active - 1); e.preventDefault(); }
    });
    let startX = null, swiped = false;
    deck.addEventListener("pointerdown", (e) => { startX = e.clientX; swiped = false; });
    deck.addEventListener("pointerup", (e) => {
      if (startX === null) return;
      const dx = e.clientX - startX;
      startX = null;
      if (Math.abs(dx) > 40) { swiped = true; choose(active + (dx < 0 ? 1 : -1)); }
    });
    select(0);
    new IntersectionObserver(([e]) => { visible = e.isIntersecting; if (visible) restart(); else clearInterval(auto); }, { threshold: 0.3 }).observe(deck);
    addEventListener("resize", layout);
  }

  // ── Boutons « Copier » ──
  $$("[data-copy]").forEach((b) => b.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(b.dataset.copy);
      b.textContent = "Copié"; b.classList.add("is-done");
      setTimeout(() => { b.textContent = "Copier"; b.classList.remove("is-done"); }, 1600);
    } catch { b.textContent = "⌘C"; }
  }));

  // ── Dernière release : lien direct vers le zip, version et taille ──
  fetch("https://api.github.com/repos/Guillaume69/prism/releases/latest", { headers: { Accept: "application/vnd.github+json" } })
    .then((r) => (r.ok ? r.json() : Promise.reject(r.status)))
    .then((release) => {
      const zip = (release.assets || []).find((a) => /\.zip$/.test(a.name));
      const version = String(release.tag_name || "").replace(/^v/, "");
      if (zip) $$("[data-download]").forEach((a) => { a.href = zip.browser_download_url; });
      if (version) {
        $$("[data-version-label]").forEach((el) => { el.textContent = `Prism ${version}`; });
        $$("[data-version]").forEach((el) => { el.textContent = `v${version}`; });
      }
      if (zip) $$("[data-size]").forEach((el) => { el.textContent = `${Math.round(zip.size / 1e6)} Mo`; });
    })
    .catch(() => {});

  // ─────────────── La barre dans la page (⌥ Espace) ───────────────
  const ICONS = {
    search: '<circle cx="11" cy="11" r="6"/><path d="m20 20-4.3-4.3"/>',
    calc: '<rect x="5" y="3" width="14" height="18" rx="2"/><path d="M8 7h8M8 12h.01M12 12h.01M16 12h.01M8 16h.01M12 16h.01M16 16h.01"/>',
    clip: '<rect x="6" y="4" width="12" height="17" rx="2"/><path d="M9 4h6v3H9z"/>',
    text: '<path d="M5 6h14M5 12h10M5 18h7"/>',
    link: '<path d="M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1"/>',
    smile: '<circle cx="12" cy="12" r="8"/><path d="M9 14a4 4 0 0 0 6 0M9.5 9.5h.01M14.5 9.5h.01"/>',
    spark: '<path d="M12 3l1.8 5.2L19 10l-5.2 1.8L12 17l-1.8-5.2L5 10l5.2-1.8z"/>',
    window: '<rect x="3" y="5" width="18" height="14" rx="2"/><path d="M12 5v14"/>',
    gear: '<circle cx="12" cy="12" r="3"/><path d="M12 3v3M12 18v3M3 12h3M18 12h3M5.6 5.6l2.1 2.1M16.3 16.3l2.1 2.1M5.6 18.4l2.1-2.1M16.3 7.7l2.1-2.1"/>',
    note: '<path d="M6 3h9l3 3v15H6z"/><path d="M9 10h6M9 14h6M9 18h3"/>',
    target: '<circle cx="12" cy="12" r="8"/><circle cx="12" cy="12" r="3"/>',
    mic: '<rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5 11a7 7 0 0 0 14 0M12 18v3"/>',
    cal: '<rect x="4" y="5" width="16" height="15" rx="2"/><path d="M4 10h16M9 3v4M15 3v4"/>',
    folder: '<path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>',
    bag: '<path d="M5 8h14l-1 12H6z"/><path d="M9 8a3 3 0 0 1 6 0"/>',
    puzzle: '<path d="M9 4h3a2 2 0 1 1 4 0h2v5a2 2 0 1 1 0 4v5h-5a2 2 0 1 0-4 0H5v-5a2 2 0 1 0 0-4V4z"/>',
    palette: '<path d="M12 3a9 9 0 1 0 0 18c1.5 0 2-1 2-2s-1-2 0-3 4 0 5-1a9 9 0 0 0-7-12z"/><circle cx="8" cy="11" r="1"/><circle cx="12" cy="7.5" r="1"/><circle cx="16" cy="10" r="1"/>',
    term: '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="m7 9 3 3-3 3M12 15h5"/>',
    lang: '<path d="M4 6h9M8.5 4v2M6 6c1 4 4 7 7 8M11 6c-1 4-3 7-6 9"/><path d="m13 20 4-9 4 9M14.5 17h5"/>',
    users: '<circle cx="9" cy="8" r="3"/><path d="M3 20a6 6 0 0 1 12 0"/><circle cx="17" cy="9" r="2.5"/><path d="M15.5 14.5A5 5 0 0 1 21 19"/>',
    sync: '<path d="M4 12a8 8 0 0 1 14-5.3L20 9M20 12a8 8 0 0 1-14 5.3L4 15"/><path d="M20 4v5h-5M4 20v-5h5"/>',
    key: '<rect x="3" y="7" width="18" height="10" rx="2"/><path d="M7 11h.01M11 11h.01M15 11h.01M8 14h8"/>',
    phone: '<rect x="7" y="3" width="10" height="18" rx="2"/><path d="M11 18h2"/>',
    download: '<path d="M12 4v11m0 0-4-4m4 4 4-4M5 20h14"/>',
    github: '<path d="M9 19c-4 1.3-4-2-6-2.5m12 5v-3.4a3 3 0 0 0-.8-2.3c2.7-.3 5.6-1.3 5.6-6a4.6 4.6 0 0 0-1.3-3.2 4.3 4.3 0 0 0-.1-3.2s-1-.3-3.4 1.3a11.6 11.6 0 0 0-6 0C6.6 1.6 5.6 1.9 5.6 1.9a4.3 4.3 0 0 0-.1 3.2A4.6 4.6 0 0 0 4.2 8.3c0 4.7 2.9 5.7 5.6 6a3 3 0 0 0-.8 2.3V20"/>',
    wifi: '<path d="M3 9a14 14 0 0 1 18 0M6 12.5a9 9 0 0 1 12 0M9 16a4 4 0 0 1 6 0M12 19.5h.01"/>',
    chart: '<path d="M4 20V10M10 20V4M16 20v-7M22 20H2"/>',
  };
  const C = { red: "#ff4554", orange: "#ff8c33", yellow: "#e8b923", green: "#38b960", blue: "#3b8cf0", violet: "#8d55f0", gray: "#8e8e93" };
  // Les titres sont ceux des vraies commandes de Prism ; ↵ mène à la partie de la page qui en parle.
  const ITEMS = [
    ["Télécharger Prism", "Release sur GitHub", "download", "gray", "@download", "Lien"],
    ["Code source", "github.com/Guillaume69/prism", "github", "gray", "https://github.com/Guillaume69/prism", "Lien"],
    ["Installer", "Trois étapes", "download", "gray", "#installer", "Page"],
    ["Rechercher des apps et des commandes", "Recherche principale", "search", "red", "#rouge"],
    ["Historique de la calculatrice", "Calculatrice", "calc", "red", "#rouge"],
    ["Rechercher des fichiers", "Fichiers", "folder", "red", "#tout"],
    ["Rechercher des captures d’écran", "Captures d’écran", "folder", "red", "#tout"],
    ["Rechercher des contacts", "Contacts", "users", "red", "#tout"],
    ["Rechercher dans les Réglages Système", "Système", "gear", "red", "#rouge"],
    ["Traduire", "Traduction", "lang", "red", "#rouge"],
    ["Historique du presse-papiers", "Presse-papiers", "clip", "orange", "#orange"],
    ["Rechercher des snippets", "Snippets", "text", "orange", "#orange"],
    ["Créer un snippet", "Snippets", "text", "orange", "#orange"],
    ["Rechercher des liens rapides", "Liens rapides", "link", "orange", "#tout"],
    ["Créer un lien rapide", "Liens rapides", "link", "orange", "#tout"],
    ["Rechercher un emoji ou un symbole", "Emojis et symboles", "smile", "orange", "#orange"],
    ["Quick AI", "IA", "spark", "yellow", "#jaune"],
    ["Rechercher les commandes d’IA", "IA", "spark", "yellow", "#jaune"],
    ["Créer une commande d’IA", "IA", "spark", "yellow", "#jaune"],
    ["Rechercher les agents", "IA", "spark", "yellow", "#jaune"],
    ["Rechercher les projets d’IA", "IA", "spark", "yellow", "#jaune"],
    ["Créer une automatisation d’IA", "IA", "spark", "yellow", "#jaune"],
    ["Mémoire de l’IA", "IA", "spark", "yellow", "#jaune"],
    ["Extensions de l’IA", "IA", "spark", "yellow", "#jaune"],
    ["Utilisation de l’IA", "IA", "chart", "yellow", "#tout"],
    ["Moitié gauche", "Gestion des fenêtres", "window", "green", "#vert"],
    ["Premier tiers", "Gestion des fenêtres", "window", "green", "#vert"],
    ["Quart supérieur droit", "Gestion des fenêtres", "window", "green", "#vert"],
    ["Agrandir", "Gestion des fenêtres", "window", "green", "#vert"],
    ["Écran suivant", "Gestion des fenêtres", "window", "green", "#vert"],
    ["Enregistrer la disposition actuelle", "Gestion des fenêtres", "window", "green", "#vert"],
    ["Changer de fenêtre", "Navigation", "window", "green", "#vert"],
    ["Rechercher dans les menus", "Navigation", "search", "green", "#vert"],
    ["Activer ou désactiver le Wi-Fi", "Système", "wifi", "green", "#vert"],
    ["Réseaux Wi-Fi", "Système", "wifi", "green", "#vert"],
    ["Appareils Bluetooth", "Système", "wifi", "green", "#vert"],
    ["Mixeur de volume", "Système", "gear", "green", "#vert"],
    ["Caméra", "Système", "gear", "green", "#vert"],
    ["Désinstaller des applications", "Applications", "gear", "green", "#tout"],
    ["Gérer la fermeture automatique", "Applications", "gear", "green", "#tout"],
    ["Nouvelle note", "Notes", "note", "blue", "#bleu"],
    ["Rechercher des notes", "Notes", "note", "blue", "#bleu"],
    ["Démarrer une session de concentration", "Concentration", "target", "blue", "#bleu"],
    ["Historique des dictées", "Dictée", "mic", "blue", "#bleu"],
    ["Mon agenda", "Calendrier", "cal", "blue", "#bleu"],
    ["Créer un évènement", "Calendrier", "cal", "blue", "#bleu"],
    ["Bloquer du temps", "Calendrier", "cal", "blue", "#bleu"],
    ["Équipe", "Équipe", "users", "blue", "#tout"],
    ["Exporter les réglages et données", "Synchronisation", "sync", "blue", "#tout"],
    ["Store d’extensions Raycast", "Extensions", "bag", "violet", "#violet"],
    ["Extensions installées", "Extensions", "puzzle", "violet", "#violet"],
    ["Store", "Script commands", "bag", "violet", "#violet"],
    ["Rechercher les commandes scripts", "Commandes scripts", "term", "violet", "#tout"],
    ["Créer une commande script", "Commandes scripts", "term", "violet", "#tout"],
    ["Exécuter une commande", "Terminal", "term", "violet", "#tout"],
    ["Changer de thème", "Thèmes", "palette", "violet", "#themes"],
    ["Touche Hyper", "Clavier", "key", "violet", "#tout"],
    ["Mes statistiques", "Divers", "chart", "violet", "#tout"],
    ["Lanceur de jeux", "Jeux", "gear", "violet", "#tout"],
    ["Prism sur iPhone", "App compagnon", "phone", "violet", "#tout"],
  ].map(([title, sub, icon, color, href, acc]) => ({ title, sub, icon, color: C[color], href, acc: acc || "Commande" }));

  const lx = $("#lx"), input = $("#lx-input"), listEl = $("#lx-list"), calcEl = $("#lx-calc"), actionEl = $("#lx-action");
  let rows = [], sel = 0, lastFocus = null;
  const fold = (s) => s.normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase().replace(/[’']/g, "'");

  // Recherche floue : les lettres dans l'ordre, les débuts de mots et les initiales comptent double.
  function score(item, q) {
    const t = fold(item.title), s = fold(item.sub);
    if (!q) return 1;
    if (t.startsWith(q)) return 100 - t.length / 100;
    const words = t.split(/[\s’'-]+/);
    if (words.some((w) => w.startsWith(q))) return 80 - t.length / 100;
    if (words.map((w) => w[0]).join("").startsWith(q)) return 70;
    if (t.includes(q)) return 60;
    if (s.includes(q)) return 40;
    // Lettres dans l'ordre, mais pas trop éparpillées.
    let i = 0, gaps = 0;
    for (const ch of t) { if (ch === q[i]) i++; else if (i) gaps++; if (i === q.length) break; }
    return i === q.length && gaps <= Math.max(2, q.length) ? 20 - gaps / 10 : 0;
  }
  function highlight(title, q) {
    if (!q) return esc(title);
    const f = fold(title);
    const at = f.indexOf(q);
    if (at < 0) return esc(title);
    return esc(title.slice(0, at)) + "<mark>" + esc(title.slice(at, at + q.length)) + "</mark>" + esc(title.slice(at + q.length));
  }
  function esc(s) { return s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c])); }

  // Une petite calculatrice : opérations, parenthèses, puissances, et deux tournures à la Soulver.
  function calculate(raw) {
    const q = raw.trim().toLowerCase().replace(/,/g, ".").replace(/×/g, "*").replace(/÷/g, "/");
    if (!q || !/\d/.test(q)) return null;
    let m = q.match(/^(\d+(?:\.\d+)?)\s*%\s*(?:off|de remise sur|de réduction sur)\s*(\d+(?:\.\d+)?)$/);
    if (m) return [raw, +m[2] * (1 - +m[1] / 100), "Après remise"];
    m = q.match(/^(\d+(?:\.\d+)?)\s*([+-])\s*(\d+(?:\.\d+)?)\s*%$/);
    if (m) return [raw, +m[1] * (1 + (m[2] === "+" ? 1 : -1) * +m[3] / 100), "Résultat"];
    m = q.match(/^(\d+(?:\.\d+)?)\s*%\s*(?:of|de)\s*(\d+(?:\.\d+)?)$/);
    if (m) return [raw, (+m[1] / 100) * +m[2], "Résultat"];
    if (!/^[\d\s.+\-*/^()%]+$/.test(q) || !/[+\-*/^%]/.test(q)) return null;
    // Analyse descendante, sans eval.
    const tokens = q.match(/\d+(?:\.\d+)?|[+\-*/^()%]/g);
    if (!tokens) return null;
    let p = 0;
    const peek = () => tokens[p], next = () => tokens[p++];
    const primary = () => {
      const t = next();
      if (t === "(") { const v = expr(); if (next() !== ")") throw 0; return v; }
      if (t === "-") return -primary();
      if (t === "+") return primary();
      if (t !== undefined && /^\d/.test(t)) { let v = +t; if (peek() === "%") { next(); v /= 100; } return v; }
      throw 0;
    };
    const power = () => { const b = primary(); if (peek() === "^") { next(); return Math.pow(b, power()); } return b; };
    const term = () => { let v = power(); while (peek() === "*" || peek() === "/") { const o = next(), r = power(); v = o === "*" ? v * r : v / r; } return v; };
    const expr = () => { let v = term(); while (peek() === "+" || peek() === "-") { const o = next(), r = term(); v = o === "+" ? v + r : v - r; } return v; };
    try {
      const v = expr();
      if (p !== tokens.length || !isFinite(v)) return null;
      return [raw, v, "Résultat"];
    } catch { return null; }
  }
  const fmtNumber = (n) => new Intl.NumberFormat("fr-FR", { maximumFractionDigits: 10 }).format(n);

  function renderLauncher() {
    const raw = input.value, q = fold(raw.trim());
    const calc = calculate(raw);
    calcEl.innerHTML = calc
      ? `<p class="lx-section">Calculatrice</p><div class="lx-calc"><div><b>${esc(calc[0].trim())}</b><small>Expression</small></div><i>→</i><div><b>${fmtNumber(calc[1])}</b><small>${calc[2]}</small></div></div>`
      : "";
    let found = ITEMS.map((it) => [it, score(it, q)]).filter(([, s]) => s > 0).sort((a, b) => b[1] - a[1]).map(([it]) => it);
    if (!q) found = ITEMS.slice(0, 40);
    const fallbacks = q ? [
      { title: `Chercher « ${raw.trim()} » dans le README`, sub: "GitHub", icon: "search", color: C.gray, href: `https://github.com/Guillaume69/prism#:~:text=${encodeURIComponent(raw.trim())}`, acc: "Web" },
    ] : [];
    rows = [...(calc ? [{ calc }] : []), ...found.slice(0, 30), ...fallbacks];
    sel = 0;
    const section = (title) => `<li class="lx-section" role="presentation">${title}</li>`;
    let html = "";
    if (found.length) html += section(q ? "Résultats" : "Commandes");
    found.slice(0, 30).forEach((it, i) => { html += rowHtml(it, i + (calc ? 1 : 0), q); });
    if (fallbacks.length) {
      html += section(`Utiliser « ${esc(raw.trim())} » avec…`);
      fallbacks.forEach((it, i) => { html += rowHtml(it, (calc ? 1 : 0) + Math.min(found.length, 30) + i, ""); });
    }
    if (!found.length && !calc && !q) html = `<li class="lx-empty">Aucun résultat</li>`;
    listEl.innerHTML = html;
    updateSelection();
  }
  function rowHtml(it, i, q) {
    return `<li class="lx-row" role="option" id="lx-opt-${i}" data-i="${i}" aria-selected="false">
      <span class="lx-icon" style="--c:${it.color}"><svg viewBox="0 0 24 24">${ICONS[it.icon] || ICONS.search}</svg></span>
      <span class="lx-title">${highlight(it.title, q)}</span><span class="lx-sub">${esc(it.sub)}</span><span class="lx-acc">${esc(it.acc)}</span></li>`;
  }
  function updateSelection() {
    $$(".lx-row", listEl).forEach((r) => {
      const on = +r.dataset.i === sel;
      r.classList.toggle("is-on", on);
      r.setAttribute("aria-selected", String(on));
      if (on) { r.scrollIntoView({ block: "nearest" }); input.setAttribute("aria-activedescendant", r.id); }
    });
    const row = rows[sel];
    calcEl.querySelector(".lx-calc")?.style.setProperty("outline", row && row.calc ? "2px solid rgba(255,255,255,.18)" : "none");
    actionEl.textContent = !row ? "Ouvrir" : row.calc ? "Copier le résultat" : row.href.startsWith("#") ? "Aller à la section" : "Ouvrir le lien";
  }
  function run(i) {
    const row = rows[i];
    if (!row) return;
    if (row.calc) {
      navigator.clipboard?.writeText(String(row.calc[1])).catch(() => {});
      actionEl.textContent = "Copié";
      return;
    }
    closeLauncher();
    if (row.href === "@download") { $("[data-download]").click(); return; }
    if (row.href.startsWith("#")) { document.querySelector(row.href)?.scrollIntoView({ behavior: reduce ? "auto" : "smooth" }); return; }
    window.open(row.href, "_blank", "noopener");
  }
  function openLauncher() {
    if (!lx.hidden) { input.select(); return; }
    lastFocus = document.activeElement;
    lx.hidden = false;
    input.value = "";
    renderLauncher();
    input.focus();
  }
  function closeLauncher() {
    lx.hidden = true;
    lastFocus?.focus?.();
  }
  // Comme une fenêtre : on la déplace en la tenant par son cadre (hors du champ et des résultats).
  const lxWindow = $(".lx-window");
  let offset = { x: 0, y: 0 };
  lxWindow.addEventListener("pointerdown", (e) => {
    if (e.button !== 0 || e.target.closest("input, .lx-row, button, a")) return;
    e.preventDefault();
    const start = { x: e.clientX - offset.x, y: e.clientY - offset.y };
    const box = lxWindow.getBoundingClientRect();
    const base = { left: box.left - offset.x, top: box.top - offset.y };
    lxWindow.classList.add("is-dragging");
    lxWindow.setPointerCapture(e.pointerId);
    const drag = (ev) => {
      const x = Math.min(Math.max(ev.clientX - start.x, -base.left - box.width + 80), innerWidth - base.left - 80);
      const y = Math.min(Math.max(ev.clientY - start.y, -base.top), innerHeight - base.top - 50);
      offset = { x, y };
      lxWindow.style.translate = `${x}px ${y}px`;
    };
    const drop = () => { lxWindow.removeEventListener("pointermove", drag); lxWindow.classList.remove("is-dragging"); input.focus(); };
    lxWindow.addEventListener("pointermove", drag);
    lxWindow.addEventListener("pointerup", drop, { once: true });
    lxWindow.addEventListener("pointercancel", drop, { once: true });
  });
  input.addEventListener("input", renderLauncher);
  input.addEventListener("keydown", (e) => {
    const max = rows.length - 1;
    if (e.key === "ArrowDown" || (e.ctrlKey && e.key === "n")) { sel = Math.min(max, sel + 1); updateSelection(); e.preventDefault(); }
    else if (e.key === "ArrowUp" || (e.ctrlKey && e.key === "p")) { sel = Math.max(0, sel - 1); updateSelection(); e.preventDefault(); }
    else if (e.key === "Enter") { run(sel); e.preventDefault(); }
    else if (e.key === "Escape") { if (input.value) { input.value = ""; renderLauncher(); } else closeLauncher(); e.preventDefault(); }
    else if (e.key === "Tab") e.preventDefault();
  });
  listEl.addEventListener("click", (e) => { const r = e.target.closest(".lx-row"); if (r) run(+r.dataset.i); });
  listEl.addEventListener("pointermove", (e) => {
    const r = e.target.closest(".lx-row");
    if (r && +r.dataset.i !== sel) { sel = +r.dataset.i; updateSelection(); }
  });
  $$("[data-close-launcher]").forEach((el) => el.addEventListener("click", closeLauncher));
  $$("[data-open-launcher]").forEach((el) => el.addEventListener("click", openLauncher));
  document.addEventListener("keydown", (e) => {
    // ⌥ Espace, comme dans Prism. Aussi ⌘K et « / » quand aucun champ n'a le focus.
    const typing = e.target instanceof Element && e.target.closest("input, textarea, [contenteditable]");
    if (e.altKey && (e.code === "Space" || e.key === " ")) { e.preventDefault(); lx.hidden ? openLauncher() : closeLauncher(); return; }
    if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k") { e.preventDefault(); openLauncher(); return; }
    if (!typing && e.key === "/" && lx.hidden) { e.preventDefault(); openLauncher(); }
  });
})();
