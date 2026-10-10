#!/usr/bin/env bash
# Build VCraft: a voxel sandbox engine written in V.
#
# The C shim (csrc/shim.c) holds only GL/SDL/EGL boilerplate that is awkward
# to express through V's FFI. All game logic is V.
set -uo pipefail

cd "$(dirname "$0")"
ROOT="$PWD"

PROD="${PROD:-1}"
CFLAGS="-I$ROOT/csrc -L$ROOT/build -l:libshim.a -lEGL -lGL -lSDL2 -lz -lm"
VFLAGS=(-cc gcc -cflags "$CFLAGS")
if [ "$PROD" = "1" ]; then
	VFLAGS+=(-prod)
fi

echo "==> [1/2] C shim"
mkdir -p build
cc -O2 -DGL_GLEXT_PROTOTYPES -fPIC -c csrc/shim.c -o build/shim.o || exit 1
ar rcs build/libshim.a build/shim.o || exit 1

echo "==> [2/2] V"
# Remove the old binary first so a failed build can never be mistaken for a
# successful one (a stale binary silently hid compile errors for a while).
rm -f build/vcraft
v "${VFLAGS[@]}" -o build/vcraft . 2>&1 | grep -v "implicit tcc" | grep -Ev '^\s*$'
status=${PIPESTATUS[0]}

if [ "$status" -ne 0 ] || [ ! -x build/vcraft ]; then
	echo "BUILD FAILED (v exit ${status})"
	exit 1
fi
echo "==> built build/vcraft"
