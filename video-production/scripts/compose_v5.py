#!/usr/bin/env python3
"""The showcase video V5 (about 48 s): Agent Manager GD and Second Brain GD, cut from real films.

Input:  video-production/captures/<step>/frameNNNNNNNN.png (Godot's movie mode, 1920x1080, 30 fps): Agent Manager's
        film-* steps (tools/showcase.sh) and film-brain-sb (the demo Second Brain, scripts/film_v5_brain.sh)
        marks: build/showcase/report-<step>.txt and captures/film-brain-sb/marks.txt (« mark <name> <frame> [x y w h] »)
        audio: assets/audio/v5/ (vo-v01..v09, music, whoosh, bell, impact: ElevenLabs, scripts/elevenlabs.py)
Output: output/agent-manager-showcase-v5.mp4 (master); scripts/render.sh makes the web encode and the poster.

Every picture is a piece of a real film, except the titles, the closing card, and in the Second Brain scene the
frame around the two apps and the light that travels from the agent's call to the Brain: an illustration laid over
two real recordings of the same moment (the agent's proposal and the Brain receiving it)."""
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
VP = os.path.dirname(HERE)
REPO = os.path.dirname(VP)
CAP = os.path.join(VP, "captures")
WORK = os.path.join(VP, "work", "v5")
OUT = os.path.join(VP, "output")
A = os.path.join(VP, "assets", "audio", "v5")
FFMPEG = os.environ.get("FFMPEG", os.path.expanduser("~/.local/opt/ffmpeg-n8.1.3-35/bin/ffmpeg"))
FONT = os.path.join(REPO, "app/assets/fonts/JetBrainsMonoNL-Regular.ttf")
FPS = 30
W, H = 1920, 1080
X = 0.25  # crossfade


def run(cmd: list) -> None:
    subprocess.run([FFMPEG, "-hide_banner", "-loglevel", "error", "-y"] + cmd, check=True)


def marks(step: str) -> dict:
    path = os.path.join(CAP, step, "marks.txt") if step.endswith("-sb") else os.path.join(REPO, "build/showcase", f"report-{step}.txt")
    out = {}
    for line in open(path, encoding="utf-8"):
        m = re.match(r"mark (\S+) (\d+)(?: (-?\d+) (-?\d+) (\d+) (\d+))?", line.strip())
        if m:
            out[m.group(1)] = {"frame": int(m.group(2)), "rect": [int(x) for x in m.groups()[2:]] if m.group(3) else None}
    return out


M: dict = {}


def fr(step: str, mark: str, plus: float = 0.0) -> int:
    if step not in M:
        M[step] = marks(step)
    return M[step][mark]["frame"] + int(round(plus * FPS))


def rect(step: str, mark: str, pad: int = 0) -> list:
    if step not in M:
        M[step] = marks(step)
    x, y, w, h = M[step][mark]["rect"]
    return [x - pad, y - pad, w + 2 * pad, h + 2 * pad]


def zoomvf(n: int, zoom_to, zoom: float, ease_in: float, start_zoom: float = 1.0) -> str:
    """The camera glides (on a 4x enlarged frame: no wobble) from start_zoom to zoom towards the rectangle's centre."""
    x, y, w, h = zoom_to
    cx, cy = x + w / 2, y + h / 2
    k = 4
    d0 = int(ease_in * FPS)
    p = f"(clip((on-{d0})/{max(1, n - d0)},0,1))"
    e = f"({p}*{p}*(3-2*{p}))"
    z = f"({start_zoom}+({zoom}-{start_zoom})*{e})"
    vx = f"clip({cx * k}-iw/{z}/2,0,iw-iw/{z})"
    vy = f"clip({cy * k}-ih/{z}/2,0,ih-ih/{z})"
    return f"scale={W * k}:{H * k}:flags=neighbor,zoompan=z='{z}':x='{vx}':y='{vy}':d=1:s={W}x{H}:fps={FPS},"


