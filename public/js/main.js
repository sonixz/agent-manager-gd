// Agent Manager GD website. No dependencies, no network calls.
(() => {
  const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  // Mobile navigation
  const toggle = document.querySelector(".nav-toggle");
  const links = document.getElementById("nav-links");
  if (toggle && links) {
    toggle.addEventListener("click", () => {
      const open = links.classList.toggle("open");
      toggle.setAttribute("aria-expanded", String(open));
    });
    links.addEventListener("click", (e) => { if (e.target.closest("a")) links.classList.remove("open"); });
  }

  // Reveal sections on scroll
  const reveals = document.querySelectorAll(".reveal");
  if ("IntersectionObserver" in window && !reduce) {
    const io = new IntersectionObserver((entries) => {
      for (const e of entries) if (e.isIntersecting) { e.target.classList.add("in"); io.unobserve(e.target); }
    }, { rootMargin: "0px 0px -8% 0px" });
    reveals.forEach((el) => io.observe(el));
  } else {
    reveals.forEach((el) => el.classList.add("in"));
  }

  // Screenshots open full size
  const box = document.createElement("div");
  box.className = "lightbox";
  box.setAttribute("role", "dialog");
  box.setAttribute("aria-label", "Screenshot, full size");
  const big = document.createElement("img");
  box.appendChild(big);
  document.body.appendChild(box);
  const close = () => { if (!box.classList.contains("open")) return; box.classList.remove("open"); if (opener) opener.focus(); };
  box.addEventListener("click", close);
  document.addEventListener("keydown", (e) => { if (e.key === "Escape") close(); });
  let opener = null;  // where the keyboard focus goes back when the lightbox closes
  const openBox = (src, alt, from) => { big.src = src; big.alt = alt; box.classList.add("open"); opener = from; box.focus(); };
  box.tabIndex = -1;
  document.querySelectorAll(".screen img, .shot img").forEach((img) => {
    img.tabIndex = 0;  // screenshots open full size from the keyboard too
    img.setAttribute("role", "button");
    img.setAttribute("aria-label", "Open full size: " + (img.alt || "screenshot"));
    img.addEventListener("click", () => openBox(img.currentSrc || img.src, img.alt, img));
    img.addEventListener("keydown", (e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); openBox(img.currentSrc || img.src, img.alt, img); } });
  });

  document.querySelectorAll("a.live-real").forEach((a) => a.addEventListener("click", (e) => {
    e.preventDefault(); openBox(a.href, "Agent Manager GD in Grid view, the real app", a);
  }));

  // Hero ticker: what the left column tells you, as it happens
  const ticker = document.querySelector(".ticker");
  if (ticker) {
    const events = [
      ["working", "Checkout flow · working"],
      ["ok", "Flaky tests · waits for your OK"],
      ["asks", "Rate limiter · asks you a question"],
      ["done", "Sparks · done, 3 files changed"],
      ["working", "Helper · tests · started by an agent"],
      ["done", "Session journal proposed to the Second Brain"],
    ];
    let i = 0;
    const show = () => {
      const [kind, text] = events[i % events.length];
      const pill = document.createElement("span");
      pill.className = "pill";
      pill.innerHTML = `<span class="light ${kind}"></span>`;
      pill.appendChild(document.createTextNode(text));
      ticker.prepend(pill);
      while (ticker.children.length > 2) ticker.lastElementChild.remove();
      i++;
    };
    show();
    setInterval(show, 2600);  // a text change, not a movement: it runs with reduced motion too
  }

  // Hero background: a quiet dot grid (CSS) and, on it, a few soft lights in the sessions' state colours that come and
  // go; now and then two of them link up, like an agent starting a helper
  const canvas = document.querySelector(".hero-matrix");
  if (canvas && canvas.getContext) {
    const ctx = canvas.getContext("2d");
    const colours = ["147, 207, 245", "255, 158, 100", "245, 207, 116", "143, 227, 239", "200, 182, 255"];
    const STEP = 28;
    let w = 0, h = 0, lights = [], links = [];
    const spot = () => ({ x: Math.round(Math.random() * w / STEP) * STEP, y: Math.round(Math.random() * h / STEP) * STEP });
    const newLight = (now) => ({ ...spot(), c: colours[Math.floor(Math.random() * colours.length)], born: now - Math.random() * 4000, life: 3500 + Math.random() * 4000 });
    const resize = () => {
      const r = canvas.getBoundingClientRect();
      const dpr = Math.min(window.devicePixelRatio || 1, 2);
      w = r.width; h = r.height;
      canvas.width = w * dpr; canvas.height = h * dpr;
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      const n = Math.max(6, Math.min(16, Math.round(w * h / 60000)));
      lights = Array.from({ length: n }, () => newLight(performance.now()));
    };
    const draw = (now) => {
      ctx.clearRect(0, 0, w, h);
      for (let i = 0; i < lights.length; i++) {
        const l = lights[i], t = (now - l.born) / l.life;
        if (t >= 1) { lights[i] = newLight(now); lights[i].born = now; continue; }
        const a = Math.sin(Math.PI * Math.max(0, t));  // fades in, then out
        const g = ctx.createRadialGradient(l.x, l.y, 0, l.x, l.y, 26);
        g.addColorStop(0, `rgba(${l.c}, ${0.22 * a})`); g.addColorStop(1, `rgba(${l.c}, 0)`);
        ctx.fillStyle = g; ctx.fillRect(l.x - 26, l.y - 26, 52, 52);
        ctx.fillStyle = `rgba(${l.c}, ${0.75 * a})`;
        ctx.beginPath(); ctx.arc(l.x, l.y, 1.8, 0, Math.PI * 2); ctx.fill();
      }
      links = links.filter((k) => now - k.born < 2600);
      for (const k of links) {
        const t = (now - k.born) / 2600, a = Math.sin(Math.PI * t) * 0.25, p = Math.min(1, t * 2.2);
        ctx.strokeStyle = `rgba(${k.a.c}, ${a})`; ctx.lineWidth = 1;
        ctx.beginPath(); ctx.moveTo(k.a.x, k.a.y);
        ctx.lineTo(k.a.x, k.a.y + (k.b.y - k.a.y) * p);
        if (p > 0.5) ctx.lineTo(k.a.x + (k.b.x - k.a.x) * (p - 0.5) * 2, k.b.y);  // an elbow, like a branch in the session tree
        ctx.stroke();
      }
      if (!reduce) requestAnimationFrame(draw);
    };
    resize();
    window.addEventListener("resize", () => { resize(); if (reduce) requestAnimationFrame(draw); });
    requestAnimationFrame(draw);
    if (!reduce) setInterval(() => {
      const a = lights[Math.floor(Math.random() * lights.length)];
      const b = { ...a, x: a.x + STEP * (3 + Math.floor(Math.random() * 5)), y: a.y + STEP * (2 + Math.floor(Math.random() * 3)) };
      if (b.x < w && b.y < h) { links.push({ a, b, born: performance.now() }); lights.push({ ...b, born: performance.now() + 1100, life: 3200 }); }
      if (lights.length > 22) lights.splice(0, lights.length - 22);
    }, 3200);
  }

  // Docs and How-to: highlight the section in view in the side navigation
  const toc = document.querySelector(".toc");
  if (toc && "IntersectionObserver" in window) {
    const map = new Map();
    toc.querySelectorAll('a[href^="#"]').forEach((a) => { const t = document.getElementById(a.getAttribute("href").slice(1)); if (t) map.set(t, a); });
    const spy = new IntersectionObserver((entries) => {
      for (const e of entries) if (e.isIntersecting) {
        toc.querySelectorAll("a.active").forEach((a) => a.classList.remove("active"));
        map.get(e.target)?.classList.add("active");
      }
    }, { rootMargin: "-20% 0px -70% 0px" });
    map.forEach((_, t) => spy.observe(t));
  }
})();
