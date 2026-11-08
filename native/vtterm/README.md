# VtTerminal (GDExtension)

A terminal Control for Godot 4.7: libghostty-vt (MIT, Ghostty) keeps the terminal state and encodes input; this
extension owns the pseudo-terminal and draws the grid with Godot fonts and theme colours.

Build (Linux/WSL, user folders, no admin rights):

1. Zig 0.17.0 from https://ziglang.org/download/ (check the SHA-256 from the official index).
2. Ghostty at a pinned commit (round 2: `e035beb9437118b803830a5864ea2f4dd7094354`):
   `zig build -Demit-lib-vt -Doptimize=ReleaseFast` → `zig-out/lib/libghostty-vt.so*`, `zig-out/include`.
3. godot-cpp `10.0.0-stable`; SCons 4.10.1 in a venv.
4. Here: `scons GODOT_CPP=~/src/godot-cpp GHOSTTY=~/src/ghostty/zig-out target=template_debug`, then copy
   `libghostty-vt.so.1` next to the built library (`prototype/terminal-ghostty/addons/vtterm/bin/`).

Windows (cross-built from WSL): `zig build -Demit-lib-vt -Doptimize=ReleaseFast -Dtarget=x86_64-windows-gnu --prefix zig-out-win`
for `ghostty-vt.dll`; then `scons platform=windows use_mingw=yes mingw_prefix=<folder with x86_64-w64-mingw32-gcc/g++/ar/ranlib/gcc-ar
wrappers calling `zig cc`/`zig c++ -target x86_64-windows-gnu`>` and copy `ghostty-vt.dll` next to the built DLL.

API: `start(program, args, cwd, env)`, `feed(bytes)`, `write_input(bytes)`, `paste_text(text)`,
`get_selection_text()`, `get_screen_text()`; properties `font`, `font_size`, `palette` (16 colours), `foreground`, `background`;
signals `exited`, `output_received`, `input_sent`, `grid_resized`, `bell`, `title_changed`.
