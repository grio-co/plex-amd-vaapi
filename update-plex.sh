#!/usr/bin/env bash
# Refresh a custom plex-amd image: pull the newest linuxserver/plex base AND
# rebuild the Alpine musl VAAPI driver layer, then recreate the container and
# re-verify hardware encode.
#
# WHY THIS EXISTS: a locally-built Plex image is invisible to Watchtower/auto-
# updaters (nothing to pull), so it never auto-updates. PMS *itself* self-updates
# on restart when VERSION=latest|plexpass; THIS script is for the other track --
# the linuxserver base OS layer + the HW-transcode driver. Run it monthly-ish, or
# after a linuxserver release.
#
# Usage:  ./update-plex.sh [compose-service] [container-name] [render-node]
#   defaults: service=plex  container=plex  render=/dev/dri/renderD128
#   env:      PLEX_VERSION=<linuxserver tag>  override the pinned base image tag
#             (passed through as a build arg; unset = Dockerfile/compose default)
# Run it from the directory containing your docker-compose.yml.
set -euo pipefail
cd "$(dirname "$0")"

SVC="${1:-plex}"
CTR="${2:-plex}"
RENDER="${3:-/dev/dri/renderD128}"

build_args=()
if [ -n "${PLEX_VERSION:-}" ]; then
  echo ">> Using linuxserver/plex base tag: $PLEX_VERSION"
  build_args+=(--build-arg "PLEX_VERSION=$PLEX_VERSION")
fi
echo ">> Pulling the linuxserver/plex base + rebuilding the VAAPI driver layer..."
docker compose build --pull ${build_args[@]+"${build_args[@]}"} "$SVC"

echo ">> Recreating $CTR..."
docker compose up -d "$SVC"

echo ">> Waiting for Plex to come up..."
for i in $(seq 1 30); do
  code=$(curl -s -m 5 -o /dev/null -w "%{http_code}" http://localhost:32400/identity || true)
  [ "$code" = "200" ] && { echo "   Plex healthy (~$((i*5))s)"; break; }
  sleep 5
done

echo ">> Verifying the HW VAAPI driver still loads (rawvideo -> h264_vaapi)..."
docker exec "$CTR" bash -c '
  export LD_LIBRARY_PATH=/usr/lib/plexmediaserver/lib
  export LIBVA_DRIVERS_PATH=/opt/vaapi/dri LIBVA_DRIVER_NAME=radeonsi
  "/usr/lib/plexmediaserver/Plex Transcoder" -hide_banner -loglevel error \
    -init_hw_device vaapi=amd:'"$RENDER"' -filter_hw_device amd \
    -f rawvideo -pix_fmt nv12 -video_size 1280x720 -r 30 -i /dev/zero \
    -t 2 -vf hwupload -c:v h264_vaapi -f null - >/dev/null 2>&1 \
    && echo "   OK: h264_vaapi hardware encode works." \
    || echo "   WARN: HW encode failed. Check Plex bundled musl vs the Alpine base:
            docker exec '"$CTR"' /usr/lib/plexmediaserver/lib/libc.so 2>&1 | grep Version
            then set the matching Alpine release in the Dockerfile (see README table)."
'
