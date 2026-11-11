#!/usr/bin/env bash
# Build a self-contained AppImage of vcraft.
#
# Usage: ./package.sh
# Output: dist/vcraft-x86_64.AppImage
#
# The AppImage bundles the game binary and launcher; it relies on the host
# providing the standard graphics stack (libSDL2, libEGL, libGL, libz), which
# is present on Arch/CachyOS and most desktops. See the README disclaimer.
#
# Run this on the oldest still-supported Ubuntu LTS (release.yml does): a
# binary only runs where the host's C library is at least as new as the one
# it was linked against, so building on an old base widens compatibility
# instead of narrowing it. The AppImage catalog (appimage.github.io) tests on
# that same baseline and rejects AppImages built against a newer glibc.
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

# The desktop file is named after the AppStream id so that appstreamcli and
# software centres can tie the two together; Icon= and Name= keep the plain
# project names, which is what the AppDir icon lookup expects.
DESKTOP="$APPDIR/io.github.gabytz777.vcraft.desktop"
cat > "$DESKTOP" <<'EOF'
[Desktop Entry]
Type=Application
Name=VCraft
Comment=Voxel sandbox game written in V
Exec=vcraft
Icon=vcraft
Categories=Game;
Terminal=false
EOF
# AppDir convention: a copy in the standard location for desktop integration
# and appstreamcli's launchable resolution, next to the one at the top level.
mkdir -p "$APPDIR/usr/share/applications"
cp "$DESKTOP" "$APPDIR/usr/share/applications/"

# AppStream metainfo, so the AppImage carries its own description (and the
# AppImage catalog stops warning about a missing appdata file). Version and
# date come from v.mod and the build clock, so they never drift.
VERSION="$(sed -n "s/^[[:space:]]*version:[[:space:]]*'\([^']*\)'.*/\1/p" "$ROOT/v.mod")"
DATE="$(date -u +%F)"
mkdir -p "$APPDIR/usr/share/metainfo"
cat > "$APPDIR/usr/share/metainfo/io.github.gabytz777.vcraft.appdata.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<component type="desktop-application">
  <id>io.github.gabytz777.vcraft</id>
  <metadata_license>CC0-1.0</metadata_license>
  <project_license>MIT</project_license>
  <name>VCraft</name>
  <summary>Voxel sandbox game written in V</summary>
  <description>
    <p>VCraft is a small Minecraft-like voxel sandbox written entirely in V.
    It has procedural terrain with biomes, caves and water, mining and
    building, a hotbar, a pause menu with settings, and procedurally
    generated sound effects.</p>
    <p>All textures, the bitmap font and every sound are generated at
    startup; no third-party game assets are used.</p>
  </description>
  <launchable type="desktop-id">io.github.gabytz777.vcraft.desktop</launchable>
  <url type="homepage">https://github.com/gabytz777/vcraft</url>
  <url type="bugtracker">https://github.com/gabytz777/vcraft/issues</url>
  <developer_name>gabytz777</developer_name>
  <provides>
    <binary>vcraft</binary>
  </provides>
  <releases>
    <release version="${VERSION}" date="${DATE}"/>
  </releases>
</component>
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

# Icon in the places lookups expect: the top level and .DirIcon for the
# AppImage itself, and the hicolor theme for desktop integration.
mkdir -p "$APPDIR/usr/share/icons/hicolor/256x256/apps"
cp "$APPDIR/vcraft.png" "$APPDIR/usr/share/icons/hicolor/256x256/apps/"
cp "$APPDIR/vcraft.png" "$APPDIR/.DirIcon"

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
