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
  const close = () => box.classList.remove("open");
  box.addEventListener("click", close);
  document.addEventListener("keydown", (e) => { if (e.key === "Escape") close(); });
  document.querySelectorAll(".screen img, .shot img").forEach((img) => {
    img.addEventListener("click", () => { big.src = img.currentSrc || img.src; big.alt = img.alt; box.classList.add("open"); });
  });

  document.querySelectorAll("a.live-real").forEach((a) => a.addEventListener("click", (e) => {
    e.preventDefault(); big.src = a.href; big.alt = "Agent Manager GD in Grid view, the real app"; box.classList.add("open");
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
    if (!reduce) setInterval(show, 2600);
  }

  // Hero background: a wall of tiny terminals, a few of them busy
  const canvas = document.querySelector(".hero-matrix");
  if (canvas && canvas.getContext) {
    const ctx = canvas.getContext("2d");
    let cells = [], w = 0, h = 0;
    const colours = ["#93cff5", "#ff9e64", "#f5cf74", "#7dd3a8"];
    const resize = () => {
      const r = canvas.getBoundingClientRect();
      const dpr = Math.min(window.devicePixelRatio || 1, 2);
      w = r.width; h = r.height;
      canvas.width = w * dpr; canvas.height = h * dpr;
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      cells = [];
      const cw = 92, ch = 58;
      for (let y = 8; y < h; y += ch) for (let x = 8; x < w; x += cw) {
        cells.push({ x, y, lines: 2 + Math.floor(Math.random() * 3), busy: Math.random() < .12, t: Math.random() * 100,
          c: colours[Math.floor(Math.random() * colours.length)] });
      }
    };
    const draw = (now) => {
      ctx.clearRect(0, 0, w, h);
      for (const c of cells) {
        ctx.strokeStyle = "rgba(51, 80, 109, .55)";
        ctx.lineWidth = 1;
        ctx.strokeRect(c.x + .5, c.y + .5, 80, 46);
        ctx.fillStyle = c.busy ? c.c : "rgba(97, 124, 146, .7)";
        ctx.beginPath(); ctx.arc(c.x + 8, c.y + 8, 2.4, 0, Math.PI * 2); ctx.fill();
        const phase = (now / 900 + c.t) % 6;
        for (let l = 0; l < c.lines; l++) {
          const len = 18 + ((c.t * 7 + l * 13) % 44);
          const shown = c.busy && l === c.lines - 1 ? len * Math.min(1, phase / 3) : len;
          ctx.fillStyle = l === 0 ? "rgba(143, 227, 239, .35)" : "rgba(159, 182, 200, .22)";
          ctx.fillRect(c.x + 8, c.y + 17 + l * 7, shown, 2.5);
        }
        if (c.busy && Math.floor(now / 500) % 2 === 0) {
          ctx.fillStyle = "rgba(201, 244, 249, .8)";
          ctx.fillRect(c.x + 8, c.y + 17 + c.lines * 7, 5, 4);
        }
      }
      if (!reduce) requestAnimationFrame(draw);
    };
    resize();
    window.addEventListener("resize", resize);
    requestAnimationFrame(draw);
    if (!reduce) setInterval(() => { const c = cells[Math.floor(Math.random() * cells.length)]; if (c) c.busy = !c.busy; }, 700);
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
