#!/usr/bin/env bash
# Build VCraft: a voxel sandbox engine written in V.
#
# There is no project-owned C anymore. src/ffi.v talks to the system C
# libraries (SDL2 / EGL / OpenGL / zlib) directly through V's FFI; those
# #flag directives live in src/ffi.v, so the linker picks them up here.
set -uo pipefail

cd "$(dirname "$0")"
ROOT="$PWD"

PROD="${PROD:-1}"
VFLAGS=(-cc gcc -enable-globals)
if [ "$PROD" = "1" ]; then
	VFLAGS+=(-prod)
fi

echo "==> building vcraft (V only)"
# Remove the old binary first so a failed build can never be mistaken for a
# successful one (a stale binary silently hid compile errors for a while).
rm -f build/vcraft
mkdir -p build
v "${VFLAGS[@]}" -o build/vcraft . 2>&1 | grep -v "implicit tcc" | grep -Ev '^\s*$'
status=${PIPESTATUS[0]}

if [ "$status" -ne 0 ] || [ ! -x build/vcraft ]; then
	echo "BUILD FAILED (v exit ${status})"
	exit 1
fi
echo "==> built build/vcraft"
