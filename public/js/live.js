// The hero's live control room: a faithful, scripted reconstruction of Agent Manager at work (its colours, labels and
// the agents' real recorded screens). No dependency, no network. Loops about every 36 seconds; pauses off screen, on
// the pause button. With reduced motion it still plays, without anything sliding or fading.
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
      ["tool", "● Bash(npm test -- giftcard)"],
      ["good", "  ⎿  ✓ tests/giftcard.test.ts (6 tests) 14ms"],
      ["dim", "     Tests  <b class=\"ok\">6 passed</b> (6)"],
      ["", ""],
      ["text", "● Gift cards work at checkout, never above their balance."],
      ["text", "  3 files changed, 6 tests. Files only, as asked."],
      ["", ""],
      ["spin done", "✻ Cooked for 41s"],
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
      ["dim", "  ⎿  Updated orbit/limits.py with 3 additions and 1 removal"],
      ["code", "       20   <kw>def</kw> <fn>client_id</fn>(request):"],
      ["del", "       21 -     <kw>return</kw> request.remote_addr"],
      ["add", "       21 +     <kw>if</kw> request.api_key:"],
      ["add", "       22 +         <kw>return</kw> <st>\"key:\"</st> + request.api_key"],
      ["add", "       23 +     <kw>return</kw> <st>\"ip:\"</st> + request.remote_addr"],
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
    const html = esc(text).replace(/&lt;(\/?)(kw|ty|fn|st|nu|b)&gt;/g, "<$1$2>").replace(/&lt;b class="(\w+)"&gt;/g, '<b class="$1">');
    return `<div class="ln ${cls}">${html || "&nbsp;"}</div>`;
  };
  let spinT = 0, spinTok = 0, spinWord = "Boondoggling", welcome = false;
  const GLYPHS = ["·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢"];
  const tokens = () => (spinTok < 1000 ? spinTok : (spinTok / 1000).toFixed(1) + "k");
  const spinLine = () => `<div class="ln spin"><span class="g">${GLYPHS[0]}</span> <span class="verb">${spinWord}…</span> <span class="meta">(<span class="sec">${spinT}</span>s · ↓ <span class="tok">${tokens()}</span> tokens · esc to interrupt)</span></div>`;
  const banner = () => `<div class="lv-welcome"><b><i>✻</i> Welcome to Claude Code</b><span>/help for help, /status for your current setup</span><span class="cwd">cwd: /home/dev/code/${esc(S(selected).where)}</span></div>`;
  const setScreen = (lines, spin, input = "") => {
    term.innerHTML = (welcome ? banner() : "") + lines.map(line).join("") + (spin ? spinLine() : "") +
      `<div class="ln rule"></div><div class="ln in">❯ <span class="typed">${esc(input)}</span><span class="caret"></span></div><div class="ln rule"></div><div class="ln foot"><span>⏵⏵ auto mode on · ← 2 agents</span><span class="ctx">✦ Second Brain</span></div>`;
  };
  const streamLast = async (lines, cps = 160) => { // the agent's answer arrives a few characters at a time
    const last = lines[lines.length - 1], full = last[1];
    for (let i = 0; i <= full.length; i += 3) { setScreen(lines.slice(0, -1).concat([[last[0], full.slice(0, i)]]), true); await wait(3000 / cps); }
  };
  const typeInput = async (lines, text, cps = 38) => { // someone typing at the prompt
    for (let i = 1; i <= text.length; i++) { setScreen(lines, false, text.slice(0, i)); await wait(1000 / cps * (text[i - 1] === " " ? 1.6 : 1)); }
  };
  const typeScreen = async (lines, spin, delay = 140, from = 1) => { // lines before `from` are already on screen
    for (let i = from; i <= lines.length; i++) {
      if (lines[i - 1][0] === "text") await streamLast(lines.slice(0, i)); else setScreen(lines.slice(0, i), spin && i === lines.length);
      await wait(delay);
    }
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
  let frame = 0;
  const spinTick = setInterval(() => {
    if (!running) return;
    frame++;
    if (frame % 8 === 0) spinT++;
    spinTok += 9 + Math.floor(Math.random() * 30);
    const g = term.querySelector(".spin .g");
    if (!g) return;
    g.textContent = GLYPHS[frame % GLYPHS.length];
    term.querySelector(".sec").textContent = spinT;
    term.querySelector(".tok").textContent = tokens();
  }, 125);
  // Grid view: four live tiles
  const main = $(".lv-main"), grid = $(".lv-grid"), views = $(".lv-views"), voice = $(".lv-voice");
  const TILES = {
    checkout: ["  PASS  tests/giftcard.test.ts", "    ✓ takes no more than the balance", "    ✓ card smaller than total", "    ✓ zero balance is refused", "    ✓ remaining total is right", "  Tests: 6 passed", "● Update(README.md)", "  ⎿  Added 2 lines"],
    flaky: ["● Bash(npm test -- --repeat 20 cart)", "  run 1/20 ✓", "  run 2/20 ✓", "  run 3/20 ✗ timeout 5000 ms", "● The clock is real in cart.test.ts:", "  fake timers would fix it", "● Update(tests/cart.test.ts)", "  ⎿  vi.useFakeTimers()"],
    limiter: ["● Update(orbit/limits.py)", "     21 def client_id(request):", "     22   return request.api_key or ip", "● Write(tests/test_limits.py)", "  ⎿  Wrote 31 lines", "● Bash(python3 -m unittest)", "  Ran 5 tests in 0.004s", "  OK"],
    sparks: ["● Sparks are 2× faster on a critical hit", "  and come back to normal after.", "  - burst(true) on a crit", "  - speed_scale, not velocity", "", "✻ Cooked for 19s · done", "", "❯ commit this"],
  };
  const drawGrid = () => {
    grid.innerHTML = ["checkout", "flaky", "limiter", "sparks"].map((id) => {
      const x = S(id), [cls, label] = STATE[x.state];
      return `<div class="lv-tile st-${cls}" data-id="${id}"><p><span class="lv-dot"></span>${esc(x.name)} · ${label}</p><div class="lv-tb"></div></div>`;
    }).join("");
  };
  const tileLine = (id, text) => {
    const tb = grid.querySelector(`[data-id=${id}] .lv-tb`);
    if (!tb) return;
    const d = document.createElement("div");
    d.className = "ln" + (text.startsWith("●") ? " tool" : text.includes("✗") ? " bad" : text.includes("✓") || text.includes("OK") || text.includes("passed") ? " good" : text.startsWith("✻") ? " spin done" : "");
    d.textContent = text || " ";
    tb.appendChild(d);
    while (tb.children.length > 9) tb.firstElementChild.remove();
  };
  const setView = (v) => {
    main.classList.toggle("grid", v === "grid");
    views.querySelectorAll("span").forEach((e) => e.classList.toggle("on", e.dataset.v === v));
    if (v === "grid") drawGrid();
  };
  const setTileState = (id) => {
    const t = grid.querySelector(`[data-id=${id}]`);
    if (!t) return;
    const [cls, label] = STATE[S(id).state];
    t.className = "lv-tile st-" + cls;
    t.querySelector("p").innerHTML = `<span class="lv-dot"></span>${esc(S(id).name)} · ${label}`;
  };

  const play = async (my) => {
    const alive = () => running && my === cycle;
    reset(); spinT = 0; spinTok = 0; spinWord = "Boondoggling"; welcome = true;
    setView("focus"); voice.classList.remove("on");
    cursor.classList.remove("on"); cursor.style.transform = `translate(${root.offsetWidth * 0.6}px, ${root.offsetHeight * 0.85}px)`;
    S("checkout").state = "ready"; drawSide(); drawHead();
    // 1. you ask Claude Code for something
    setScreen([], false); await wait(600);
    await typeInput([], "Add a gift card to the checkout, plus tests"); if (!alive()) return;
    await wait(350);
    set("checkout", "working"); welcome = false;
    const chk = SCREENS.checkout.slice(2);
    setScreen([["prompt", "❯ Add a gift card to the checkout, plus tests"]], true);
    await wait(500);
    for (let i = 1; i <= chk.length; i++) { setScreen([["prompt", "❯ Add a gift card to the checkout, plus tests"], ["", ""]].concat(chk.slice(0, i)), true); await wait(150); }
    if (!alive()) return;
    // 2. one waits for your OK: approved from the list
    set("flaky", "ok"); toast("Flaky tests waits for your OK", "ok");
    await wait(1500); if (!alive()) return;
    if (S("flaky").state === "ok") { await click(await moveTo(".lv-wait[data-id=flaky] .lv-approve")); if (!alive()) return; set("flaky", "working"); toast("Approved · Flaky tests carries on"); }
    await wait(1000); if (!alive()) return;
    // 3. one asks a question: open it, pick an answer
    set("limiter", "asks"); toast("Rate limiter asks you a question", "asks");
    await wait(1300); if (!alive()) return;
    if (S("limiter").state === "asks") await click(await moveTo(".lv-wait[data-id=limiter] .lv-open"));
    if (!alive()) return;
    const lim = SCREENS.limiter.map((l) => [...l]);
    select("limiter"); setScreen(lim, false);
    await wait(900);
    for (const n of [2, 3]) { // the arrow keys, then Enter
      lim.forEach((l) => { if (l[0].startsWith("opt")) { l[0] = "opt"; l[1] = " " + l[1].slice(1); } });
      const idx = lim.findIndex((l) => l[1].includes(` ${n}. `));
      lim[idx] = ["opt sel", "❯" + lim[idx][1].slice(1)];
      setScreen(lim, false); await wait(480);
    }
    if (!alive()) return;
    set("limiter", "working"); spinT = 1; spinTok = 0; spinWord = "Thinking";
    await typeScreen(SCREENS.limiterGo, true, 150); if (!alive()) return;
    await wait(500);
    // 4. Grid view: everyone at once
    await click(await moveTo(".lv-views [data-v=grid]")); if (!alive()) return;
    setView("grid");
    const feed = { checkout: 0, flaky: 0, limiter: 0, sparks: 0 };
    const pump = (id) => { if (feed[id] < TILES[id].length) tileLine(id, TILES[id][feed[id]++]); };
    for (const id of ["checkout", "flaky", "limiter", "sparks"]) for (let k = 0; k < 3; k++) pump(id);
    for (let step = 0; step < 14; step++) {
      await wait(380); if (!alive()) return;
      pump(["checkout", "flaky", "limiter"][step % 3]);
      if (step === 2) { set("sparks", "done"); setTileState("sparks"); for (let k = 0; k < 5; k++) pump("sparks"); toast("Sparks is done · 3 files changed", "done"); }
      if (step === 7) {
        sessions.splice(sessions.indexOf(S("lead")) + 1, 0,
          { id: "h1", name: "Helper · tests", tool: "shell", g: "orbit", state: "ready", where: "orbit-api", parent: "lead", fresh: true },
          { id: "h2", name: "Helper · changelog", tool: "shell", g: "orbit", state: "ready", where: "orbit-api", parent: "lead", fresh: true });
        drawSide(); toast("Release lead started 2 helpers through MCP");
      }
      if (step === 11) { set("checkout", "done"); setTileState("checkout"); toast("Checkout flow is done", "done"); }
    }
    await wait(700); if (!alive()) return;
    // 5. back to Focus, and you just say what to do (F8)
    await click(await moveTo(".lv-card[data-id=checkout]")); if (!alive()) return;
    setView("focus"); select("checkout");
    const done = SCREENS.checkout.slice(10).concat(SCREENS.checkoutDone);
    setScreen(done, false);
    await wait(900); if (!alive()) return;
    voice.classList.add("on");
    const said = voice.querySelector(".said"), bars = [...voice.querySelectorAll(".lv-meter i")];
    said.textContent = "";
    const words = "commit this and push the branch".split(" ");
    for (let k = 0; k < words.length * 3; k++) {
      bars.forEach((b) => { b.style.height = (18 + Math.random() * 82) + "%"; });
      if (k % 3 === 2) said.textContent += (said.textContent ? " " : "") + words[(k - 2) / 3];
      await wait(150); if (!alive()) return;
    }
    await wait(400);
    voice.classList.remove("on");
    await typeInput(done, "commit this and push the branch", 60); if (!alive()) return;
    await wait(250);
    set("checkout", "working"); spinT = 1; spinTok = 0; spinWord = "Committing";
    const git = done.slice(-9).concat([["prompt", "❯ commit this and push the branch"], ["", ""], ["tool", "● Bash(git commit -am \"Gift cards at checkout\")"], ["dim", "  ⎿  [main 4f2a91c] Gift cards at checkout · 3 files changed"], ["tool", "● Bash(git push)"], ["dim", "  ⎿  main -> main (with this repository's own deploy key)"]]);
    await typeScreen(git, true, 260, 10); if (!alive()) return;
    set("checkout", "done"); setScreen(git.concat([["spin done", "✻ Done in 6s"]]), false);
    await wait(500);
    toast("✦ Session journal proposed to the Second Brain", "brain");
    await wait(3400); if (!alive()) return;
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

  let userPaused = false, inView = false;
  if (pauseBtn) pauseBtn.addEventListener("click", () => { if (running) { userPaused = true; stop(); } else { userPaused = false; start(); } });
  if (reduce) root.classList.add("calm");  // still plays: states and text change, nothing slides or fades
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
