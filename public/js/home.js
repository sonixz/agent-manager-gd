// The home page: the film in the hero, the feature bar, the pictures' numbered points, the views and themes viewer, the zooms, the MCP
// map and the loops. No dependency, no network call. With reduced motion nothing moves by itself.
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

  // ---------------------------------------------------------------- a picture's numbered points and their cards
  // Each card (data-for) belongs to a point on the picture (data-n). Beside the picture, a line joins them; under it,
  // the number does. A tour lights one at a time while it is on screen; the pointer or the keyboard takes over.
  document.querySelectorAll("[data-anno]").forEach((anno) => {
    const svg = anno.querySelector(".anno-lines"), NS = "http://www.w3.org/2000/svg";
    const cards = [...anno.querySelectorAll(".anno-card")], dots = [...anno.querySelectorAll(".hot")];
    const dotOf = (n) => dots.find((d) => d.dataset.n === n);
    const shown = (el) => el && el.offsetParent !== null;
    const lines = {};
    const draw = () => {
      if (!svg) return;
      const m = anno.getBoundingClientRect();
      svg.setAttribute("viewBox", `0 0 ${m.width} ${m.height}`);
      for (const c of cards) {
        const n = c.dataset.for, d = dotOf(n);
        if (!lines[n]) { lines[n] = document.createElementNS(NS, "path"); svg.appendChild(lines[n]); }
        if (!shown(c) || !shown(d)) { lines[n].setAttribute("d", ""); continue; }
        const C = c.getBoundingClientRect(), D = d.getBoundingClientRect();
        const left = C.right <= D.left, right = C.left >= D.right;
        if (!left && !right) { lines[n].setAttribute("d", ""); continue; }   // the card is under the picture: no line
        const x1 = (left ? C.right : C.left) - m.left, y1 = C.top + Math.min(C.height / 2, 30) - m.top;
        const x2 = (left ? D.left - 3 : D.right + 3) - m.left, y2 = D.top + D.height / 2 - m.top, dx = (x2 - x1) / 2;
        lines[n].setAttribute("d", `M${x1},${y1} C${x1 + dx},${y1} ${x2 - dx},${y2} ${x2},${y2}`);
      }
    };
    const light = (n) => {
      cards.forEach((c) => c.classList.toggle("on", c.dataset.for === n));
      dots.forEach((d) => d.classList.toggle("on", d.dataset.n === n));
      Object.keys(lines).forEach((k) => lines[k].classList.toggle("on", k === n));
    };
    let at = -1, held = false, onScreen = false;
    const next = () => {
      const live = cards.filter(shown);
      if (!live.length) return;
      at = (at + 1) % live.length;
      light(live[at].dataset.for);
    };
    const take = (n) => { held = true; light(n); };
    cards.forEach((c) => {
      c.addEventListener("pointerenter", () => take(c.dataset.for));
      c.addEventListener("focus", () => take(c.dataset.for));
    });
    dots.forEach((d) => d.addEventListener("pointerenter", () => take(d.dataset.n)));
    anno.addEventListener("pointerleave", () => { held = false; });
    // the picture's other state (the viewer's tabs) has its own points and cards
    const viewer = anno.closest("[data-viewer]");
    if (viewer) viewer.addEventListener("click", (e) => { if (e.target.closest("[role=tab]")) setTimeout(() => { at = -1; light(""); draw(); if (!reduce) next(); }, 0); });
    draw();
    window.addEventListener("resize", draw);
    window.addEventListener("load", draw);
    if (document.fonts && document.fonts.ready) document.fonts.ready.then(draw);
    if (reduce) return;   // nothing lights by itself
    if ("IntersectionObserver" in window) new IntersectionObserver((es) => { onScreen = es.some((e) => e.isIntersecting); if (onScreen) draw(); }, { threshold: 0.3 }).observe(anno);
    else onScreen = true;
    setInterval(() => { if (onScreen && !held) next(); }, 2600);
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
      v.classList.toggle("alt", t !== tabs[0]);   // each state of the picture has its own points and cards
      show(t);
    }));
    sws.forEach((s) => s.addEventListener("click", () => {
      sws.forEach((x) => x.classList.toggle("on", x === s));
      tabs.forEach((x) => x.setAttribute("aria-selected", String(x.textContent === "Grid")));
      show(s);
    }));
  });

  // ---------------------------------------------------------------- screenshots that zoom inside their frame towards a detail
  // data-zoom="x y zoom": the detail's centre (fractions of the picture) and how much. The picture grows around the
  // point that brings that centre to the middle of the frame, kept inside the picture so the frame stays full.
  document.querySelectorAll(".zoom-fig").forEach((fig, idx) => {
    const frame = fig.querySelector(".zoom-frame"), btn = fig.querySelector(".zoom-toggle");
    if (!frame || !btn) return;
    const [cx, cy, z = 3] = (fig.dataset.zoom || "0.5 0.5").split(" ").map(Number);
    const origin = (c) => (Math.max(0, Math.min(1, (z * c - 0.5) / (z - 1))) * 100).toFixed(2) + "%";
    fig.style.setProperty("--ox", origin(cx)); fig.style.setProperty("--oy", origin(cy)); fig.style.setProperty("--z", String(z));
    let auto = !reduce, on = false, timer = 0, visible = false, first = true;
    const set = (v) => {
      on = v; fig.classList.toggle("zoomed", v);
      btn.textContent = v ? "⤢ Whole picture" : "🔍 Detail"; btn.setAttribute("aria-pressed", String(v));
    };
    // by itself while it is on screen: the whole picture, then the detail, then back
    const tick = () => {
      clearTimeout(timer);
      if (!auto || !visible) return;
      const wait = on ? 5200 : first ? 1300 + (idx % 2) * 1100 : 3400;
      first = false;
      timer = setTimeout(() => { set(!on); tick(); }, wait);
    };
    if ("IntersectionObserver" in window) {
      new IntersectionObserver((es) => {
        visible = es.some((e) => e.isIntersecting);
        if (visible) tick(); else { clearTimeout(timer); if (auto) { set(false); first = true; } }
      }, { threshold: 0.55 }).observe(frame);
    }
    btn.addEventListener("click", () => { auto = false; clearTimeout(timer); set(!on); });   // by hand from now on
  });

  // ---------------------------------------------------------------- the built-in MCP: a map of who calls what, played step by step
  const stage = document.querySelector("[data-mcp]");
  if (stage) {
    const map = stage.querySelector(".mcp-map"), svg = map.querySelector(".mm-lines"), log = stage.querySelector(".mcp-lines");
    const hubCall = map.querySelector(".mm-call"), pauseB = stage.querySelector(".mcp-pause");
    const tools = [...document.querySelectorAll(".mcp-tool")];
    const N = {};
    map.querySelectorAll("[data-n]").forEach((el) => { N[el.dataset.n] = el; });
    const NS = "http://www.w3.org/2000/svg";
    const EDGES = [["lead", "hub"], ["hub", "s1"], ["hub", "s2"], ["hub", "s3"], ["hub", "k1"]];
    const paths = {};
    // a line from one box to the next, wherever the layout put them (side by side, or one under the other)
    const edge = (a, b) => {
      const m = map.getBoundingClientRect(), A = N[a].getBoundingClientRect(), B = N[b].getBoundingClientRect();
      if (B.left >= A.right - 4) {
        const x1 = A.right - m.left, y1 = A.top + A.height / 2 - m.top, x2 = B.left - m.left, y2 = B.top + B.height / 2 - m.top, dx = (x2 - x1) / 2;
        return `M${x1},${y1} C${x1 + dx},${y1} ${x2 - dx},${y2} ${x2},${y2}`;
      }
      const x2 = B.left + B.width / 2 - m.left, y2 = B.top - m.top, y1 = A.bottom - m.top;
      const x1 = Math.max(A.left - m.left + 14, Math.min(A.right - m.left - 14, x2)), dy = (y2 - y1) / 2;
      return `M${x1},${y1} C${x1},${y1 + dy} ${x2},${y2 - dy} ${x2},${y2}`;
    };
    const draw = () => {
      svg.setAttribute("viewBox", `0 0 ${map.clientWidth} ${map.clientHeight}`);
      for (const [a, b] of EDGES) {
        const key = a + "-" + b;
        if (!paths[key]) { paths[key] = document.createElementNS(NS, "path"); svg.appendChild(paths[key]); }
        paths[key].setAttribute("d", edge(a, b));
      }
    };
    const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
    let run = 0, paused = false, onScreen = false;
    const alive = (id) => id === run;
    const pulse = (key, id, back = false, dur = 520) => new Promise((res) => {
      const p = paths[key];
      if (!p || reduce || !alive(id)) { res(); return; }
      p.classList.add("hot");
      const len = p.getTotalLength(), dot = document.createElementNS(NS, "circle"), t0 = performance.now();
      dot.setAttribute("r", "5"); dot.setAttribute("class", "mm-dot"); svg.appendChild(dot);
      const step = (now) => {
        const k = Math.min(1, (now - t0) / dur), pt = p.getPointAtLength(len * (back ? 1 - k : k));
        dot.setAttribute("cx", pt.x); dot.setAttribute("cy", pt.y);
        if (k < 1 && alive(id)) requestAnimationFrame(step);
        else { dot.remove(); setTimeout(() => p.classList.remove("hot"), 350); res(); }
      };
      requestAnimationFrame(step);
    });
    const flash = (n, cls = "flash", ms = 900) => { N[n].classList.add(cls); setTimeout(() => N[n].classList.remove(cls), ms); };
    const kid = (state, words) => {   // "off" | "idle" | "working" | "done"
      const k = N.k1;
      k.classList.toggle("off", state === "off");
      paths["hub-k1"] && paths["hub-k1"].classList.toggle("off", state === "off");
      k.querySelector(".light").className = "light" + (state === "working" ? " working" : state === "done" ? " done" : "");
      k.querySelector("small").textContent = words;
    };
    const esc = (s) => s.replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]));
    const line = (cls, text) => {
      const d = document.createElement("div");
      d.className = "ml " + cls; d.textContent = text; log.appendChild(d);
      while (log.children.length > 1 && log.scrollHeight > log.clientHeight + 1) log.firstChild.remove();   // the oldest lines leave, as in a terminal
      return d;
    };
    const pretty = (d, text) => { const i = text.indexOf("("); d.innerHTML = `<span class="fn">${esc(text.slice(0, i))}</span>${esc(text.slice(i))}`; };
    const type = async (text, id) => {
      const d = line("call typing", "");
      if (!reduce) for (let i = 0; i <= text.length; i += 3) { if (!alive(id)) return; d.textContent = text.slice(0, i); await sleep(20); }
      d.classList.remove("typing"); pretty(d, text);
      while (log.children.length > 1 && log.scrollHeight > log.clientHeight + 1) log.firstChild.remove();
    };
    // the example: every tool once, and the one refusal that matters. Each step: the call, what moves, what comes back.
    const STEPS = [
      { tool: "list_sessions", call: "list_sessions()", out: [["res", "Checkout flow · working"], ["res", "Flaky tests · waits for your OK"], ["res", "Rate limiter · working"]],
        fx: async (id) => { await pulse("lead-hub", id); await Promise.all(["s1", "s2", "s3"].map((n) => pulse("hub-" + n, id))); ["s1", "s2", "s3"].forEach((n) => flash(n)); await pulse("lead-hub", id, true); } },
      { tool: "session_status", call: "session_status(\"Flaky tests\")", out: [["res", "waits for your OK · « Claude needs your permission »"]],
        fx: async (id) => { await pulse("lead-hub", id); await pulse("hub-s2", id); flash("s2"); await pulse("hub-s2", id, true); await pulse("lead-hub", id, true); } },
      { tool: "send_to_session", call: "send_to_session(\"Flaky tests\", \"1\")", out: [["no", "refused · you may only write to sessions you started"]],
        fx: async (id) => { await pulse("lead-hub", id); if (!alive(id)) return; paths["hub-s2"].classList.add("no"); flash("hub", "blocked", 600); await sleep(900); paths["hub-s2"].classList.remove("no"); } },
      { tool: "start_session", call: "start_session(name=\"Helper · tests\", tool=\"shell\")", out: [["ok", "started · ↳ Release lead"]],
        fx: async (id) => { await pulse("lead-hub", id); if (!alive(id)) return; kid("idle", "ready · ↳ Release lead"); await pulse("hub-k1", id); flash("k1"); } },
      { tool: "send_to_session", call: "send_to_session(\"Helper · tests\", \"python3 -m unittest -v\")", out: [["ok", "sent"]],
        fx: async (id) => { await pulse("lead-hub", id); await pulse("hub-k1", id); if (alive(id)) kid("working", "working · ↳ Release lead"); } },
      { tool: "wait_for_session", call: "wait_for_session(\"Helper · tests\")", out: [["ok", "done"]],
        fx: async (id) => { await sleep(reduce ? 0 : 1100); if (!alive(id)) return; kid("done", "done · ↳ Release lead"); await pulse("hub-k1", id, true); await pulse("lead-hub", id, true); } },
      { tool: "read_screen", call: "read_screen(\"Helper · tests\")", out: [["res", "Ran 3 tests in 0.000s"], ["ok", "OK"]],
        fx: async (id) => { await pulse("lead-hub", id); await pulse("hub-k1", id); flash("k1"); await pulse("hub-k1", id, true); await pulse("lead-hub", id, true); } },
    ];
    const kidAt = (i) => (i <= 3 ? ["off", "not started yet"] : i === 4 ? ["idle", "ready · ↳ Release lead"] : i === 5 ? ["working", "working · ↳ Release lead"] : ["done", "done · ↳ Release lead"]);
    const mark = (tool) => { tools.forEach((b) => b.classList.toggle("on", b.dataset.tool === tool)); hubCall.textContent = tool || "6 tools"; };
    const play = async (from, once = false) => {
      const id = ++run;
      draw();
      for (let i = from; alive(id); i++) {
        if (i >= STEPS.length) {
          if (once || reduce) { mark(""); return; }
          await sleep(4200);
          if (!alive(id)) return;
          i = 0; log.innerHTML = "";
        }
        while ((paused || !onScreen) && alive(id)) await sleep(250);
        if (!alive(id)) return;
        const s = STEPS[i];
        kid(...kidAt(i)); mark(s.tool);
        await type(s.call, id);
        if (!alive(id)) return;
        await s.fx(id);
        if (!alive(id)) return;
        s.out.forEach(([c, x]) => line(c, x));
        await sleep(reduce ? 0 : 1300);
      }
    };
    draw();
    window.addEventListener("resize", draw);
    window.addEventListener("load", draw);
    if (document.fonts && document.fonts.ready) document.fonts.ready.then(draw);
    kid("off", "not started yet");
    if (reduce) {   // no motion: the whole example, written out, and the map at its end
      onScreen = true;
      play(0, true);
    } else if ("IntersectionObserver" in window) {
      let started = false;
      new IntersectionObserver((es) => { onScreen = es.some((e) => e.isIntersecting); if (onScreen && !started) { started = true; play(0); } }, { threshold: 0.2 }).observe(stage);
    } else { onScreen = true; play(0); }
    tools.forEach((b) => b.addEventListener("click", () => {
      const i = STEPS.findIndex((s) => s.tool === b.dataset.tool);
      log.innerHTML = ""; paused = false; onScreen = true;
      pauseB.textContent = "❚❚"; pauseB.setAttribute("aria-pressed", "false");
      play(i);
    }));
    pauseB.addEventListener("click", () => {
      paused = !paused;
      pauseB.textContent = paused ? "▶" : "❚❚"; pauseB.setAttribute("aria-pressed", String(paused));
      pauseB.setAttribute("aria-label", paused ? "Play the example" : "Pause the example");
    });
  }

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
