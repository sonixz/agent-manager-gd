#!/usr/bin/env python3
"""Cuts the filmed steps into the showcase video, then adds titles, narration, music and sound effects.

Input:  video-production/captures/<step>/frameNNNNNNNN.png (tools/showcase.sh with SHOW_MOVIE, 1920x1080, 30 fps)
        build/showcase/report-<step>.txt  (« mark <name> <frame> [x y w h] » lines written by the film-* steps)
        video-production/work/audio/*.mp3 (scripts/make_audio.sh) and work/logo-360.png (scripts/logo_png.gd)
Output: video-production/output/agent-manager-showcase.mp4 (master) and the web encode + poster (scripts/render.sh).

Every shot is a piece of a real film step: no picture is drawn here except the titles and the closing card.
The camera moves (zoom towards a detail) are computed on a 4x enlarged frame so they glide without wobbling."""
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
VP = os.path.dirname(HERE)
REPO = os.path.dirname(VP)
CAP = os.path.join(VP, "captures")
WORK = os.path.join(VP, "work")
OUT = os.path.join(VP, "output")
FFMPEG = os.environ.get("FFMPEG", os.path.expanduser("~/.local/opt/ffmpeg-n8.1.3-35/bin/ffmpeg"))
FONT = os.path.join(REPO, "app/assets/fonts/JetBrainsMonoNL-Regular.ttf")
FPS = 30
W, H = 1920, 1080

# ---------------------------------------------------------------- the marks the film steps left


def marks(step: str) -> dict:
    out = {}
    for line in open(os.path.join(REPO, "build/showcase", f"report-{step}.txt"), encoding="utf-8"):
        m = re.match(r"mark (\S+) (\d+)(?: (-?\d+) (-?\d+) (\d+) (\d+))?", line.strip())
        if m:
            out[m.group(1)] = {"frame": int(m.group(2)), "rect": [int(x) for x in m.groups()[2:]] if m.group(3) else None}
    return out


def first_frame(step: str) -> int:
    names = sorted(f for f in os.listdir(os.path.join(CAP, step)) if f.startswith("frame") and f.endswith(".png"))
    return int(names[0][5:13])


# ---------------------------------------------------------------- one shot


def shot(name: str, step: str, start: int, seconds: float, zoom_to=None, zoom=1.0, ease_in=0.0) -> str:
    """A piece of a step: `seconds` from frame `start`. With zoom_to (x y w h on the 1920x1080 screen), the camera
    glides from the whole screen towards that rectangle's centre, up to `zoom`, after `ease_in` seconds."""
    n = int(round(seconds * FPS))
    out = os.path.join(WORK, f"shot-{name}.mp4")
    src = os.path.join(CAP, step, "frame%08d.png")
    if zoom_to and zoom > 1.0:
        x, y, w, h = zoom_to
        cx, cy = x + w / 2, y + h / 2
        k = 4  # enlarged 4x: every move lands on a quarter pixel
        d0, d1 = int(ease_in * FPS), n
        # eased progress 0..1 (smoothstep) from frame d0 to the end
        p = f"(clip((on-{d0})/{max(1, d1 - d0)},0,1))"
        e = f"({p}*{p}*(3-2*{p}))"
        z = f"(1+({zoom}-1)*{e})"
        # the visible window's top-left, kept inside the picture
        vx = f"clip({cx * k}-iw/{z}/2,0,iw-iw/{z})"
        vy = f"clip({cy * k}-ih/{z}/2,0,ih-ih/{z})"
        vf = (f"scale={W * k}:{H * k}:flags=neighbor,"
              f"zoompan=z='{z}':x='{vx}':y='{vy}':d=1:s={W}x{H}:fps={FPS},format=yuv420p")
    else:
        vf = "format=yuv420p"
    subprocess.run([FFMPEG, "-hide_banner", "-loglevel", "error", "-y", "-framerate", str(FPS), "-start_number", str(start), "-i", src,
                    "-frames:v", str(n), "-vf", vf, "-c:v", "libx264", "-crf", "10", "-preset", "fast", out], check=True)
    return out


def card(seconds: float) -> str:
    """The closing card: the project's logo and words on the site's dark ground (drawn, not filmed)."""
    out = os.path.join(WORK, "shot-card.mp4")
    logo = os.path.join(VP, "assets", "branding", "logo-360.png")
    t0 = 0.55  # the logo lands on the music's impact, set in the mix
    vf = (f"[1:v]format=rgba,fade=t=in:st={t0}:d=0.45:alpha=1[logo];"
          f"[0:v][logo]overlay=x='(W-w)/2':y='200-(1-min(1,max(0,(t-{t0})/0.45)))*30':format=auto,"
          f"format=yuv420p[v]")
    subprocess.run([FFMPEG, "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", f"color=c=0x101a26:s={W}x{H}:r={FPS}:d={seconds}",
                    "-loop", "1", "-framerate", str(FPS), "-t", str(seconds), "-i", logo,
                    "-filter_complex", vf, "-map", "[v]", "-frames:v", str(int(seconds * FPS)), "-c:v", "libx264", "-crf", "10", "-preset", "fast", out], check=True)
    return out


