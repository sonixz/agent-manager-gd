# Terminal prototype (Loop 2)

Bench for VT engine candidates, attached to a private tmux server (`tmux -L agmgd-bench`).

godot-xterm is not committed: download `godot-xterm-v4.0.3.zip` from https://github.com/lihop/godot-xterm/releases,
check SHA-256 `3c41f533962be0880ed681d18d5c6e0d0a1c7f683386ca0630f99f2739d9ccae`, and copy its `addons/godot_xterm`
here. Then `tools/bench.sh <render|input|tui|mouse|perf|baseline> <out-dir>` (virtual display; `BENCH_TRUSTED=<folder>`
for the tui mode starts Claude Code and Codex in a folder they already trust).
