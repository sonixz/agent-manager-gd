"""Heavy output for the speed test: coloured lines for N seconds (default 6)."""
import sys, time
end = time.time() + float(sys.argv[1] if len(sys.argv) > 1 else 6)
i = 0
while time.time() < end:
    sys.stdout.write(f"\x1b[38;5;{16 + i % 216}m{i:08d} " + "agent output é à ✓ " * 6 + "\x1b[0m\n")
    i += 1
sys.stdout.flush()