def shot(name: str, step: str, start: int, seconds: float, zoom_to=None, zoom=1.0, ease_in=0.0, start_zoom=1.0) -> str:
    n = int(round(seconds * FPS))
    out = os.path.join(WORK, f"shot-{name}.mp4")
    # a film that ends early holds its last picture, so every shot keeps its length (and the cut chain its timing)
    vf = "tpad=stop_mode=clone:stop_duration=3," + (zoomvf(n, zoom_to, zoom, ease_in, start_zoom) if zoom_to and (zoom > 1.0 or start_zoom > 1.0) else "") + "format=yuv420p"
    run(["-framerate", str(FPS), "-start_number", str(start), "-i", os.path.join(CAP, step, "frame%08d.png"),
         "-frames:v", str(n), "-vf", vf, "-c:v", "libx264", "-crf", "10", "-preset", "fast", out])
    return out


def glow() -> str:
    out = os.path.join(WORK, "glow.png")
    run(["-f", "lavfi", "-i", "color=c=black@0.0:s=110x110,format=rgba", "-frames:v", "1", "-vf",
         "geq=r='190':g='245':b='252':a='255*min(1,1.6*exp(-((X-55)*(X-55)+(Y-55)*(Y-55))/260))'", out])
    return out


def split(name: str, am_start: int, sb_start: int, seconds: float, beam: tuple, src: tuple, dst: tuple) -> str:
    """Agent Manager (left) and Second Brain (right), both real films of the same moment, in frames on the site's
    dark ground; light travels from the agent's terminal to the Brain between beam[0] and beam[1] (seconds)."""
    n = int(round(seconds * FPS))
    out = os.path.join(WORK, f"shot-{name}.mp4")
    pw, ph = 880, 495
    lx, rx, py = 60, W - 60 - pw, 300
    g = glow()
    t0, t1 = beam
    (sx, sy), (dx, dy) = src, dst  # in screen coordinates of each 1920x1080 film
    ax, ay = lx + sx * pw / W, py + sy * ph / H
    bx, by = rx + dx * pw / W, py + dy * ph / H
    dots, prev = "", "base"
    for j in range(4):
        d = j * 0.27
        prog = f"(mod(t-{t0}-{d},1.1)/1.1)"
        on = f"between(t,{t0}+{d},{t1})"
        dots += (f"[{prev}][dot{j}]overlay=x='if({on},{ax}+({bx}-{ax})*{prog}-55,-200)'"
                 f":y='if({on},{ay}+({by}-{ay})*{prog}-55-sin(PI*{prog})*90,-200)':format=auto[o{j}];")
        prev = f"o{j}"
    label = lambda text, x, col: (f"drawtext=fontfile='{FONT}':text='{text}':fontsize=26:fontcolor={col}:x={x}:y={py - 48}")
    fc = (f"[0:v]scale={pw}:{ph},pad={pw + 4}:{ph + 4}:2:2:color=0x8fe3ef[am];"
          f"[1:v]scale={pw}:{ph},pad={pw + 4}:{ph + 4}:2:2:color=0xc8b6ff[sb];"
          f"[2:v][am]overlay={lx - 2}:{py - 2}[b1];[b1][sb]overlay={rx - 2}:{py - 2},"
          f"{label('◆ AGENT MANAGER GD', lx, '0x8fe3ef')},{label('◇ SECOND BRAIN GD', rx, '0xc8b6ff')}[base];"
          + "[3:v]split=4[dot0][dot1][dot2][dot3];" + dots
          + f"[o3]format=yuv420p[v]")
    run(["-framerate", str(FPS), "-start_number", str(am_start), "-i", os.path.join(CAP, "film-brain", "frame%08d.png"),
         "-framerate", str(FPS), "-start_number", str(sb_start), "-i", os.path.join(CAP, "film-brain-sb", "frame%08d.png"),
         "-f", "lavfi", "-i", f"color=c=0x101a26:s={W}x{H}:r={FPS}:d={seconds}",
         "-loop", "1", "-framerate", str(FPS), "-i", g,
         "-filter_complex", fc, "-map", "[v]", "-frames:v", str(n), "-c:v", "libx264", "-crf", "10", "-preset", "fast", out])
    return out


