# Stage 1: musl-built AMD VAAPI driver from Alpine.
# CRITICAL: Plex "Plex Transcoder" is a *musl* binary (bundles ld-musl + its own
# musl libva, but NO VA driver). A glibc mesa driver can NEVER dlopen into a musl
# process. Alpine ships a musl-built radeonsi driver (mesa-va-gallium) -- the only
# kind Plex's transcoder can load.
FROM alpine:3.15 AS vaapi
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

# Stage 2: linuxserver/plex + the musl VAAPI driver
FROM lscr.io/linuxserver/plex:latest
COPY --from=vaapi /opt/vaapi /opt/vaapi
ENV LIBVA_DRIVERS_PATH=/opt/vaapi/dri \
    LIBVA_DRIVER_NAME=radeonsi