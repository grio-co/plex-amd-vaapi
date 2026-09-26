#!/usr/bin/env bash
# Verify that the bundled musl VAAPI driver can be loaded by Plex's *own* musl
# dynamic loader -- without a GPU, /dev/dri, or a running Plex.
#
# Why this shape: "Plex Transcoder" is a musl binary that ships its own
# ld-musl (lib/ld-musl-x86_64.so.1) and dlopen()s ${LIBVA_DRIVER_NAME}_drv_video.so
# from ${LIBVA_DRIVERS_PATH}. The host's glibc `ldd` cannot inspect a musl
# object, so every check below goes through Plex's loader:
#
#   1. `ld-musl --list <driver>`  -- every DT_NEEDED resolves via the RPATH
#                                    that the Dockerfile patched in (/opt/vaapi).
#   2. LD_PRELOAD=<driver> ld-musl "Plex Transcoder" -version
#                                 -- the loader maps *and fully relocates* the
#                                    driver and all its deps against Plex's musl.
#                                    A driver built on a newer musl than Plex
#                                    bundles dies here with
#                                    "Error relocating ...: qsort_r: symbol not found"
#                                    (the exact failure this repo exists to avoid).
#
# Usage (inside the built image, or via `docker run --rm --entrypoint`):
#   /opt/vaapi/driver-check.sh
# Env overrides (mainly for running against an unpacked tree without Docker):
#   PLEX_HOME   (default /usr/lib/plexmediaserver)
#   VAAPI_DIR   (default /opt/vaapi)
#   LIBVA_DRIVER_NAME (default radeonsi)
#   EXPECTED_MUSL (default 1.2.2) -- warn (not fail) if Plex's bundled musl differs
set -euo pipefail

PLEX_HOME="${PLEX_HOME:-/usr/lib/plexmediaserver}"
VAAPI_DIR="${VAAPI_DIR:-/opt/vaapi}"
DRIVER_NAME="${LIBVA_DRIVER_NAME:-radeonsi}"
EXPECTED_MUSL="${EXPECTED_MUSL:-1.2.2}"

LOADER="$PLEX_HOME/lib/ld-musl-x86_64.so.1"
TRANSCODER="$PLEX_HOME/Plex Transcoder"
DRIVER="$VAAPI_DIR/dri/${DRIVER_NAME}_drv_video.so"

fail() { echo "FAIL: $*" >&2; exit 1; }
step() { echo; echo "=== $*"; }

step "files"
for f in "$LOADER" "$TRANSCODER" "$DRIVER"; do
  [ -e "$f" ] || fail "missing: $f"
  echo "ok: $f"
done

step "Plex bundled musl"
musl_ver="$("$LOADER" 2>&1 | sed -n 's/^Version //p' | head -1 || true)"
[ -n "$musl_ver" ] || fail "could not read musl version from $LOADER"
echo "musl $musl_ver (driver bundle is built for musl $EXPECTED_MUSL)"
if [ "$musl_ver" != "$EXPECTED_MUSL" ]; then
  echo "WARN: Plex now bundles musl $musl_ver, not $EXPECTED_MUSL." >&2
  echo "WARN: A driver built on an older musl still loads (newer musl is a superset)," >&2
  echo "WARN: but the ALPINE_VERSION pin in the Dockerfile may be bumpable. See README." >&2
fi

step "driver bundle"
echo "driver: $DRIVER"
n=$(find "$VAAPI_DIR" -maxdepth 1 -name '*.so*' | wc -l)
echo "sibling libs in $VAAPI_DIR: $n"
[ "$n" -gt 0 ] || fail "no shared libraries bundled next to the driver"
if grep -q -a '__vaDriverInit_' "$DRIVER"; then
  echo "ok: driver exports a __vaDriverInit_* entry point"
else
  fail "driver does not contain a __vaDriverInit_* symbol -- not a VA driver?"
fi

step "1/2 dependency resolution via Plex's ld-musl --list"
# Plex's loader honours the driver's patched RPATH (/opt/vaapi); LD_LIBRARY_PATH
# points at Plex's own libs (libva etc.) exactly like the transcoder runs.
list_out="$(LD_LIBRARY_PATH="$PLEX_HOME/lib" "$LOADER" --list "$DRIVER" 2>&1)" || {
  echo "$list_out"; fail "ld-musl --list failed for $DRIVER"; }
echo "$list_out"
if echo "$list_out" | grep -Eiq 'not found|Error loading'; then
  fail "unresolved dependency in $DRIVER"
fi
# Every bundled sibling must also be self-consistent (they carry the same RPATH).
bad=0
for so in "$VAAPI_DIR"/*.so*; do
  out="$(LD_LIBRARY_PATH="$PLEX_HOME/lib" "$LOADER" --list "$so" 2>&1)" || bad=1
  if echo "$out" | grep -Eiq 'not found|Error loading'; then
    echo "$out" | grep -Ei 'not found|Error loading' | sed "s|^|  $(basename "$so"): |"
    bad=1
  fi
done
[ "$bad" -eq 0 ] || fail "one or more bundled libraries have unresolved dependencies"
echo "ok: all DT_NEEDED entries resolve"

step "2/2 full load + relocation under Plex's musl (LD_PRELOAD into Plex Transcoder)"
set +e
preload_out="$(LD_PRELOAD="$DRIVER" LD_LIBRARY_PATH="$PLEX_HOME/lib" \
  "$LOADER" "$TRANSCODER" -version 2>&1)"
rc=$?
set -e
echo "$preload_out" | head -1
if [ "$rc" -ne 0 ] || echo "$preload_out" | grep -Eiq 'Error relocating|symbol not found|Error loading'; then
  echo "$preload_out" | grep -Ei 'Error relocating|symbol not found|Error loading' || true
  fail "driver could not be loaded by Plex's musl (exit $rc)"
fi
echo "ok: driver + $n deps loaded and relocated against Plex's musl $musl_ver"

echo
echo "PASS: $DRIVER loads under Plex's musl loader"
