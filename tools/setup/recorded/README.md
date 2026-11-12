# What the setup check is checked against

`app/tools_setup_check.gd` reads these and many states written in the script itself.

| File | Where it comes from |
|---|---|
| `windows-en.txt` | Recorded on a real Windows 11 (English, WSL 2.6.3, one Ubuntu distribution): the answer to the PowerShell call of `app/scripts/setup_probe.gd`, as the app receives it. The sizes (memory, disk file, drive) are rounded. The lines `free=` and `vmmem=` were recorded later (2026-11-12) by the same call, on the same computer. |
| `doctor.txt` | Recorded in that distribution: the answer of `engine/doctor.sh 8790`, with the user's name replaced by `dev` and the engine's process number by `4242`. |

Every other state in the script (no WSL, no distribution, Docker Desktop's distribution as the default one, WSL 1,
Windows in French, an old Windows, virtualization off, a silent PowerShell) is **written by hand** from what
Microsoft's documentation says. None of them was seen on a computer yet. Replace them with recordings when one is
at hand:

```bash
godot --headless --path app --script res://tools_setup_check.gd -- argv     # the call, to run in Windows
godot --headless --path app --script res://tools_setup_check.gd -- parse windows.txt doctor.txt
```
