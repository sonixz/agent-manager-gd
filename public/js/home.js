// The home page: the film in the hero, the feature bar, hotspots, the views and themes viewer, the loupes, the MCP
// typer, the tunnel's wires and the loops. No dependency, no network call. With reduced motion nothing moves by itself.
(() => {
  const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const saveData = !!(navigator.connection && navigator.connection.saveData);
  const seen = (el, fn, margin = "0px 0px -15% 0px") => {
    if (!("IntersectionObserver" in window)) { fn(); return; }
    const io = new IntersectionObserver((es) => { if (es.some((e) => e.isIntersecting)) { io.disconnect(); fn(); } }, { rootMargin: margin });
    io.observe(el);
  };

  // ---------------------------------------------------------------- the film: muted, in a loop, with a Sound button
  const film = document.querySelector("video.film");
  if (film) {
    const sound = document.querySelector(".film-sound"), pause = document.querySelector(".film-pause");
    const auto = !reduce && !saveData;
    film.removeAttribute("controls");      // without script the native controls stay
    film.muted = true;
    const setPause = () => { pause.textContent = film.paused ? "▶" : "❚❚"; pause.setAttribute("aria-pressed", String(film.paused)); pause.setAttribute("aria-label", film.paused ? "Play the film" : "Pause the film"); };
    const setSound = () => { sound.textContent = film.muted ? "🔊 Sound" : "🔇 Mute"; sound.setAttribute("aria-pressed", String(!film.muted)); };
    film.addEventListener("play", setPause); film.addEventListener("pause", setPause);
    if (auto) {
      film.preload = "auto";
      // the film opens on a fade from black: the silent loop starts just after it (with the sound, from the start)
      film.addEventListener("loadedmetadata", () => { if (film.muted && film.currentTime < 1) film.currentTime = 1.2; }, { once: true });
      // plays while it is on screen, rests when it is not
      if ("IntersectionObserver" in window) {
        new IntersectionObserver((es) => { for (const e of es) { if (e.isIntersecting) film.play().catch(() => {}); else if (film.muted) film.pause(); } }, { threshold: 0.25 }).observe(film);
      } else film.play().catch(() => {});
    }
    sound.addEventListener("click", () => {
      if (film.muted) { film.muted = false; film.currentTime = 0; film.loop = false; film.play().catch(() => {}); }
      else { film.muted = true; film.loop = true; }
      setSound();
    });
    film.addEventListener("ended", () => { film.muted = true; film.loop = true; setSound(); if (auto) film.play().catch(() => {}); });
    pause.addEventListener("click", () => { if (film.paused) film.play().catch(() => {}); else film.pause(); });
    film.addEventListener("click", () => { if (film.paused) film.play().catch(() => {}); else film.pause(); });
    setPause(); setSound();
  }

  // ---------------------------------------------------------------- counters
  document.querySelectorAll(".stats b[data-count]").forEach((b) => {
    if (reduce) return;
    const end = +b.dataset.count;
    b.textContent = "0";
    seen(b, () => {
      const t0 = performance.now(), dur = 1300;
      const step = (now) => { const p = Math.min(1, (now - t0) / dur); b.textContent = String(Math.round(end * (1 - Math.pow(1 - p, 3)))); if (p < 1) requestAnimationFrame(step); };
      requestAnimationFrame(step);
    }, "0px");
  });

  // ---------------------------------------------------------------- the feature bar: sticky once past the index, follows the page
  const bar = document.querySelector(".featnav"), index = document.getElementById("features");
  if (bar && index) {
    const links = [...bar.querySelectorAll("a")];
    const targets = links.map((a) => document.getElementById(a.getAttribute("href").slice(1))).filter(Boolean);
    const prog = bar.querySelector(".featnav-progress");
    const onScroll = () => {
      const past = index.getBoundingClientRect().bottom < 70;
      const lastSec = document.getElementById("loops");
      const before = lastSec ? lastSec.getBoundingClientRect().bottom > 140 : true;
      bar.classList.toggle("show", past && before);
      let cur = null;
      for (const t of targets) if (t.getBoundingClientRect().top < window.innerHeight * 0.35) cur = t;
      links.forEach((a) => a.classList.toggle("on", cur && a.getAttribute("href") === "#" + cur.id));
      const on = bar.querySelector("a.on");
      if (on && bar.classList.contains("show")) {
        const box = bar.querySelector(".featnav-in");
        const l = on.offsetLeft - box.clientWidth / 2 + on.clientWidth / 2;
        if (Math.abs(box.scrollLeft - l) > 40) box.scrollTo({ left: l, behavior: reduce ? "auto" : "smooth" });
      }
      const first = targets[0], end = lastSec;
      if (first && end && prog) {
        const a = first.offsetTop, z = end.offsetTop;
        prog.style.transform = `scaleX(${Math.max(0, Math.min(1, (window.scrollY + 120 - a) / (z - a)))})`;
      }
    };
    window.addEventListener("scroll", onScroll, { passive: true });
    window.addEventListener("resize", onScroll);
    onScroll();
  }

  // ---------------------------------------------------------------- hotspots: one after the other, then all stay
  document.querySelectorAll("[data-hot]").forEach((fig) => {
    const hots = [...fig.querySelectorAll(".hot")];
    seen(fig, () => {
      hots.forEach((h, i) => setTimeout(() => h.classList.add("in"), reduce ? 0 : 500 + i * 650));
      if (reduce) return;
      // then each label in turn, as a guided tour, until the pointer comes
      let k = 0, timer = 0;
      const tour = () => { hots.forEach((h) => h.classList.remove("lit")); hots[k % hots.length].classList.add("lit"); k++; };
      setTimeout(() => { tour(); timer = setInterval(tour, 2200); }, 500 + hots.length * 650);
      fig.addEventListener("pointerenter", () => { clearInterval(timer); hots.forEach((h) => h.classList.remove("lit")); fig.classList.add("all"); });
    });
  });

  // ---------------------------------------------------------------- views and themes
  document.querySelectorAll("[data-viewer]").forEach((v) => {
    const img = v.querySelector(".viewer-img");
    const tabs = [...v.querySelectorAll("[role=tab]")], sws = [...v.querySelectorAll(".sw")];
    const show = (btn) => {
      const src = btn.dataset.src;
      if (img.getAttribute("src") === src) return;
      const pre = new Image();
      pre.onload = () => {
        img.classList.add("swap");
        setTimeout(() => { img.src = src; img.alt = btn.dataset.alt; img.classList.remove("swap"); }, reduce ? 0 : 180);
      };
      pre.src = src;
    };
    tabs.forEach((t) => t.addEventListener("click", () => {
      tabs.forEach((x) => x.setAttribute("aria-selected", String(x === t)));
      sws.forEach((s) => s.classList.toggle("on", false));
      v.classList.toggle("alt", t !== tabs[0]);   // the points belong to the first picture
      show(t);
    }));
    sws.forEach((s) => s.addEventListener("click", () => {
      sws.forEach((x) => x.classList.toggle("on", x === s));
      tabs.forEach((x) => x.setAttribute("aria-selected", String(x.textContent === "Grid")));
      show(s);
    }));
  });

  // ---------------------------------------------------------------- loupes: a detail of the screenshot, and a lens under the pointer
  document.querySelectorAll(".loupe-fig").forEach((fig) => {
    const img = fig.querySelector("img"), det = fig.querySelector(".loupe-detail");
    if (!img || !det) return;
    // data-c="x y zoom": the point of the screenshot to show (fractions) and how much to enlarge it
    const [cx, cy, z] = (fig.dataset.c || "0.5 0.5 3").split(" ").map(Number);
    const place = () => {
      const w = det.clientWidth, h = det.clientHeight, iw = img.naturalWidth || +img.getAttribute("width"), ih = img.naturalHeight || +img.getAttribute("height");
      if (!w || !iw) return;
      const bw = w * z, bh = bw * ih / iw;
      det.style.backgroundSize = `${bw}px ${bh}px`;
      det.style.backgroundPosition = `${Math.min(0, Math.max(w - bw, w / 2 - cx * bw))}px ${Math.min(0, Math.max(h - bh, h / 2 - cy * bh))}px`;
    };
    if (img.complete) place(); else img.addEventListener("load", place);
    window.addEventListener("resize", place);
    seen(fig, () => { place(); fig.classList.add("zoomed"); });
    if (!window.matchMedia("(hover: hover)").matches) return;
    const lens = document.createElement("span");
    lens.className = "lens";
    lens.setAttribute("aria-hidden", "true");
    lens.style.backgroundImage = `url(${img.getAttribute("src")})`;
    fig.appendChild(lens);
    fig.addEventListener("pointermove", (e) => {
      const r = img.getBoundingClientRect();
      const x = (e.clientX - r.left) / r.width, y = (e.clientY - r.top) / r.height;
      if (x < 0 || x > 1 || y < 0 || y > 1) { lens.classList.remove("on"); return; }
      const Z = 2.6, size = lens.offsetWidth || 190;
      lens.style.left = `${e.clientX - fig.getBoundingClientRect().left - size / 2}px`;
      lens.style.top = `${e.clientY - fig.getBoundingClientRect().top - size / 2}px`;
      lens.style.backgroundSize = `${r.width * Z}px ${r.height * Z}px`;
      lens.style.backgroundPosition = `${-(x * r.width * Z - size / 2)}px ${-(y * r.height * Z - size / 2)}px`;
      lens.classList.add("on");
    });
    fig.addEventListener("pointerleave", () => lens.classList.remove("on"));
  });

  // ---------------------------------------------------------------- the MCP typer: an example of calls, typed
  const typer = document.querySelector(".typer-lines");
  if (typer) {
    const script = [
      ["c", "# a lead agent, through agent-manager's MCP server"],
      ["k", "list_sessions()"],
      ["o", "  Checkout flow · working   Flaky tests · waits for your OK   Rate limiter · working"],
      ["k", "start_session(name=\"Helper · tests\", tool=\"shell\", cwd=\"~/code/orbit-api\")"],
      ["o", "  ↳ started, under « Release lead »"],
      ["k", "send_to_session(\"Helper · tests\", \"python3 -m unittest -v\")"],
      ["k", "wait_for_session(\"Helper · tests\")"],
      ["o", "  done"],
      ["k", "read_screen(\"Helper · tests\")"],
      ["g", "  Ran 3 tests in 0.000s · OK"],
    ];
    const render = (n, partial) => {
      typer.innerHTML = "";
      script.slice(0, n).forEach(([c, t], i) => {
        const d = document.createElement("div");
        d.className = "tl " + c;
        d.textContent = (i === n - 1 && partial != null) ? t.slice(0, partial) : t;
        typer.appendChild(d);
      });
    };
    if (reduce) render(script.length);
    else seen(typer, () => {
      let line = 0, ch = 0;
      const tick = () => {
        if (line >= script.length) { setTimeout(() => { line = 0; ch = 0; tick(); }, 5200); return; }
        const [c, t] = script[line];
        if (c === "k" && ch < t.length) { ch += 2; render(line + 1, ch); setTimeout(tick, 28); return; }
        render(line + 1); line++; ch = 0;
        setTimeout(tick, c === "k" ? 420 : 650);
      };
      tick();
    });
  }

  // ---------------------------------------------------------------- the tunnel's wires: still with reduced motion
  const wires = document.querySelector(".tn-wires");
  if (wires && reduce && wires.pauseAnimations) wires.pauseAnimations();

  // ---------------------------------------------------------------- loops: a dot per loop, themes, search, the latest first
  const ui = document.querySelector(".loops-ui");
  if (ui) {
    const list = ui.querySelector(".loop-list"), rail = ui.querySelector(".loop-rail");
    const cards = [...list.querySelectorAll(".loop")];
    const toggle = ui.querySelector(".loop-toggle"), search = ui.querySelector(".loop-search input");
    const phases = [...ui.querySelectorAll(".loop-phases button")];
    let phase = "all", q = "";
    // the rail, oldest to newest
    cards.slice().reverse().forEach((c) => {
      const b = document.createElement("button");
      b.type = "button";
      b.className = c.className.replace("loop", "dot-b");
      b.title = c.querySelector(".loop-tag").textContent + ": " + c.querySelector("h3").textContent;
      b.innerHTML = `<span class="dot"></span><span class="lbl"></span>`;
      b.querySelector(".lbl").textContent = c.dataset.loop;
      b.addEventListener("click", () => {
        list.classList.remove("collapsed"); toggle.setAttribute("aria-expanded", "true"); toggle.textContent = "Show the latest only";
        phase = "all"; q = ""; search.value = ""; apply();
        c.scrollIntoView({ behavior: reduce ? "auto" : "smooth", block: "center" });
        c.classList.remove("flash"); void c.offsetWidth; c.classList.add("flash");
      });
      c._dot = b;
      rail.appendChild(b);
    });
    rail.scrollLeft = rail.scrollWidth;
    const apply = () => {
      let shown = 0;
      cards.forEach((c) => {
        const ok = (phase === "all" || c.dataset.phase === phase) && (!q || c.textContent.toLowerCase().includes(q));
        c.hidden = !ok;
        c._dot.classList.toggle("dim", !ok);
        if (ok) shown++;
      });
      phases.forEach((p) => p.setAttribute("aria-pressed", String(p.dataset.phase === phase)));
      const filtering = phase !== "all" || q;
      list.classList.toggle("filtering", !!filtering);
      toggle.hidden = !!filtering || cards.length <= 6;
      list.dataset.empty = shown ? "" : "Nothing matches.";
    };
    phases.forEach((p) => p.addEventListener("click", () => { phase = p.dataset.phase; apply(); }));
    search.addEventListener("input", () => { q = search.value.trim().toLowerCase(); apply(); });
    toggle.textContent = `Show all ${cards.length} loops`;
    toggle.addEventListener("click", () => {
      const open = list.classList.toggle("collapsed") === false;
      toggle.setAttribute("aria-expanded", String(open));
      toggle.textContent = open ? "Show the latest only" : `Show all ${cards.length} loops`;
      if (!open) ui.scrollIntoView({ behavior: reduce ? "auto" : "smooth", block: "start" });
    });
    apply();
  }
})();
