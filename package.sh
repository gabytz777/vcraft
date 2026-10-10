#!/usr/bin/env bash
# Build a self-contained AppImage of vcraft.
#
# Usage: ./package.sh
# Output: dist/vcraft-x86_64.AppImage
#
# The AppImage bundles the game binary and launcher; it relies on the host
# providing the standard graphics stack (libSDL2, libEGL, libGL, libz), which
# is present on Arch/CachyOS and most desktops. See the README disclaimer.
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$PWD"
DIST="$ROOT/dist"
APPDIR="$ROOT/build/vcraft.AppDir"
TOOLS="${TOOLS:-/tmp/opencode}"
mkdir -p "$TOOLS"

echo "==> [1/4] building game"
./build.sh

echo "==> [2/4] assembling AppDir"
rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/bin"
cp "$ROOT/build/vcraft" "$APPDIR/usr/bin/vcraft"
strip "$APPDIR/usr/bin/vcraft" 2>/dev/null || true

cat > "$APPDIR/AppRun" <<'EOF'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
exec "$HERE/usr/bin/vcraft" "$@"
EOF
chmod +x "$APPDIR/AppRun"

cat > "$APPDIR/vcraft.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=VCraft
Comment=Voxel sandbox game written in V
Exec=vcraft
Icon=vcraft
Categories=Game;
Terminal=false
EOF

echo "==> [3/4] rendering icon"
python3 - "$APPDIR/vcraft.png" <<'PY'
import sys, zlib, struct, random
random.seed(7)
W = H = 256
def lerp(a, b, t): return int(a + (b - a) * t)
px = bytearray()
# sky
for y in range(H):
    for x in range(W):
        px += bytes((lerp(120, 180, y/H), lerp(170, 210, y/H), 240, 255))
def block(x0, y0, x1, y1, top, side):
    for y in range(y0, y1):
        for x in range(x0, x1):
            n = random.randint(-14, 14)
            base = top if y < y0 + (y1-y0)//4 else side
            i = (y*W + x)*4
            px[i]   = max(0, min(255, base[0] + n))
            px[i+1] = max(0, min(255, base[1] + n))
            px[i+2] = max(0, min(255, base[2] + n))
            px[i+3] = 255
block(48, 96, 208, 256, (86, 160, 58), (122, 90, 56))
def chunk(out, typ, data):
    out += struct.pack('>I', len(data)) + typ + data
    out += struct.pack('>I', zlib.crc32(typ + data) & 0xffffffff)
    return out
raw = b''.join(b'\x00' + bytes(px[y*W*4:(y+1)*W*4]) for y in range(H))
out = b'\x89PNG\r\n\x1a\n'
out = chunk(out, b'IHDR', struct.pack('>IIBBBBB', W, H, 8, 6, 0, 0, 0))
out = chunk(out, b'IDAT', zlib.compress(raw, 9))
out = chunk(out, b'IEND', b'')
open(sys.argv[1], 'wb').write(out)
PY

echo "==> [4/4] packaging"
mkdir -p "$DIST"
TOOL="$TOOLS/appimagetool-x86_64.AppImage"
if [ ! -x "$TOOL" ]; then
	curl -sSL -o "$TOOL" \
		https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage
	chmod +x "$TOOL"
fi
ARCH=x86_64 APPIMAGE_EXTRACT_AND_RUN=1 "$TOOL" "$APPDIR" "$DIST/vcraft-x86_64.AppImage"

echo "==> built $DIST/vcraft-x86_64.AppImage"
ls -lh "$DIST/vcraft-x86_64.AppImage"