# ---------------------------------------------------------------- titles


def esc(s: str) -> str:
    return s.replace("\\", "\\\\").replace(":", "\\:").replace("'", "’").replace("%", "\\%")


def title(text: str, t0: float, t1: float, y: str, size: int, colour: str = "white", box: bool = True, fade: float = 0.3) -> str:
    a = f"if(lt(t,{t0}+{fade}),(t-{t0})/{fade},if(gt(t,{t1}-{fade}),({t1}-t)/{fade},1))"
    b = ":box=1:boxcolor=0x0b121c@0.80:boxborderw=18|30" if box else ""
    return (f"drawtext=fontfile='{FONT}':text='{esc(text)}':fontsize={size}:fontcolor={colour}:x=(w-tw)/2:y={y}"
            f":alpha='{a}':enable='between(t,{t0},{t1})'{b}")


# ---------------------------------------------------------------- the edit


def main() -> None:
    os.makedirs(WORK, exist_ok=True)
    os.makedirs(OUT, exist_ok=True)
    m = {s: marks(s) for s in ("film-control", "film-wsl", "film-repos", "film-sandbox", "film-tunnel")}
    json.dump(m, open(os.path.join(WORK, "marks.json"), "w"), indent=1)
    off = {s: first_frame(s) for s in m}  # the movie's first frame number on disk (the marks count from the engine's start)
    f = lambda s, k, plus=0.0: m[s][k]["frame"] - m[s]["__base"]["frame"] + off[s] + int(plus * FPS) if "__base" in m[s] else m[s][k]["frame"] + int(plus * FPS)
    rect = lambda s, k: m[s][k]["rect"]
    pad = lambda r, px: [r[0] - px, r[1] - px, r[2] + 2 * px, r[3] + 2 * px]

    # (name, file, seconds) in order; each cut lands on a beat (120 BPM: 0.5 s)
    plan = [
        ("intro", shot("intro", "film-control", f("film-control", "grid", 0.4), 4.0, zoom_to=[310, 40, 1600, 1000], zoom=1.06, ease_in=0.0), 4.0),
        ("board", shot("board", "film-control", f("film-control", "board", 0.3), 2.0), 2.0),
        ("wsl", shot("wsl", "film-wsl", f("film-wsl", "page", 0.6), 3.0, zoom_to=pad(rect("film-wsl", "chart"), 40), zoom=1.35, ease_in=0.3), 3.0),
        ("repos", shot("repos", "film-repos", f("film-repos", "list", 0.2), 2.5), 2.5),
        ("metro", shot("metro", "film-repos", f("film-repos", "unfolded", 0.2), 3.5, zoom_to=pad(rect("film-repos", "unfolded"), 30), zoom=1.3, ease_in=0.2), 3.5),
        ("sbx", shot("sbx", "film-sandbox", f("film-sandbox", "page", 0.3), 2.0), 2.0),
        ("sizes", shot("sizes", "film-sandbox", f("film-sandbox", "sizes", -0.2), 4.0, zoom_to=pad(rect("film-sandbox", "sizes"), 60), zoom=1.45, ease_in=0.2), 4.0),
        ("health", shot("health", "film-tunnel", f("film-tunnel", "health", 0.0), 2.0, zoom_to=pad(rect("film-tunnel", "health"), 40), zoom=1.25, ease_in=0.0), 2.0),
        ("wire", shot("wire", "film-tunnel", f("film-tunnel", "socks", 0.3), 3.5, zoom_to=pad(rect("film-tunnel", "wire" if "wire" in m["film-tunnel"] else "socks"), 40), zoom=1.5, ease_in=0.0), 3.5),
        ("card", card(6.0), 6.0),
    ]
    # joined with short crossfades (0.25 s) that keep the total: each one eats into both sides
    X = 0.25
    inputs, chain, t = [], "", 0.0
    for i, (_, path, sec) in enumerate(plan):
        inputs += ["-i", path]
    label = "[0:v]"
    for i in range(1, len(plan)):
        t += plan[i - 1][2] - (X if i > 1 else X)
        nxt = f"[x{i}]"
        chain += f"{label}[{i}:v]xfade=transition=fade:duration={X}:offset={t:.3f}{nxt};"
        label = nxt
    total = sum(p[2] for p in plan) - X * (len(plan) - 1)
    starts, acc = [], 0.0
    for i, p in enumerate(plan):
        starts.append(acc)
        acc += p[2] - X
    st = dict(zip([p[0] for p in plan], starts))

    t_card = st["card"]
    titles = [
        title("EVERY AGENT. ONE CONTROL ROOM.", 0.8, st["board"] - 0.1, "h-210", 54),
        title("SESSIONS & WSL", st["board"] + 0.2, st["repos"] - 0.1, "h-200", 50),
        title("REPOSITORIES & GIT", st["repos"] + 0.2, st["sbx"] - 0.1, "h-200", 50),
        title("CLOUD SANDBOXES", st["sbx"] + 0.2, st["health"] - 0.1, "h-210", 50),
        title("ISOLATED. SCALABLE. COST-AWARE.", st["sbx"] + 0.7, st["health"] - 0.1, "h-112", 28, colour="0x8fe3ef", box=True),
        title("CLOUD POWER. LOCAL CONTROL.", st["health"] + 0.2, t_card - 0.05, "h-210", 50),
        title("CLOUD SANDBOX  ↔  SSH TUNNEL · SOCKS  ↔  YOUR LOCALHOST", st["wire"] + 0.3, t_card - 0.05, "h-112", 28, colour="0x8fe3ef", box=True),
        title("AGENT MANAGER GD", t_card + 0.9, total, "600", 84, box=False, fade=0.4),
        title("BUILT FOR AI BUILDERS.", t_card + 1.3, total, "715", 48, colour="0x8fe3ef", box=False, fade=0.4),
        title("OPEN SOURCE · MIT LICENSED", t_card + 1.8, total, "805", 32, colour="0xf5cf74", box=False, fade=0.4),
        title("sonixz.github.io/gd-project/agent-manager", t_card + 2.1, total, "870", 28, colour="0xa8b8c8", box=False, fade=0.4),
    ]
    vchain = chain + f"{label}" + ",".join(titles) + f",fade=t=in:st=0:d=0.6,fade=t=out:st={total - 0.6:.3f}:d=0.6[v]"

    # audio: music bed under the voice (ducked), the voice lines on their scenes, a whoosh on two cuts, the impact on the logo
    A = os.path.join(VP, "assets", "audio")  # the exact takes used (re-making them gives other takes)
    vo = [("01-intro", 0.45), ("02-sessions", st["board"] + 0.25), ("03-repos", st["repos"] + 0.2), ("04-sandboxes", st["sbx"] + 0.25),
          ("05-bridge", st["health"] + 0.2), ("06-close", t_card + 1.0)]
    ai = ["-i", os.path.join(A, "music-a.mp3")]
    for vid, _ in vo:
        ai += ["-i", os.path.join(A, f"vo-{vid}.mp3")]
    ai += ["-i", os.path.join(A, "sfx-impact.mp3"), "-i", os.path.join(A, "sfx-whoosh.mp3")]
    base = len(plan)
    mi = base
    parts = []
    for j, (vid, at) in enumerate(vo):
        k = base + 1 + j
        ms = int(at * 1000)
        parts.append(f"[{k}:a]aresample=48000,aformat=channel_layouts=stereo,volume=1.0,adelay={ms}|{ms}[v{j}]")
    vmix = "".join(f"[v{j}]" for j in range(len(vo)))
    imp = base + 1 + len(vo)
    who = imp + 1
    t_imp = int((t_card + 0.5) * 1000)
    t_w1, t_w2 = int((st["sbx"] - 0.2) * 1000), int((st["health"] - 0.2) * 1000)
    achain = ";".join(parts) + ";" + (
        f"{vmix}amix=inputs={len(vo)}:normalize=0,apad[voice];"
        f"[voice]asplit=2[voice1][voice2];"
        f"[{mi}:a]aresample=48000,aformat=channel_layouts=stereo,volume=0.55,afade=t=out:st={total - 1.6:.3f}:d=1.6[music];"
        f"[music][voice2]sidechaincompress=threshold=0.03:ratio=6:attack=15:release=350[bed];"
        f"[{imp}:a]aresample=48000,aformat=channel_layouts=stereo,volume=0.8,adelay={t_imp}|{t_imp}[imp];"
        f"[{who}:a]aresample=48000,aformat=channel_layouts=stereo,volume=0.35,asplit=2[w1][w2];[w1]adelay={t_w1}|{t_w1}[wa];[w2]adelay={t_w2}|{t_w2}[wb];"
        f"[bed][voice1][imp][wa][wb]amix=inputs=5:normalize=0:duration=first,atrim=0:{total:.3f},loudnorm=I=-14:TP=-1.5:LRA=9[a]")

    master = os.path.join(OUT, "agent-manager-showcase.mp4")
    cmd = [FFMPEG, "-hide_banner", "-loglevel", "error", "-y"] + inputs + ai + [
        "-filter_complex", vchain + ";" + achain, "-map", "[v]", "-map", "[a]", "-t", f"{total:.3f}",
        "-c:v", "libx264", "-crf", "16", "-preset", "slow", "-profile:v", "high", "-pix_fmt", "yuv420p", "-r", str(FPS),
        "-c:a", "aac", "-b:a", "192k", "-ar", "48000", "-movflags", "+faststart", master]
    subprocess.run(cmd, check=True)
    json.dump({"total": total, "starts": st, "voice": dict(vo), "impact": t_imp / 1000}, open(os.path.join(WORK, "timeline.json"), "w"), indent=1)
    print(f"master: {master} ({total:.2f} s)")


if __name__ == "__main__":
    sys.exit(main())