def card(seconds: float) -> str:
    out = os.path.join(WORK, "shot-card.mp4")
    logo = os.path.join(VP, "assets", "branding", "logo-360.png")
    t0 = 0.55
    vf = (f"[1:v]format=rgba,fade=t=in:st={t0}:d=0.45:alpha=1[logo];"
          f"[0:v][logo]overlay=x='(W-w)/2':y='200-(1-min(1,max(0,(t-{t0})/0.45)))*30':format=auto,format=yuv420p[v]")
    run(["-f", "lavfi", "-i", f"color=c=0x101a26:s={W}x{H}:r={FPS}:d={seconds}", "-loop", "1", "-framerate", str(FPS), "-t", str(seconds), "-i", logo,
         "-filter_complex", vf, "-map", "[v]", "-frames:v", str(int(seconds * FPS)), "-c:v", "libx264", "-crf", "10", "-preset", "fast", out])
    return out


def esc(s: str) -> str:
    return s.replace("\\", "\\\\").replace(":", "\\:").replace("'", "’").replace("%", "\\%")


def title(text: str, t0: float, t1: float, y: str, size: int, colour: str = "white", box: bool = True, fade: float = 0.3) -> str:
    a = f"if(lt(t,{t0}+{fade}),(t-{t0})/{fade},if(gt(t,{t1}-{fade}),({t1}-t)/{fade},1))"
    b = ":box=1:boxcolor=0x0b121c@0.80:boxborderw=18|30" if box else ""
    return (f"drawtext=fontfile='{FONT}':text='{esc(text)}':fontsize={size}:fontcolor={colour}:x=(w-tw)/2:y={y}"
            f":alpha='{a}':enable='between(t,{t0},{t1})'{b}")


