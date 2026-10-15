// La scène d'ouverture : un rayon blanc entre dans le prisme et en ressort décomposé.
// La réfraction est calculée pour de vrai (loi de Snell, indice de Cauchy), avec une dispersion exagérée
// pour que l'éventail se voie. Le pointeur règle l'angle d'incidence, un clic envoie un flash.
(() => {
  "use strict";
  const hero = document.getElementById("top");
  const canvas = document.getElementById("scene");
  if (!hero || !canvas) return;
  const ctx = canvas.getContext("2d", { alpha: false });
  const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const root = document.documentElement;
  const DEG = Math.PI / 180;

  // ── Couleurs : celles de l'icône, du rouge au violet ──
  const PALETTE = [[255, 69, 84], [255, 140, 51], [255, 214, 64], [77, 217, 115], [64, 153, 255], [158, 97, 255]];
  // u ∈ [0, 1] parcourt le spectre du rouge (700 nm) au violet (400 nm), régulièrement en 1/λ².
  const INV_RED = 1 / (0.7 * 0.7), INV_VIOLET = 1 / (0.4 * 0.4), INV_D = 1 / (0.589 * 0.589);
  const invLambda2 = (u) => INV_RED + u * (INV_VIOLET - INV_RED);
  const lambdaNm = (u) => Math.round(1000 / Math.sqrt(invLambda2(u)));
  function colorAt(u) {
    const x = Math.min(Math.max(u * 6 - 0.5, 0), 5);
    const i = Math.min(Math.floor(x), 4), f = x - i;
    const a = PALETTE[i], b = PALETTE[i + 1];
    return [a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f, a[2] + (b[2] - a[2]) * f];
  }
  const edgeFade = (u) => Math.min(1, 0.35 + Math.min(u, 1 - u) * 9);

  // Indice du verre : n(λ) = 1,52 à 589 nm, la pente de Cauchy multipliée par la dispersion choisie.
  const DISPERSIONS = [1, 8, 16];
  let dispersionIndex = 1;
  const indexAt = (u, k) => 1.52 + k * 0.0042 * (invLambda2(u) - INV_D);

  // ── Vecteurs ──
  const v = (x, y) => ({ x, y });
  const add = (a, b) => v(a.x + b.x, a.y + b.y);
  const sub = (a, b) => v(a.x - b.x, a.y - b.y);
  const mul = (a, s) => v(a.x * s, a.y * s);
  const dot = (a, b) => a.x * b.x + a.y * b.y;
  const len = (a) => Math.hypot(a.x, a.y);
  const norm = (a) => mul(a, 1 / (len(a) || 1));
  const lerp = (a, b, t) => v(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t);
  const rot = (a, ang) => v(a.x * Math.cos(ang) - a.y * Math.sin(ang), a.x * Math.sin(ang) + a.y * Math.cos(ang));

  // Réfraction de d (unitaire) sur une surface de normale n tournée vers d'où vient le rayon ; η = n1 / n2.
  function refract(d, n, eta) {
    const cosi = -dot(d, n);
    const k = 1 - eta * eta * (1 - cosi * cosi);
    if (k < 0) return null; // réflexion totale
    return norm(add(mul(d, eta), mul(n, eta * cosi - Math.sqrt(k))));
  }
  const reflect = (d, n) => sub(d, mul(n, 2 * dot(d, n)));
  // Intersection du rayon p + t·d avec le segment [a, b].
  function hit(p, d, a, b) {
    const e = sub(b, a);
    const den = d.x * e.y - d.y * e.x;
    if (Math.abs(den) < 1e-9) return null;
    const w = sub(a, p);
    const t = (w.x * e.y - w.y * e.x) / den;
    const s = (w.x * d.y - w.y * d.x) / den;
    return t > 1e-4 && s >= -1e-6 && s <= 1 + 1e-6 ? t : null;
  }

  // ── État ──
  let W = 0, H = 0, dpr = 1;
  let prism = null;             // sommets, faces, normales
  const pointer = { x: 0.5, y: 0.55, active: false, inside: false, px: -1, py: -1, last: 0 };
  let incidence = 49 * DEG, incidenceTarget = incidence;
  let tilt = 0, tiltTarget = 0;
  let boost = 0;                // éclat après un flash
  let pulse = null;             // le paquet de lumière lancé par un clic
  let time = 0, running = true, visible = true;
  let samples = [];             // un rayon par longueur d'onde
  let beam = null;              // source et point d'entrée
  const N = reduce ? 28 : 40;
  const families = [...document.querySelectorAll("#spectrum-labels a")];

  // Calques : le fond (dessiné une fois), et deux tampons basse définition pour le halo.
  const bg = document.createElement("canvas");
  const glowA = document.createElement("canvas"), glowB = document.createElement("canvas");
  const gA = glowA.getContext("2d"), gB = glowB.getContext("2d");

  // ── Géométrie ──
  function layout() {
    const r = hero.getBoundingClientRect();
    W = Math.max(320, r.width); H = Math.max(480, r.height);
    dpr = Math.min(window.devicePixelRatio || 1, W > 1600 ? 1.25 : 1.5);
    canvas.width = Math.round(W * dpr); canvas.height = Math.round(H * dpr);
    bg.width = canvas.width; bg.height = canvas.height;
    glowA.width = Math.ceil(W / 4); glowA.height = Math.ceil(H / 4);
    glowB.width = Math.ceil(W / 12); glowB.height = Math.ceil(H / 12);
    drawBackground();
    seedDust();
    measureLabels();
  }

  function prismGeometry() {
    // Paysage : le texte à gauche, le prisme à droite. Portrait : le texte en haut, le prisme en bas.
    let side, c;
    if (W < 700) { side = Math.min(W * 0.44, 190); c = v(W * 0.5, H - 205); }
    else if (H > W * 1.15) { side = Math.min(W * 0.4, H * 0.3, 360); c = v(W * 0.56, H * 0.71); }
    else { side = Math.min(W * 0.25, H * 0.46, 440); c = v(W * 0.64, H * 0.6); }
    const h = side * Math.sqrt(3) / 2;
    // Sommets autour du centre de gravité, légèrement tournés par le pointeur.
    const raw = [v(0, -h * 2 / 3), v(-side / 2, h / 3), v(side / 2, h / 3)];
    const [T, A, B] = raw.map((p) => add(c, rot(p, tilt)));
    const faces = [[A, T], [T, B], [B, A]].map(([a, b]) => {
      let n = norm(v(b.y - a.y, -(b.x - a.x)));
      if (dot(n, sub(lerp(a, b, 0.5), c)) < 0) n = mul(n, -1);
      return { a, b, n }; // n : normale sortante
    });
    return { T, A, B, c, side, faces };
  }

  // Trace un rayon de longueur d'onde u : entrée par la face gauche, au plus deux réflexions internes.
  function trace(u, k, entry, d) {
    const n = indexAt(u, k);
    const left = prism.faces[0];
    let dir = refract(d, left.n, 1 / n);
    if (!dir) return null;
    let p = entry;
    const path = [entry];
    let face = 0;
    for (let bounce = 0; bounce < 3; bounce++) {
      let best = null, bestFace = -1;
      prism.faces.forEach((f, i) => {
        if (i === face) return;
        const t = hit(p, dir, f.a, f.b);
        if (t !== null && (best === null || t < best)) { best = t; bestFace = i; }
      });
      if (best === null) return null;
      p = add(p, mul(dir, best)); face = bestFace; path.push(p);
      const out = refract(dir, mul(prism.faces[face].n, -1), n);
      if (out) return { u, n, path, exit: p, dir: out, face };
      dir = reflect(dir, prism.faces[face].n);
    }
    return null;
  }

  function solve() {
    prism = prismGeometry();
    const left = prism.faces[0];
    const entry = lerp(left.a, left.b, 0.42);
    // L'incidence se mesure depuis la normale rentrante de la face gauche.
    const inward = mul(left.n, -1);
    const d = norm(rot(inward, -incidence));
    const reach = (entry.x + 80) / Math.max(d.x, 0.2);
    beam = { source: sub(entry, mul(d, reach)), entry, d };
    const k = DISPERSIONS[dispersionIndex];
    samples = [];
    for (let i = 0; i < N; i++) samples.push(trace(i / (N - 1), k, entry, d));
    summarizeFan();
  }

  // ── Fond ──
  function drawBackground() {
    const b = bg.getContext("2d");
    b.setTransform(dpr, 0, 0, dpr, 0, 0);
    const g = b.createRadialGradient(W * 0.62, H * 0.52, 0, W * 0.62, H * 0.52, Math.max(W, H) * 0.8);
    g.addColorStop(0, "#150f26"); g.addColorStop(0.45, "#0a0814"); g.addColorStop(1, "#050409");
    b.fillStyle = g; b.fillRect(0, 0, W, H);
    // Une grille de points très discrète, comme une table d'optique.
    b.fillStyle = "rgba(255,255,255,0.05)";
    const step = 34;
    for (let y = step / 2; y < H; y += step) for (let x = step / 2; x < W; x += step) b.fillRect(x, y, 1, 1);
  }

  // ── Poussière dans la lumière (particules réutilisées) ──
  const dust = [];
  function seedDust() {
    const count = Math.round(Math.min(260, (W * H) / 5200));
    dust.length = 0;
    for (let i = 0; i < count; i++) {
      dust.push({ x: Math.random() * W, y: Math.random() * H, vx: (Math.random() - 0.5) * 6, vy: -2 - Math.random() * 5,
        r: 0.5 + Math.random() * 1.3, ph: Math.random() * 6.28 });
    }
  }

  // ── Étincelles et photons, réutilisés eux aussi ──
  const sparks = Array.from({ length: 220 }, () => ({ live: false }));
  const photons = Array.from({ length: 26 }, () => ({ live: false }));
  let photonClock = 0;

  function spawnSparks(count) {
    const valid = samples.filter(Boolean);
    if (!valid.length) return;
    let made = 0;
    for (const s of sparks) {
      if (s.live) continue;
      const ray = valid[(Math.random() * valid.length) | 0];
      const dir = rot(ray.dir, (Math.random() - 0.5) * 0.12);
      const speed = 380 + Math.random() * 900;
      Object.assign(s, { live: true, x: ray.exit.x, y: ray.exit.y, vx: dir.x * speed, vy: dir.y * speed, life: 0, max: 0.5 + Math.random() * 0.9, c: colorAt(ray.u) });
      if (++made >= count) break;
    }
  }

  function spawnPhoton() {
    const p = photons.find((q) => !q.live);
    if (!p) return;
    Object.assign(p, { live: true, stage: 0, t: 0, u: Math.random(), speed: 700 + Math.random() * 500 });
  }

  // ── Flash ──
  function flash() {
    if (pulse) return;
    pulse = { t: 0 };
    hero.dispatchEvent(new CustomEvent("prism:flash"));
  }
  function burst() {
    boost = 1;
    spawnSparks(150);
    const title = document.querySelector(".title");
    if (title) {
      title.classList.remove("glitch"); void title.offsetWidth; title.classList.add("glitch");
      setTimeout(() => title.classList.remove("glitch"), 450);
    }
    Sound.chime();
  }

  // ── Dessin ──
  function bandPath(g, a, b, far) {
    g.beginPath();
    g.moveTo(a.exit.x, a.exit.y);
    g.lineTo(a.exit.x + a.dir.x * far, a.exit.y + a.dir.y * far);
    g.lineTo(b.exit.x + b.dir.x * far, b.exit.y + b.dir.y * far);
    g.lineTo(b.exit.x, b.exit.y);
    g.closePath();
  }

  function drawSpectrum(g, scale, strength) {
    const far = Math.max(W, H) * 2.2;
    g.globalCompositeOperation = "lighter";
    for (let i = 0; i < samples.length - 1; i++) {
      const a = samples[i], b = samples[i + 1];
      if (!a || !b || a.face !== b.face) continue;
      const u = (a.u + b.u) / 2;
      const [r, gg, bb] = colorAt(u);
      const fade = edgeFade(u) * strength;
      const o = lerp(a.exit, b.exit, 0.5), dir = norm(add(a.dir, b.dir));
      const grad = g.createLinearGradient(o.x, o.y, o.x + dir.x * far * 0.5, o.y + dir.y * far * 0.5);
      grad.addColorStop(0, `rgba(${r | 0},${gg | 0},${bb | 0},${0.34 * fade})`);
      grad.addColorStop(0.18, `rgba(${r | 0},${gg | 0},${bb | 0},${0.22 * fade})`);
      grad.addColorStop(1, `rgba(${r | 0},${gg | 0},${bb | 0},${0.05 * fade})`);
      g.fillStyle = grad;
      bandPath(g, a, b, far);
      g.fill();
    }
    g.globalCompositeOperation = "source-over";
  }

  function drawBeam(g, width, alpha) {
    const { source, entry } = beam;
    g.globalCompositeOperation = "lighter";
    g.strokeStyle = `rgba(255,255,255,${alpha})`;
    g.lineWidth = width;
    g.lineCap = "round";
    g.beginPath(); g.moveTo(source.x, source.y); g.lineTo(entry.x, entry.y); g.stroke();
    g.globalCompositeOperation = "source-over";
  }

  function drawInside(g) {
    g.globalCompositeOperation = "lighter";
    for (const s of samples) {
      if (!s) continue;
      const [r, gg, bb] = colorAt(s.u);
      g.strokeStyle = `rgba(${r | 0},${gg | 0},${bb | 0},${0.12 + boost * 0.2})`;
      g.lineWidth = 1.2;
      g.beginPath();
      g.moveTo(s.path[0].x, s.path[0].y);
      for (let i = 1; i < s.path.length; i++) g.lineTo(s.path[i].x, s.path[i].y);
      g.stroke();
    }
    g.globalCompositeOperation = "source-over";
  }

  function drawPrism(g) {
    const { T, A, B } = prism;
    g.save();
    g.beginPath(); g.moveTo(T.x, T.y); g.lineTo(B.x, B.y); g.lineTo(A.x, A.y); g.closePath();
    const fill = g.createLinearGradient(T.x, T.y, T.x, A.y);
    fill.addColorStop(0, "rgba(255,255,255,0.16)"); fill.addColorStop(1, "rgba(255,255,255,0.03)");
    g.fillStyle = fill; g.fill();
    g.lineJoin = "round";
    g.shadowColor = "rgba(255,255,255,0.6)"; g.shadowBlur = 16;
    g.strokeStyle = "rgba(255,255,255,0.92)"; g.lineWidth = 2.2; g.stroke();
    g.shadowBlur = 0;
    // Reflet sur la face gauche.
    const hl = g.createLinearGradient(A.x, A.y, T.x, T.y);
    hl.addColorStop(0, "rgba(255,255,255,0)"); hl.addColorStop(0.6, "rgba(255,255,255,0.35)"); hl.addColorStop(1, "rgba(255,255,255,0)");
    g.strokeStyle = hl; g.lineWidth = 1;
    const inset = (p) => lerp(p, prism.c, 0.08);
    g.beginPath(); g.moveTo(inset(A).x, inset(A).y); g.lineTo(inset(T).x, inset(T).y); g.stroke();
    g.restore();
  }

  function glowDot(g, p, radius, rgba) {
    const grad = g.createRadialGradient(p.x, p.y, 0, p.x, p.y, radius);
    grad.addColorStop(0, rgba); grad.addColorStop(1, "rgba(0,0,0,0)");
    g.fillStyle = grad;
    g.fillRect(p.x - radius, p.y - radius, radius * 2, radius * 2);
  }

  // L'éventail de sortie, résumé une fois par image : origine, direction médiane, angles extrêmes.
  let fan = null;
  function summarizeFan() {
    const valid = samples.filter(Boolean);
    if (valid.length < 2) { fan = null; return; }
    let o = v(0, 0);
    valid.forEach((s) => { o = add(o, s.exit); });
    const first = valid[0], last = valid[valid.length - 1];
    fan = {
      o: mul(o, 1 / valid.length), mid: norm(valid[valid.length >> 1].dir),
      a0: Math.atan2(first.dir.y, first.dir.x), a1: Math.atan2(last.dir.y, last.dir.x), u0: first.u, u1: last.u,
    };
  }
  // Où se trouve un point du spectre : u, ou null hors de l'éventail.
  function spectrumAt(px, py) {
    if (!fan) return null;
    const qx = px - fan.o.x, qy = py - fan.o.y;
    if (qx * fan.mid.x + qy * fan.mid.y < 4) return null;
    const t = (Math.atan2(qy, qx) - fan.a0) / (fan.a1 - fan.a0 || 1e-6);
    if (t < -0.02 || t > 1.02) return null;
    return Math.min(1, Math.max(0, fan.u0 + t * (fan.u1 - fan.u0)));
  }

  function distToBeam(px, py) {
    const { source, entry } = beam;
    const e = sub(entry, source), w = sub(v(px, py), source);
    const t = Math.min(1, Math.max(0, dot(w, e) / dot(e, e)));
    return len(sub(w, mul(e, t)));
  }

  function render(dt) {
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.drawImage(bg, 0, 0);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    const strength = 1 + boost * 2.2;

    // Halo : spectre et rayon dessinés en basse définition, puis agrandis (flou gratuit).
    for (const [g, cv, s] of [[gA, glowA, 4], [gB, glowB, 12]]) {
      g.setTransform(1, 0, 0, 1, 0, 0);
      g.clearRect(0, 0, cv.width, cv.height);
      g.setTransform(1 / s, 0, 0, 1 / s, 0, 0);
      drawSpectrum(g, s, strength * 1.4);
      drawBeam(g, 22, 0.35 + boost * 0.4);
    }
    ctx.globalCompositeOperation = "lighter";
    ctx.imageSmoothingEnabled = true;
    ctx.globalAlpha = 0.9; ctx.drawImage(glowB, 0, 0, W, H);
    ctx.globalAlpha = 0.75; ctx.drawImage(glowA, 0, 0, W, H);
    ctx.globalAlpha = 1;
    ctx.globalCompositeOperation = "source-over";

    drawSpectrum(ctx, 1, strength);

    // Rayon incident : cœur blanc et gaines lumineuses.
    drawBeam(ctx, 9, 0.06);
    drawBeam(ctx, 4, 0.22);
    drawBeam(ctx, 1.6, 0.95);

    drawInside(ctx);
    drawPrism(ctx);
    ctx.globalCompositeOperation = "lighter";
    glowDot(ctx, beam.entry, 26 + boost * 30, `rgba(255,255,255,${0.5 + boost * 0.4})`);
    const exits = samples.filter(Boolean);
    if (exits.length) glowDot(ctx, exits[exits.length >> 1].exit, 34 + boost * 40, `rgba(255,240,230,${0.28 + boost * 0.4})`);

    // Poussière : visible seulement dans la lumière.
    for (const p of dust) {
      if (!reduce) {
        p.x += p.vx * dt; p.y += p.vy * dt; p.ph += dt;
        if (p.y < -4) { p.y = H + 4; p.x = Math.random() * W; }
        if (p.x < -4) p.x = W + 4; else if (p.x > W + 4) p.x = -4;
      }
      const db = distToBeam(p.x, p.y);
      let r = 255, g = 255, b = 255, a = 0.05;
      if (db < 18) a = 0.9 * (1 - db / 18);
      else {
        const u = spectrumAt(p.x, p.y);
        if (u !== null) { [r, g, b] = colorAt(u); a = 0.55 * edgeFade(u); }
      }
      a *= 0.75 + 0.25 * Math.sin(p.ph * 2.3);
      if (a < 0.03) continue;
      ctx.fillStyle = `rgba(${r | 0},${g | 0},${b | 0},${a * (1 + boost)})`;
      ctx.beginPath(); ctx.arc(p.x, p.y, p.r, 0, 6.283); ctx.fill();
    }

    // Photons : de petits éclats qui suivent le chemin de la lumière.
    if (!reduce) {
      photonClock += dt;
      if (photonClock > 0.16) { photonClock = 0; spawnPhoton(); }
      for (const p of photons) {
        if (!p.live) continue;
        p.t += dt * p.speed;
        const ray = samples[Math.round(p.u * (samples.length - 1))];
        let pos, back, col = [255, 255, 255];
        if (p.stage === 0) {
          const L = len(sub(beam.entry, beam.source));
          if (p.t >= L) { p.stage = 1; p.t = 0; continue; }
          pos = add(beam.source, mul(beam.d, p.t)); back = mul(beam.d, -26);
        } else {
          if (!ray) { p.live = false; continue; }
          col = colorAt(ray.u);
          pos = add(ray.exit, mul(ray.dir, p.t)); back = mul(ray.dir, -34);
          if (pos.x > W + 40 || pos.y > H + 40 || pos.x < -40 || pos.y < -40) { p.live = false; continue; }
        }
        const grad = ctx.createLinearGradient(pos.x, pos.y, pos.x + back.x, pos.y + back.y);
        grad.addColorStop(0, `rgba(${col[0] | 0},${col[1] | 0},${col[2] | 0},0.9)`);
        grad.addColorStop(1, "rgba(0,0,0,0)");
        ctx.strokeStyle = grad; ctx.lineWidth = 1.6;
        ctx.beginPath(); ctx.moveTo(pos.x, pos.y); ctx.lineTo(pos.x + back.x, pos.y + back.y); ctx.stroke();
      }
    }

    // Le paquet de lumière d'un clic, puis les étincelles.
    if (pulse) {
      pulse.t += dt;
      const k = Math.min(1, pulse.t / 0.28);
      const pos = lerp(beam.source, beam.entry, 1 - Math.pow(1 - k, 2));
      glowDot(ctx, pos, 60, "rgba(255,255,255,0.95)");
      glowDot(ctx, pos, 14, "rgba(255,255,255,1)");
      if (k >= 1) { pulse = null; burst(); }
    }
    for (const s of sparks) {
      if (!s.live) continue;
      s.life += dt;
      if (s.life > s.max) { s.live = false; continue; }
      const drag = Math.exp(-dt * 1.6);
      s.vx *= drag; s.vy *= drag;
      s.x += s.vx * dt; s.y += s.vy * dt;
      const a = 1 - s.life / s.max;
      ctx.strokeStyle = `rgba(${s.c[0] | 0},${s.c[1] | 0},${s.c[2] | 0},${a})`;
      ctx.lineWidth = 1.4;
      ctx.beginPath(); ctx.moveTo(s.x, s.y); ctx.lineTo(s.x - s.vx * 0.025, s.y - s.vy * 0.025); ctx.stroke();
    }
    ctx.globalCompositeOperation = "source-over";

    // Éclair blanc bref sur toute la scène.
    if (boost > 0.6) {
      ctx.fillStyle = `rgba(255,255,255,${(boost - 0.6) * 0.18})`;
      ctx.fillRect(0, 0, W, H);
    }
  }

  // ── Étiquettes au bout des couleurs ──
  const labelRays = [0.5, 1.5, 2.5, 3.5, 4.5, 5.5].map((x) => x / 6);
  let labelSizes = [];
  function measureLabels() { labelSizes = families.map((el) => [el.offsetWidth, el.offsetHeight]); }
  function placeLabels() {
    const bottom = H - 96, right = W - 14;
    const spots = families.map((el, i) => {
      const u = labelRays[i];
      const ray = trace(u, DISPERSIONS[dispersionIndex], beam.entry, beam.d);
      if (!ray) return null;
      // Le point où le rayon quitte la zone visible.
      let best = Infinity;
      if (ray.dir.x > 0) best = Math.min(best, (right - ray.exit.x) / ray.dir.x);
      if (ray.dir.y > 0) best = Math.min(best, (bottom - ray.exit.y) / ray.dir.y);
      if (ray.dir.y < 0) best = Math.min(best, (70 - ray.exit.y) / ray.dir.y);
      if (!isFinite(best) || best < 40) return null;
      const p = add(ray.exit, mul(ray.dir, best));
      const [w, h] = labelSizes[i] || [100, 30];
      return { i, u, w, h, x: Math.min(Math.max(p.x - w, 8), W - w - 8), y: Math.min(Math.max(p.y - h / 2, 60), bottom - h) };
    });
    // Les étiquettes trop proches s'écartent, dans l'ordre du spectre, en restant au-dessus du bas.
    const shown = spots.filter(Boolean);
    for (let k = 1; k < shown.length; k++) shown[k].y = Math.max(shown[k].y, shown[k - 1].y + shown[k - 1].h + 2);
    const overflow = shown.length ? shown[shown.length - 1].y + shown[shown.length - 1].h - bottom : 0;
    if (overflow > 0) shown.forEach((s) => { s.y -= overflow; });
    families.forEach((el, i) => {
      const s = spots[i];
      el.classList.toggle("is-on", !!s);
      if (!s) return;
      el.style.transform = `translate(${s.x.toFixed(1)}px, ${s.y.toFixed(1)}px)`;
      const text = `λ ${lambdaNm(s.u)} nm`;
      const small = el.firstElementChild;
      if (small.textContent !== text) small.textContent = text;
    });
  }

  // ── Tableau de bord ──
  const hud = {
    inc: document.getElementById("hud-inc"), dev: document.getElementById("hud-dev"), n: document.getElementById("hud-n"),
    spread: document.getElementById("hud-spread"), k: document.getElementById("hud-k"), lambda: document.getElementById("hud-lambda"),
  };
  const fmt = (x, d = 1) => x.toFixed(d).replace(".", ",");
  let hudClock = 1;
  function updateHud(dt) {
    hudClock += dt;
    if (hudClock < 0.1) return;
    hudClock = 0;
    const k = DISPERSIONS[dispersionIndex];
    const valid = samples.filter(Boolean);
    const angle = (a, b) => Math.acos(Math.max(-1, Math.min(1, dot(norm(a), norm(b))))) / DEG;
    if (hud.inc) hud.inc.textContent = `${fmt(incidence / DEG)}°`;
    const yellow = trace(0.42, k, beam.entry, beam.d);
    if (hud.dev) hud.dev.textContent = yellow ? `${fmt(angle(beam.d, yellow.dir))}°` : "réfl. totale";
    if (hud.n) hud.n.textContent = fmt(indexAt((INV_D - INV_RED) / (INV_VIOLET - INV_RED), k), 3);
    if (hud.spread) hud.spread.textContent = valid.length > 1 ? `${fmt(angle(valid[0].dir, valid[valid.length - 1].dir), 2)}°` : "—";
    if (hud.k) hud.k.textContent = `×${k}`;
    if (hud.lambda) {
      const u = pointer.inside ? spectrumAt(pointer.px, pointer.py) : null;
      hud.lambda.textContent = u === null ? "—" : `${lambdaNm(u)} nm`;
    }
    const abBase = 3 + (pointer.x - 0.5) * 4;
    root.style.setProperty("--ab", (abBase + boost * 12).toFixed(2));
  }

  // ── Boucle ──
  let last = performance.now();
  let slowFrames = 0;
  function frame(now) {
    const dt = Math.min(0.05, (now - last) / 1000);
    last = now;
    time += dt;
    if (dt > 0.03) slowFrames++; else slowFrames = Math.max(0, slowFrames - 1);
    if (slowFrames > 90 && dpr > 1) { slowFrames = 0; dpr = 1; resize(); }
    // Sans pointeur, le rayon balaie doucement.
    if (!pointer.active || now - pointer.last > 6000) {
      incidenceTarget = (55 + Math.sin(time * 0.35) * 7) * DEG;
      tiltTarget = Math.sin(time * 0.2) * 2.5 * DEG;
    }
    const ease = 1 - Math.exp(-dt * 5);
    incidence += (incidenceTarget - incidence) * ease;
    tilt += (tiltTarget - tilt) * ease;
    boost *= Math.exp(-dt * 3.2);
    if (boost < 0.002) boost = 0;
    solve();
    render(dt);
    placeLabels();
    updateHud(dt);
    if (running && visible) requestAnimationFrame(frame); else loopOn = false;
  }
  let loopOn = false;
  function start() {
    if (loopOn || reduce) return;
    loopOn = true;
    last = performance.now();
    requestAnimationFrame(frame);
  }
  function still() { solve(); render(0); placeLabels(); updateHud(1); }

  function resize() { layout(); if (reduce || !loopOn) still(); }

  // ── Entrées ──
  hero.addEventListener("pointermove", (e) => {
    const r = hero.getBoundingClientRect();
    pointer.px = e.clientX - r.left; pointer.py = e.clientY - r.top;
    pointer.x = pointer.px / r.width; pointer.y = pointer.py / r.height;
    pointer.active = true; pointer.inside = true; pointer.last = performance.now();
    incidenceTarget = (40 + Math.min(1, Math.max(0, pointer.y)) * 34) * DEG;
    tiltTarget = (pointer.x - 0.5) * 7 * DEG;
    if (reduce) still();
  });
  hero.addEventListener("pointerleave", () => { pointer.inside = false; });
  hero.addEventListener("click", (e) => {
    if (e.target instanceof Element && e.target.closest("a, button, .hud-panel")) return;
    if (reduce) return;
    flash();
  });

  function cycleDispersion() {
    dispersionIndex = (dispersionIndex + 1) % DISPERSIONS.length;
    const btn = document.getElementById("toggle-k");
    if (btn) btn.querySelector("b").textContent = `×${DISPERSIONS[dispersionIndex]}`;
    if (reduce || !loopOn) still();
  }
  document.getElementById("toggle-k")?.addEventListener("click", cycleDispersion);
  document.getElementById("toggle-sound")?.addEventListener("click", () => Sound.toggle());
  window.addEventListener("keydown", (e) => {
    if ((e.target instanceof Element && e.target.closest("input, textarea")) || e.metaKey || e.ctrlKey || e.altKey) return;
    if (document.getElementById("lx") && !document.getElementById("lx").hidden) return;
    if (e.key === "d" || e.key === "D") cycleDispersion();
    if (e.key === "s" || e.key === "S") Sound.toggle();
  });

  // ── Son : un carillon de verre, du grave (rouge) à l'aigu (violet) ──
  const Sound = (() => {
    let ac = null, master = null, hum = null, on = false;
    const btn = document.getElementById("toggle-sound");
    function setup() {
      ac = new (window.AudioContext || window.webkitAudioContext)();
      master = ac.createGain(); master.gain.value = 0.5;
      const delay = ac.createDelay(1); delay.delayTime.value = 0.27;
      const fb = ac.createGain(); fb.gain.value = 0.32;
      const wet = ac.createBiquadFilter(); wet.type = "lowpass"; wet.frequency.value = 3200;
      master.connect(ac.destination);
      master.connect(delay); delay.connect(wet); wet.connect(fb); fb.connect(delay); wet.connect(ac.destination);
      // Un bourdon très bas, dont le filtre suit l'incidence.
      const o1 = ac.createOscillator(), o2 = ac.createOscillator();
      o1.frequency.value = 55; o2.frequency.value = 82.6; o2.detune.value = 6;
      const lp = ac.createBiquadFilter(); lp.type = "lowpass"; lp.frequency.value = 300;
      const g = ac.createGain(); g.gain.value = 0;
      o1.connect(lp); o2.connect(lp); lp.connect(g); g.connect(ac.destination);
      o1.start(); o2.start();
      hum = { g, lp };
    }
    function toggle() {
      on = !on;
      if (on && !ac) setup();
      if (ac && ac.state === "suspended") ac.resume();
      if (hum) hum.g.gain.setTargetAtTime(on ? 0.035 : 0, ac.currentTime, 0.4);
      if (btn) { btn.setAttribute("aria-pressed", String(on)); btn.querySelector("b").textContent = on ? "on" : "off"; }
      if (on) chime();
    }
    function chime() {
      if (!on || !ac) return;
      const notes = [392, 493.88, 587.33, 739.99, 880, 1174.66];
      const t0 = ac.currentTime;
      notes.forEach((f, i) => {
        const t = t0 + i * 0.045;
        const o = ac.createOscillator(), o2 = ac.createOscillator(), g = ac.createGain();
        o.type = "sine"; o.frequency.value = f;
        o2.type = "sine"; o2.frequency.value = f * 2.76; // partiel inharmonique : le verre
        const g2 = ac.createGain(); g2.gain.value = 0.18;
        g.gain.setValueAtTime(0, t);
        g.gain.linearRampToValueAtTime(0.11, t + 0.006);
        g.gain.exponentialRampToValueAtTime(0.0008, t + 2.2);
        o.connect(g); o2.connect(g2); g2.connect(g); g.connect(master);
        o.start(t); o2.start(t); o.stop(t + 2.3); o2.stop(t + 2.3);
      });
    }
    function follow() { if (hum && on) hum.lp.frequency.setTargetAtTime(160 + (incidence / DEG - 40) * 14, ac.currentTime, 0.2); }
    setInterval(follow, 200);
    return { toggle, chime };
  })();

  // ── Visibilité ──
  new IntersectionObserver(([entry]) => {
    visible = entry.isIntersecting;
    if (visible) start();
  }, { threshold: 0 }).observe(hero);
  document.addEventListener("visibilitychange", () => {
    running = !document.hidden;
    if (running) start();
  });
  let resizeTimer = 0;
  window.addEventListener("resize", () => { clearTimeout(resizeTimer); resizeTimer = setTimeout(resize, 120); });

  // Le ticker : de vraies réponses de la calculatrice et des commandes.
  const ticker = document.getElementById("ticker-run");
  if (ticker) {
    const items = [
      ["10 ft in m", "3,048 m", "--red"], ["20% off 80", "64", "--orange"], ["5pm ldn in sf", "09:00", "--yellow"],
      ["255 in hex", "0xFF", "--green"], ["#ff6161", "rgb(255 97 97)", "--red"], ["145 min en durée", "2 h 25 min", "--blue"],
      ["bonjour en anglais", "hello", "--violet"], ["oklch(0.7 0.2 30)", "#FF614D", "--orange"], ["80 + 15%", "92", "--yellow"],
      ["2^10", "1 024", "--green"], ["16px en rem", "1 rem", "--blue"], ["feu", "🔥", "--red"], ["moitié gauche", "▌", "--green"],
      ["⌘K", "actions", "--violet"], ["Tab", "Quick AI", "--yellow"],
    ];
    const html = items.map(([q, r, c]) => `<span><b>${q}</b> → <i style="--c:var(${c})">${r}</i></span>`).join("");
    ticker.innerHTML = html + html;
  }

  if (document.fonts && document.fonts.ready) document.fonts.ready.then(() => { measureLabels(); if (reduce || !loopOn) still(); });
  layout();
  if (reduce) still(); else start();
})();
