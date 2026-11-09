// The hero's live control room: a faithful, scripted reconstruction of Agent Manager at work (its colours, labels and
// the agents' real recorded screens). No dependency, no network. Loops about every 26 seconds; pauses off screen, on
// the pause button, and stays still for people who prefer reduced motion.
(() => {
  const root = document.querySelector(".live");
  if (!root) return;
  const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const $ = (sel) => root.querySelector(sel);
  const side = $(".lv-side"), queue = $(".lv-queue"), tree = $(".lv-tree"), term = $(".lv-term");
  const head = $(".lv-head"), toastBox = $(".lv-toasts"), cursor = $(".lv-cursor"), pauseBtn = document.querySelector(".live-pause");

  const TOOLS = { claude: ["✻", "Claude Code"], codex: ["◎", "Codex"], shell: ["❯", "Shell"] };
  const STATE = {
    working: ["working", "working"], ok: ["ok", "waits for your OK"], asks: ["asks", "waits for an answer"],
    done: ["done", "done"], ready: ["idle", "ready"],
  };
  const GROUPS = [["acme", "Acme Store"], ["orbit", "Orbit API"], ["pixel", "Pixel Forge"]];
  const esc = (s) => s.replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]));

  // Terminal screens, from the recorded sessions (tools/showcase/scenes). [class, text] per line.
  const SCREENS = {
    checkout: [
      ["prompt", "❯ Add a gift card to the checkout: redeemGiftCard(total, card) that never takes more than the balance, plus tests."],
      ["", ""],
      ["tool", "● Read(src/checkout/cart.ts)"],
      ["dim", "  ⎿  Read 48 lines"],
      ["tool", "● Write(src/checkout/giftcard.ts)"],
      ["dim", "  ⎿  Wrote 35 lines to src/checkout/giftcard.ts"],
      ["code", "      1 <kw>export interface</kw> <ty>GiftCard</ty> {"],
      ["code", "      2   code: <ty>string</ty>;"],
      ["code", "      3   balance: <ty>number</ty>;"],
      ["code", "      4 }"],
      ["tool", "● Write(tests/giftcard.test.ts)"],
      ["dim", "  ⎿  Wrote 74 lines to tests/giftcard.test.ts"],
      ["code", "      5 <fn>test</fn>(<st>\"card smaller than total: takes the whole balance\"</st>, () => {"],
      ["code", "      6   <kw>const</kw> r = <fn>redeemGiftCard</fn>(<nu>80</nu>, <fn>card</fn>(<nu>50</nu>));"],
      ["code", "      7   <fn>expect</fn>(r.applied).<fn>toBe</fn>(<nu>50</nu>);"],
    ],
    checkoutDone: [
      ["", ""],
      ["text", "● Gift cards are redeemed at checkout, never for more than their balance. 3 files"],
      ["text", "  changed, 6 tests. I read and wrote files only, as asked."],
      ["", ""],
      ["spin done", "✻ Cooked for 41s · done"],
    ],
    limiter: [
      ["dim", "  with your question tool: should the limit be per API key or per IP address?"],
      ["rule", ""],
      ["tabs", "←  <b>☐ Client key</b>  ☐ Over limit  ✔ Submit  →"],
      ["", ""],
      ["q", "│ For the per-client rate limits in orbit/limits.py, how should a \"client\" be identified?"],
      ["", ""],
      ["opt sel", "❯ 1. Per API key"],
      ["dim", "     Each API key gets its own bucket. Fair to shared-IP users, needs auth."],
      ["opt", "  2. Per IP address"],
      ["dim", "     Bucket by client IP. Users behind NAT share a limit."],
      ["opt", "  3. API key, IP fallback"],
      ["dim", "     Use the API key when present, otherwise the client IP."],
      ["opt", "  4. Type something."],
    ],
    limiterGo: [
      ["prompt", "❯ 3. API key, IP fallback"],
      ["", ""],
      ["tool", "● Update(orbit/limits.py)"],
      ["dim", "  ⎿  Added 14 lines, removed 3 lines"],
      ["code", "     21 <kw>def</kw> <fn>client_id</fn>(request):"],
      ["code", "     22     <kw>return</kw> request.api_key <kw>or</kw> request.remote_addr"],
    ],
  };

  let sessions, selected, timers = [], running = false, cycle = 0;
  const reset = () => {
    sessions = [
      { id: "checkout", name: "Checkout flow", tool: "claude", g: "acme", state: "working", where: "acme-store", brain: true },
      { id: "flaky", name: "Flaky tests", tool: "claude", g: "acme", state: "working", where: "acme-store", brain: true },
      { id: "docs", name: "Docs refresh", tool: "codex", g: "acme", state: "done", where: "acme-store", brain: true, quote: "Updated README.md: cart, Quebec sales tax…" },
      { id: "limiter", name: "Rate limiter", tool: "claude", g: "orbit", state: "working", where: "orbit-api", brain: true },
      { id: "lead", name: "Release lead", tool: "claude", g: "orbit", state: "working", where: "orbit-api", brain: true },
      { id: "sparks", name: "Sparks", tool: "claude", g: "pixel", state: "working", where: "pixel-forge", brain: true },
    ];
    selected = "checkout";
  };
  const S = (id) => sessions.find((s) => s.id === id);

  // ------------------------------------------------------------------ drawing
  const card = (s) => {
    const [cls, label] = STATE[s.state];
    const [icon, tool] = TOOLS[s.tool];
    return `<div class="lv-card st-${cls}${s.id === selected ? " sel" : ""}${s.fresh ? " fresh" : ""}" data-id="${s.id}">
      <span class="lv-icon t-${s.tool}">${icon}</span>
      <span class="lv-body"><b>${esc(s.name)}${s.brain ? ` <em>✦</em>` : ""}</b><i class="lv-state">${s.parent ? "↳ " + esc(S(s.parent).name) + " · " : tool + " · "}${label}</i></span>
      <span class="lv-dot"></span></div>`;
  };
  const drawSide = () => {
    const waiting = sessions.filter((s) => s.state === "ok" || s.state === "asks");
    queue.innerHTML = waiting.length ? `<p class="lv-over warn">They wait for you <span>${waiting.length}</span></p>` + waiting.map((s) => `
      <div class="lv-wait st-${STATE[s.state][0]}" data-id="${s.id}"><b>${esc(s.name)} · ${STATE[s.state][1]}</b>
        <i>${s.state === "ok" ? "Claude needs your permission to use Bash" : "Claude is waiting for your input"}</i>
        <span class="lv-btns">${s.state === "ok" ? `<button class="lv-approve" tabindex="-1">Approve</button><button tabindex="-1">Refuse</button>` : `<button class="lv-reply" tabindex="-1">Reply…</button>`}<button class="lv-open" tabindex="-1">Open</button></span></div>`).join("") : "";
    tree.innerHTML = GROUPS.map(([g, name]) => {
      const list = sessions.filter((s) => s.g === g);
      const w = list.filter((s) => s.state === "ok" || s.state === "asks").length;
      return `<p class="lv-over">▾ ${name} <span>${list.length}${w ? " · " + w + " waiting" : ""}</span></p>` + list.map(card).join("");
    }).join("");
    sessions.forEach((s) => { s.fresh = false; });
  };
  const drawHead = () => {
    const s = S(selected);
    const [cls, label] = STATE[s.state];
    head.innerHTML = `<span class="lv-title"><b>${esc(s.name)}</b><small>${TOOLS[s.tool][1]} · ~/code/${s.where} · ⎇ main · ✦ shares the Second Brain</small></span>
      <span class="lv-pill st-${cls}"><span class="lv-dot"></span>${label}</span>`;
  };
  const line = ([cls, text]) => {
    const html = esc(text).replace(/&lt;(\/?)(kw|ty|fn|st|nu|b)&gt;/g, "<$1$2>");
    return `<div class="ln ${cls}">${html || "&nbsp;"}</div>`;
  };
  let spinT = 0, spinWord = "Boondoggling";
  const setScreen = (lines, spin) => {
    term.innerHTML = lines.map(line).join("") + (spin ? `<div class="ln spin">✻ ${spinWord}… (<span class="sec">${spinT}</span>s · thinking)</div>` : "") +
      `<div class="ln rule"></div><div class="ln in">❯ <span class="caret"></span></div><div class="ln rule"></div><div class="ln foot">⏵⏵ auto mode on · ← 2 agents</div>`;
  };
  const typeScreen = async (lines, spin, delay = 140) => {
    for (let i = 1; i <= lines.length; i++) { setScreen(lines.slice(0, i), spin && i === lines.length); await wait(delay); }
  };

  // ------------------------------------------------------------------ motion helpers
  const wait = (ms) => new Promise((ok) => { const t = setTimeout(ok, ms); timers.push(t); });
  const toast = (text, kind = "") => {
    const el = document.createElement("div");
    el.className = "lv-toast " + kind;
    el.textContent = text;
    toastBox.appendChild(el);
    while (toastBox.children.length > 2) toastBox.firstElementChild.remove();
    const t = setTimeout(() => el.classList.add("out"), 2600);
    const u = setTimeout(() => el.remove(), 3100);
    timers.push(t, u);
  };
  const pos = (el) => { // position inside the frame, without transforms
    let x = 0, y = 0, e = el;
    while (e && e !== root) { x += e.offsetLeft; y += e.offsetTop; e = e.offsetParent; }
    return { x: x + el.offsetWidth * 0.55, y: y + el.offsetHeight * 0.6 };
  };
  const moveTo = async (sel) => {
    const el = root.querySelector(sel);
    if (!el) return null;
    const p = pos(el);
    cursor.classList.add("on");
    cursor.style.transform = `translate(${p.x}px, ${p.y}px)`;
    await wait(750);
    return el;
  };
  const click = async (el) => {
    if (!el) return;
    cursor.classList.add("click"); el.classList.add("pressed");
    await wait(220);
    cursor.classList.remove("click"); el.classList.remove("pressed");
  };
  const set = (id, state, quote) => { const s = S(id); s.state = state; s.quote = quote; drawSide(); if (id === selected) drawHead(); };
  const select = (id) => { selected = id; drawSide(); drawHead(); };

  // ------------------------------------------------------------------ the script
  const spinTick = setInterval(() => { if (!running) return; spinT++; const el = term.querySelector(".sec"); if (el) el.textContent = spinT; }, 1000);
  const play = async (my) => {
    const alive = () => running && my === cycle;
    reset(); spinT = 4; spinWord = "Boondoggling";
    cursor.classList.remove("on"); cursor.style.transform = `translate(${root.offsetWidth * 0.6}px, ${root.offsetHeight * 0.85}px)`;
    drawSide(); drawHead();
    await typeScreen(SCREENS.checkout, true, 170); if (!alive()) return;
    await wait(500);
    set("flaky", "ok", "Claude needs your permission to use Bash"); toast("Flaky tests waits for your OK", "ok");
    await wait(1700); if (!alive()) return;
    if (S("flaky").state === "ok") { await click(await moveTo(".lv-wait[data-id=flaky] .lv-approve")); if (!alive()) return; set("flaky", "working"); toast("Approved · Flaky tests carries on"); }
    await wait(1300); if (!alive()) return;
    set("limiter", "asks", "Claude is waiting for your input"); toast("Rate limiter asks you a question", "asks");
    await wait(1500); if (!alive()) return;
    if (S("limiter").state === "asks") await click(await moveTo(".lv-wait[data-id=limiter] .lv-open"));
    if (!alive()) return;
    const lim = SCREENS.limiter.map((l) => [...l]);
    select("limiter"); setScreen(lim, false);
    await wait(900);
    for (const n of [2, 3]) { // the arrow keys, then Enter
      lim.forEach((l) => { if (l[0].startsWith("opt")) { l[0] = "opt"; l[1] = " " + l[1].slice(1); } });
      const idx = lim.findIndex((l) => l[1].includes(` ${n}. `));
      lim[idx] = ["opt sel", "❯" + lim[idx][1].slice(1)];
      setScreen(lim, false); await wait(450);
    }
    if (!alive()) return;
    set("limiter", "working"); spinT = 1; spinWord = "Thinking";
    await typeScreen(SCREENS.limiterGo, true, 160); if (!alive()) return;
    set("sparks", "done", "Sparks are faster on a critical hit"); toast("Sparks is done · 3 files changed", "done");
    await wait(1500); if (!alive()) return;
    sessions.splice(sessions.indexOf(S("lead")) + 1, 0,
      { id: "h1", name: "Helper · tests", tool: "shell", g: "orbit", state: "ready", where: "orbit-api", parent: "lead", fresh: true },
      { id: "h2", name: "Helper · changelog", tool: "shell", g: "orbit", state: "ready", where: "orbit-api", parent: "lead", fresh: true });
    drawSide(); toast("Release lead started 2 helpers through MCP");
    await wait(1800); if (!alive()) return;
    await click(await moveTo(".lv-card[data-id=checkout]")); if (!alive()) return;
    select("checkout");
    set("checkout", "done", "Gift cards are redeemed at checkout…");
    setScreen(SCREENS.checkout.slice(4).concat(SCREENS.checkoutDone), false);
    toast("Checkout flow is done", "done");
    await wait(1300); if (!alive()) return;
    toast("✦ Session journal proposed to the Second Brain", "brain");
    await wait(3600); if (!alive()) return;
    root.classList.add("fade"); await wait(450); root.classList.remove("fade");
    if (alive()) play(my);
  };

  // The visitor can approve or open too
  side.addEventListener("click", (e) => {
    const w = e.target.closest(".lv-wait");
    if (w && e.target.closest(".lv-approve")) { set(w.dataset.id, "working"); toast("Approved · " + S(w.dataset.id).name + " carries on"); }
    const c = e.target.closest(".lv-card");
    if (c && !running) select(c.dataset.id);
  });

  const start = () => { if (running) return; running = true; cycle++; root.classList.remove("paused"); play(cycle); updateBtn(); };
  const stop = () => { running = false; timers.forEach(clearTimeout); timers = []; root.classList.add("paused"); updateBtn(); };
  const updateBtn = () => { if (pauseBtn) { pauseBtn.textContent = running ? "❚❚ Pause" : "▶ Play"; pauseBtn.setAttribute("aria-pressed", String(!running)); } };

  // A still picture for reduced motion: several states at once, nothing moves
  const still = () => {
    reset(); spinT = 31;
    S("flaky").state = "ok"; S("limiter").state = "asks"; S("sparks").state = "done";
    drawSide(); drawHead(); setScreen(SCREENS.checkout, true); updateBtn();
  };

  let userPaused = false, inView = false;
  if (pauseBtn) pauseBtn.addEventListener("click", () => { if (running) { userPaused = true; stop(); } else { userPaused = false; start(); } });
  if (reduce) { still(); return; }
  if ("IntersectionObserver" in window) {
    new IntersectionObserver((es) => { for (const e of es) { inView = e.isIntersecting; if (inView && !userPaused) start(); else if (!inView && running) stop(); } }, { threshold: 0.2 }).observe(root);
    const r = root.getBoundingClientRect();
    if (r.top < innerHeight && r.bottom > 0) { inView = true; start(); }  // in view at load: start without waiting
  } else { inView = true; start(); }
  document.addEventListener("visibilitychange", () => {
    if (document.hidden && running) stop(); else if (!document.hidden && inView && !userPaused) start();
  });
  void spinTick;
})();