def main() -> None:
    os.makedirs(WORK, exist_ok=True)
    os.makedirs(OUT, exist_ok=True)
    sb = "film-brain-sb"
    plan = [
        # 1 · intro
        ("intro", shot("intro", "film-control", fr("film-control", "grid", 0.4), 3.25, zoom_to=[310, 40, 1600, 1000], zoom=1.06), 3.25),
        ("board", shot("board", "film-control", fr("film-control", "board", 0.3), 2.25), 2.25),
        # 2 · sessions, approvals, WSL
        ("approve", shot("approve", "film-approvals", fr("film-approvals", "approve", -1.6), 2.75, zoom_to=[0, 0, 1100, 640], zoom=1.35, ease_in=0.0, start_zoom=1.15), 2.75),
        ("wsl", shot("wsl", "film-wsl", fr("film-wsl", "hovered", -0.9), 2.75, zoom_to=rect("film-wsl", "chart", 40), zoom=1.35, ease_in=0.2), 2.75),
        # 3 · repositories
        ("repos", shot("repos", "film-repos", fr("film-repos", "list", 0.2), 2.0), 2.0),
        ("metro", shot("metro", "film-repos", fr("film-repos", "unfolded", 0.2), 3.25, zoom_to=rect("film-repos", "unfolded", 30), zoom=1.3, ease_in=0.2), 3.25),
        # 4 · sandboxes
        ("sbx", shot("sbx", "film-sandbox", fr("film-sandbox", "page", 0.3), 2.0), 2.0),
        ("sizes", shot("sizes", "film-sandbox", fr("film-sandbox", "sizes", -0.2), 3.75, zoom_to=rect("film-sandbox", "sizes", 60), zoom=1.45, ease_in=0.2), 3.75),
        # 5 · local bridge
        ("health", shot("health", "film-tunnel", fr("film-tunnel", "health", 0.0), 2.25, zoom_to=rect("film-tunnel", "health", 40), zoom=1.25), 2.25),
        ("wire", shot("wire", "film-tunnel", fr("film-tunnel", "socks", 0.3), 3.75, zoom_to=rect("film-tunnel", "wire", 40), zoom=1.5), 3.75),
        # 6 · your keys
        ("keys", shot("keys", "film-keys", fr("film-keys", "page", 0.0), 4.25, zoom_to=[322, 132, 1588, 700], zoom=1.25, ease_in=0.3), 4.25),
        # 7 · Agent Manager → Second Brain
        ("newsess", shot("newsess", "film-brain", fr("film-brain", "dialog", -1.2), 1.25, zoom_to=[665, 430, 590, 360], zoom=1.55, start_zoom=1.3), 1.25),
        ("agent", shot("agent", "film-brain", fr("film-brain", "propose", -2.4), 2.5, zoom_to=[320, 60, 1600, 700], zoom=1.3, start_zoom=1.15), 2.5),
        ("link", split("link", fr("film-brain", "propose", -1.0), fr(sb, "proposal", -1.6), 3.5, beam=(0.4, 2.9), src=(480, 640), dst=(1700, 36)), 3.5),
        # 8 · the archivist, in Second Brain
        ("waiting", shot("waiting", sb, fr(sb, "waiting", -1.9), 2.5, zoom_to=[580, 240, 780, 300], zoom=1.8, start_zoom=1.4), 2.5),
        ("filed", shot("filed", sb, fr(sb, "filed", -1.4), 2.25, zoom_to=[580, 230, 780, 200], zoom=2.0, start_zoom=1.7), 2.25),
        ("item", shot("item", sb, fr(sb, "item", -2.4), 3.0, zoom_to=[900, 320, 640, 440], zoom=1.6, ease_in=0.4), 3.0),
        # 9 · closing
        ("card", card(5.25), 5.25),
    ]
    inputs, chain, t = [], "", 0.0
    for _, path, _ in plan:
        inputs += ["-i", path]
    label = "[0:v]"
    for i in range(1, len(plan)):
        t += plan[i - 1][2] - X
        chain += f"{label}[{i}:v]xfade=transition=fade:duration={X}:offset={t:.3f}[x{i}];"
        label = f"[x{i}]"
    total = sum(p[2] for p in plan) - X * (len(plan) - 1)
    st, acc = {}, 0.0
    for p in plan:
        st[p[0]] = acc
        acc += p[2] - X
    tc = st["card"]
    small = "0x8fe3ef"
    titles = [
        title("EVERY AGENT. ONE CONTROL ROOM.", 0.8, st["approve"] - 0.1, "h-210", 54),
        title("SESSIONS · APPROVALS · WSL", st["approve"] + 0.2, st["repos"] - 0.1, "h-200", 48),
        title("REPOSITORIES · GIT · SSH", st["repos"] + 0.2, st["sbx"] - 0.1, "h-200", 48),
        title("ISOLATED CLOUD SANDBOXES", st["sbx"] + 0.2, st["health"] - 0.1, "h-200", 48),
        title("EXTEND YOUR LAB INTO THE CLOUD", st["health"] + 0.2, st["keys"] - 0.1, "h-210", 48),
        title("YOUR LOCALHOST  ←  SSH TUNNEL · SOCKS  →  CLOUD SANDBOX", st["wire"] + 0.3, st["keys"] - 0.1, "h-112", 28, colour=small),
        title("BRING YOUR OWN KEYS", st["keys"] + 0.2, st["newsess"] - 0.1, "h-210", 52),
        title("NO ACCOUNT · NO MIDDLEMAN · LOCAL-FIRST", st["keys"] + 0.6, st["newsess"] - 0.1, "h-120", 28, colour=small),
        title("CONNECTED TO SECOND BRAIN", st["newsess"] + 0.2, st["link"] - 0.1, "h-200", 48),
        title("propose_item  →  the archivist", st["link"] + 0.5, st["waiting"] - 0.1, "h-150", 32, colour=small),
        title("THE ARCHIVIST", st["waiting"] + 0.2, st["item"] - 0.1, "60", 50),
        title("KNOWLEDGE THAT PERSISTS", st["item"] + 0.1, tc - 0.05, "h-200", 50),
        title("MCP · PARA · YOUR RULES, YOUR OK", st["item"] + 0.4, tc - 0.05, "h-120", 28, colour=small),
        title("AGENT MANAGER GD", tc + 0.9, total, "600", 84, box=False, fade=0.4),
        title("YOUR AGENT LAB.", tc + 1.3, total, "715", 52, colour="0x8fe3ef", box=False, fade=0.4),
        title("OPEN SOURCE · MIT LICENSED", tc + 1.8, total, "805", 32, colour="0xf5cf74", box=False, fade=0.4),
        title("sonixz.github.io/gd-project/agent-manager", tc + 2.1, total, "870", 28, colour="0xa8b8c8", box=False, fade=0.4),
        title("Works with Second Brain GD · MIT", tc + 2.4, total, "925", 22, colour="0x8196ae", box=False, fade=0.4),
    ]
    vchain = chain + label + ",".join(titles) + f",fade=t=in:st=0:d=0.6,fade=t=out:st={total - 0.6:.3f}:d=0.6[v]"

    vo = [("v01", 0.45), ("v02", st["approve"] + 0.25), ("v03", st["repos"] + 0.2), ("v04", st["sbx"] + 0.25), ("v05", st["health"] + 0.25),
          ("v06", st["keys"] + 0.6), ("v07", st["newsess"] + 0.25), ("v08", st["waiting"] + 0.3), ("v09", tc + 1.0)]
    ai = ["-i", os.path.join(A, "music.mp3")]
    for vid, _ in vo:
        ai += ["-i", os.path.join(A, f"vo-{vid}.mp3")]
    ai += ["-i", os.path.join(A, "sfx-impact.mp3"), "-i", os.path.join(A, "sfx-whoosh.mp3"), "-i", os.path.join(A, "sfx-bell.mp3")]
    base = len(plan)
    parts = []
    for j, (vid, at) in enumerate(vo):
        ms = int(at * 1000)
        parts.append(f"[{base + 1 + j}:a]aresample=48000,aformat=channel_layouts=stereo,adelay={ms}|{ms}[v{j}]")
    imp, who, bell = base + 1 + len(vo), base + 2 + len(vo), base + 3 + len(vo)
    t_imp, t_who, t_bell = int((tc + 0.5) * 1000), int((st["newsess"] - 0.3) * 1000), int((st["waiting"] + 0.1) * 1000)
    achain = ";".join(parts) + ";" + (
        "".join(f"[v{j}]" for j in range(len(vo))) + f"amix=inputs={len(vo)}:normalize=0,apad[voice];[voice]asplit=2[voice1][voice2];"
        f"[{base}:a]aresample=48000,aformat=channel_layouts=stereo,volume=0.55,afade=t=out:st={total - 1.6:.3f}:d=1.6[music];"
        f"[music][voice2]sidechaincompress=threshold=0.03:ratio=6:attack=15:release=350[bed];"
        f"[{imp}:a]aresample=48000,aformat=channel_layouts=stereo,volume=0.8,adelay={t_imp}|{t_imp}[imp];"
        f"[{who}:a]aresample=48000,aformat=channel_layouts=stereo,volume=0.35,adelay={t_who}|{t_who}[who];"
        f"[{bell}:a]aresample=48000,aformat=channel_layouts=stereo,volume=0.3,adelay={t_bell}|{t_bell}[bell];"
        f"[bed][voice1][imp][who][bell]amix=inputs=5:normalize=0:duration=first,atrim=0:{total:.3f},loudnorm=I=-14:TP=-1.5:LRA=9[a]")
    master = os.path.join(OUT, "agent-manager-showcase-v5.mp4")
    run(inputs + ai + ["-filter_complex", vchain + ";" + achain, "-map", "[v]", "-map", "[a]", "-t", f"{total:.3f}",
                       "-c:v", "libx264", "-crf", "16", "-preset", "slow", "-profile:v", "high", "-pix_fmt", "yuv420p", "-r", str(FPS),
                       "-c:a", "aac", "-b:a", "192k", "-ar", "48000", "-movflags", "+faststart", master])
    json.dump({"total": total, "starts": st, "voice": dict(vo), "impact": t_imp / 1000, "whoosh": t_who / 1000, "bell": t_bell / 1000},
              open(os.path.join(WORK, "timeline.json"), "w"), indent=1)
    print(f"master: {master} ({total:.2f} s)")


if __name__ == "__main__":
    sys.exit(main())
