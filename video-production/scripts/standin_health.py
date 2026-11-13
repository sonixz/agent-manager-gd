"""The stand-in sandbox's health readings for the film (the tunnel scene): processors, memory, network and programs
move every second, as a real sandbox at work would. Only the readings are made up; their reading and drawing are the
app's own. Same shape as the sandbox-ports step of app/tools_showcase.gd."""
import math, os, sys, time
path = sys.argv[1]
busy = idle = rx = tx = 0
for i in range(1800):
    load = 0.35 + 0.3 * math.sin(i / 6.0) + (0.25 if 12 < i % 40 < 22 else 0.0)
    busy += int(200 * load); idle += int(200 * (1 - load))
    rx += int(40000 + 30000 * abs(math.sin(i / 4.0))); tx += int(6000 + 4000 * abs(math.cos(i / 5.0)))
    used = int(380000 + 60000 * math.sin(i / 9.0))
    text = (f"MemTotal: 1009636 kB\nMemFree: 211208 kB\nMemAvailable: {1009636 - used} kB\n---\n{load * 2:.2f} 0.31 0.12 1/97 2231\n---\n5123.40 9001.11\n---\n"
            "Filesystem 1-blocks Used Available Capacity Mounted on\n/dev/vdb 8350298112 2147483648 5771362304 28% /\n---\n"
            f"cpu  {busy} 0 0 {idle} 0 0 0 0 0 0\n---\n  eth0: {rx} 1 0 0 0 0 0 0 {tx} 1 0 0 0 0 0 0\n---\n"
            f"    412 streamlit       {60 * load:.1f} 182340\n    300 claude           {12 * load:.1f} 465788\n    655 python3          3.1  48120\n     41 sshd             0.0  7400\n---\n2\n")
    with open(path + ".tmp", "w") as f:
        f.write(text)
    os.replace(path + ".tmp", path)
    time.sleep(1.0)
