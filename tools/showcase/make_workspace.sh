#!/usr/bin/env bash
# Builds the fictional workspace the website screenshots show: a user « dev » with three small git projects.
# Nothing personal: its own HOME, its own git identity (dev@example.com), commits dated in October 2026.
#   tools/showcase/make_workspace.sh <root>      → <root>/home/dev (HOME), <root>/home/dev/code/<project>
set -euo pipefail
ROOT="$1"; HERE="$(cd "$(dirname "$0")" && pwd)"
H="$ROOT/home/dev"; mkdir -p "$H/code"
cat > "$H/.profile" <<P
export PATH="$HERE/bin:\$PATH"
export SHOWCASE_SCENES="$HERE/scenes" SHOWCASE_MAP="$ROOT/map" SHOWCASE_REMOTES="$ROOT/remote"
[ -f "\$HOME/.bashrc" ] && . "\$HOME/.bashrc"
P
cat > "$H/.bashrc" <<'B'
PS1='\[\e[38;5;114m\]dev@workstation\[\e[0m\]:\[\e[38;5;75m\]\w\[\e[0m\]$ '
alias ls='ls --color=auto'
B
mkdir -p "$ROOT/map"
G=(git -c user.name="Dev" -c user.email="dev@example.com" -c init.defaultBranch=main -c commit.gpgsign=false)

commit() {  # commit <repo> <date> <message>
  (cd "$1" && git add -A && GIT_AUTHOR_DATE="$2" GIT_COMMITTER_DATE="$2" "${G[@]}" commit -qm "$3")
}

# --- acme-store: a small web shop (TypeScript)
A="$H/code/acme-store"; mkdir -p "$A/src/checkout" "$A/tests"; (cd "$A" && "${G[@]}" init -q)
cat > "$A/README.md" <<'X'
# Acme Store
A small storefront: catalogue, cart and checkout.
X
cat > "$A/src/checkout/cart.ts" <<'X'
export interface Line { sku: string; price: number; qty: number }
export function subtotal(lines: Line[]): number {
  return lines.reduce((sum, l) => sum + l.price * l.qty, 0);
}
X
cat > "$A/tests/cart.test.ts" <<'X'
import { subtotal } from "../src/checkout/cart";
test("subtotal", () => expect(subtotal([{ sku: "A1", price: 12.5, qty: 2 }])).toBe(25));
X
echo '{ "name": "acme-store", "version": "0.4.0", "scripts": { "test": "vitest" } }' > "$A/package.json"
commit "$A" "2026-10-02T10:12:00" "Catalogue page and product cards"
echo 'export const TAX_RATE = 0.14975;' > "$A/src/checkout/tax.ts"
commit "$A" "2026-10-09T15:40:00" "Quebec sales tax on the cart total"
echo '// shipping zones: local, national, international' > "$A/src/checkout/shipping.ts"
commit "$A" "2026-10-21T09:05:00" "Shipping zones"
echo 'export const FREE_SHIPPING_FROM = 75;' >> "$A/src/checkout/shipping.ts"
commit "$A" "2026-10-30T17:22:00" "Free shipping from \$75"

# --- orbit-api: a Python service
O="$H/code/orbit-api"; mkdir -p "$O/orbit" "$O/tests"; (cd "$O" && "${G[@]}" init -q)
cat > "$O/README.md" <<'X'
# Orbit API
Satellite pass predictions over HTTP.
X
touch "$O/tests/__init__.py"
cat > "$O/orbit/__init__.py" <<'X'
X
cat > "$O/orbit/passes.py" <<'X'
"""Visible passes of a satellite over a place."""


def next_passes(lat: float, lon: float, hours: int = 24) -> list[dict]:
    if not -90 <= lat <= 90:
        raise ValueError("latitude out of range")
    return [{"rise": "21:14", "peak": "21:19", "set": "21:24", "max_elevation": 61}]
X
cat > "$O/tests/test_passes.py" <<'X'
import unittest

from orbit.passes import next_passes


class Passes(unittest.TestCase):
    def test_one_pass(self):
        self.assertEqual(len(next_passes(45.5, -73.6)), 1)

    def test_latitude(self):
        with self.assertRaises(ValueError):
            next_passes(120, 0)

    def test_peak_elevation(self):
        self.assertGreater(next_passes(45.5, -73.6)[0]["max_elevation"], 10)
X
commit "$O" "2026-10-05T11:00:00" "Pass predictions endpoint"
echo '# rate limits: 60 requests a minute per key' > "$O/orbit/limits.py"
commit "$O" "2026-10-18T14:30:00" "Rate limits, first draft"
echo 'MAX_HOURS = 72' >> "$O/orbit/passes.py"
commit "$O" "2026-10-27T10:45:00" "Predictions up to 72 hours ahead"

# --- pixel-forge: a small Godot game
P="$H/code/pixel-forge"; mkdir -p "$P/scenes" "$P/scripts"; (cd "$P" && "${G[@]}" init -q)
echo '# Pixel Forge' > "$P/README.md"
printf 'extends GPUParticles2D\n\nfunc burst() -> void:\n\trestart()\n' > "$P/scripts/sparks.gd"
commit "$P" "2026-10-12T20:10:00" "Forge scene and anvil sparks"
printf '\nfunc cool_down() -> void:\n\tamount = 8\n' >> "$P/scripts/sparks.gd"
commit "$P" "2026-10-29T21:35:00" "Sparks cool down after a strike"
# each project has a GitHub-looking origin (git@github.com:acme/<project>.git) served from a local bare copy in
# <root>/remote by tools/showcase/bin/ssh, so a connected repository checks « connected » without any network
mkdir -p "$ROOT/remote"
for p in acme-store orbit-api pixel-forge; do
  git clone -q --bare "$H/code/$p" "$ROOT/remote/$p.git"
  git -C "$H/code/$p" remote add origin "git@github.com:acme/$p.git"
done
echo "$H"
