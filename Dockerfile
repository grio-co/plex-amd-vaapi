# Stage 1: musl-built AMD VAAPI driver from Alpine.
# CRITICAL: Plex "Plex Transcoder" is a *musl* binary (bundles ld-musl + its own
# musl libva, but NO VA driver). A glibc mesa driver can NEVER dlopen into a musl
# process. Alpine ships a musl-built radeonsi driver (mesa-va-gallium) -- the only
# kind Plex's transcoder can load.
#
# ALPINE_VERSION must not exceed the musl release Plex bundles. Plex Media Server
# 1.43.4 (2026-09) still ships musl 1.2.2, and every Alpine >= 3.16 builds mesa
# against musl >= 1.2.3 whose driver imports qsort_r -- which Plex's musl does not
# export ("Error relocating radeonsi_drv_video.so: qsort_r: symbol not found").
# Alpine 3.15 is EOL (2023-11) but it is a build stage only: nothing from it runs
# in the final image except the driver .so files copied out below. The v3.15
# package mirror is still served. See README "Why Alpine 3.15 (and why not newer)".
# PLACEHOLDER(greg): confirm staying on Alpine 3.15 (EOL); 3.16-3.24 all need qsort_r, which Plex's musl 1.2.2 lacks
ARG ALPINE_VERSION=3.15
# Pinned linuxserver/plex tag for stage 2 (<plex version>-ls<build>); override with
#   docker build --build-arg PLEX_VERSION=<tag> .
# Tags: https://github.com/linuxserver/docker-plex/releases (or `latest`).
# (Both ARGs live above the first FROM: an ARG between stages is scoped to the
# preceding stage and would not be visible to the second FROM.)
ARG PLEX_VERSION=1.43.4.10903-e5521bd8c-ls325
FROM alpine:${ALPINE_VERSION} AS vaapi
RUN apk add --no-cache mesa-va-gallium libva patchelf
RUN set -eux; mkdir -p /opt/vaapi/dri; \
    cp -aL /usr/lib/dri/radeonsi_drv_video.so /opt/vaapi/dri/; \
    deps() { ldd "$1" 2>/dev/null | awk '/=>/{print $3}'; }; \
    deps /opt/vaapi/dri/radeonsi_drv_video.so | sort -u | while read -r l; do \
      case "$l" in */ld-musl*|*/libc.musl*|"") continue;; esac; cp -aL "$l" /opt/vaapi/ 2>/dev/null || true; done; \
    for so in /opt/vaapi/*.so*; do deps "$so"; done | sort -u | while read -r l; do \
      case "$l" in */ld-musl*|*/libc.musl*|"") continue;; esac; \
      b=$(basename "$l"); [ -e "/opt/vaapi/$b" ] || cp -aL "$l" /opt/vaapi/ 2>/dev/null || true; done; \
    patchelf --set-rpath /opt/vaapi /opt/vaapi/dri/radeonsi_drv_video.so; \
    for so in /opt/vaapi/*.so*; do patchelf --set-rpath /opt/vaapi "$so" 2>/dev/null || true; done; \
    echo "=== musl VAAPI userspace ==="; ls /opt/vaapi; echo "count=$(ls /opt/vaapi/*.so* | wc -l)"

# Stage 2: linuxserver/plex + the musl VAAPI driver (PLEX_VERSION: see top)
FROM lscr.io/linuxserver/plex:${PLEX_VERSION}
COPY --from=vaapi /opt/vaapi /opt/vaapi
# Self-test: loads the driver through Plex's own musl loader, no GPU required.
#   docker run --rm --entrypoint /opt/vaapi/driver-check.sh <image>
COPY ci/driver-check.sh /opt/vaapi/driver-check.sh
ENV LIBVA_DRIVERS_PATH=/opt/vaapi/dri \
    LIBVA_DRIVER_NAME=radeonsi
