"""Prints the colour test: 16 ANSI, the 256-colour cube, 24-bit gradients, styles."""
import sys
w = sys.stdout.write
for i in range(16):
    w(f"\x1b[48;5;{i}m {i:2d} ")
w("\x1b[0m\n")
for i in range(16, 232):
    w(f"\x1b[48;5;{i}m  ")
    if (i - 15) % 36 == 0:
        w("\x1b[0m\n")
for i in range(232, 256):
    w(f"\x1b[48;5;{i}m  ")
w("\x1b[0m\n")
for row in range(3):
    for x in range(72):
        t = x / 71
        r, g, b = [(int(255 * t), 0, int(255 * (1 - t))), (0, int(255 * t), 128), (int(255 * t),) * 3][row]
        w(f"\x1b[48;2;{r};{g};{b}m ")
    w("\x1b[0m\n")
w("\x1b[1mbold\x1b[0m \x1b[2mdim\x1b[0m \x1b[3mitalic\x1b[0m \x1b[4munderline\x1b[0m \x1b[7minverse\x1b[0m "
  "\x1b[9mstrike\x1b[0m \x1b[38;2;255;120;0mtruecolor orange text\x1b[0m\n")
