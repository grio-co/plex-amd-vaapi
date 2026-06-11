# Plex AMD VAAPI Hardware Transcoding (the musl fix)

Getting **AMD iGPU/GPU hardware transcoding** working in a Dockerized Plex Media
Server — and a full write-up of *why* the "obvious" approaches all fail.

If you've installed `mesa-va-drivers` into a Plex container and still get
**software transcoding**, with errors like:

```
Error relocating .../radeonsi_drv_video.so: __isoc23_strtoul: symbol not found
Error relocating .../radeonsi_drv_video.so: fcntl64: symbol not found
Error relocating .../radeonsi_drv_video.so: qsort_r: symbol not found
```

…this repo explains the real root cause and ships a working `Dockerfile`.

---

## TL;DR

**Modern Plex Media Server's `Plex Transcoder` is a [musl](https://musl.libc.org/)
binary** — it bundles its own `ld-musl` (musl **1.2.2** at time of writing) and
its own musl `libva`, but **ships no VA driver**. It expects the host/image to
provide `radeonsi_drv_video.so`.

Every `mesa-va-drivers` package from Ubuntu/Debian is built against **glibc**.
**You cannot `dlopen` a glibc shared object into a musl process** — it's a
different libc ABI, not a version mismatch. That's why every fix attempt hits a
different missing glibc symbol (`__isoc23_*`, `fcntl64`, `qsort_r`, …).

**The fix:** supply a **musl-built** `radeonsi` driver — which is exactly what
**Alpine Linux** ships (`mesa-va-gallium`). Match the Alpine release to Plex's
bundled musl version, bundle the driver + its musl deps, and point Plex at them.

```dockerfile
# Plex bundles musl 1.2.2; qsort_r landed in musl 1.2.3, so use the last
# Alpine that ships musl 1.2.2 -> Alpine 3.15. (3.16+ = musl 1.2.4/1.2.5 = too new)
FROM alpine:3.15 AS vaapi
RUN apk add --no-cache mesa-va-gallium libva patchelf
# ... gather radeonsi_drv_video.so + its musl deps into /opt/vaapi, patchelf RPATH ...

FROM lscr.io/linuxserver/plex:latest
COPY --from=vaapi /opt/vaapi /opt/vaapi
ENV LIBVA_DRIVERS_PATH=/opt/vaapi/dri LIBVA_DRIVER_NAME=radeonsi
```

See the full [`Dockerfile`](./Dockerfile).

---

## The debugging journey (so you don't have to repeat it)

| Attempt | What happened | Why |
|---|---|---|
| Pass `/dev/dri` + install Ubuntu `mesa-va-drivers` | Software transcode, no error in normal logs | Driver silently fails to load |
| Inspect the failure | `__isoc23_strtoul: symbol not found` | `__isoc23_*` symbols are **glibc 2.38+** |
| Try jammy (Ubuntu 22.04, glibc 2.35) mesa | `fcntl64: symbol not found` | `fcntl64` is **glibc 2.28+** — Plex's libc is older |
| Inspect Plex's bundled libc | Found **`ld-musl-x86_64.so.1`** | **Plex Transcoder is musl, not glibc at all** |
| Try Alpine 3.20 (musl 1.2.5) mesa | `qsort_r: symbol not found` | `qsort_r` is **musl 1.2.3+**; Plex bundles **musl 1.2.2** |
| Alpine 3.15 (musl 1.2.2) mesa | ✅ `Initialised VAAPI connection: version 1.22` | musl version matches |

The decisive evidence that Plex is musl:

```console
$ docker exec plex bash -c '/usr/lib/plexmediaserver/lib/libc.so 2>&1 | head -3'
musl libc (x86_64)
Version 1.2.2
Dynamic Program Loader

$ docker exec plex bash -c 'cd /usr/lib/plexmediaserver; LD_LIBRARY_PATH=./lib ldd "Plex Transcoder"'
        libc.so => ./lib/libc.so (...)          # <-- musl, not glibc libc.so.6
        ...
```

### Key facts

- **`qsort_r` → musl 1.2.3**, **`__isoc23_*` → glibc 2.38**, **`fcntl64` → glibc 2.28.**
  Use these to identify which libc/version a "symbol not found" error implies.
- Plex's VA driver search path is **not** the system default, so the driver must
  be findable via `LIBVA_DRIVERS_PATH` and named via `LIBVA_DRIVER_NAME`.
- `patchelf --set-rpath /opt/vaapi` on the driver + its deps makes the dlopen'd
  driver resolve its siblings regardless of Plex's locked `LD_LIBRARY_PATH`.
- On **linuxserver/plex** (s6-overlay), set the `LIBVA_*` vars in the container
  **`environment:`** so `with-contenv` exports them into the PMS process *and the
  transcoder children it spawns* — a Dockerfile `ENV` alone proved unreliable here.

---

## Usage

### 1. Build & run

```yaml
# docker-compose.yml (see docker-compose.example.yml)
services:
  plex:
    build: .                      # this repo's Dockerfile
    container_name: plex
    network_mode: host
    devices:
      - /dev/dri:/dev/dri         # the GPU render node
    environment:
      - PUID=1000
      - PGID=1000
      - VERSION=docker
      - LIBVA_DRIVERS_PATH=/opt/vaapi/dri
      - LIBVA_DRIVER_NAME=radeonsi
    volumes:
      - ./config:/config
      - /path/to/media:/media
    # optional: keep transcode scratch in RAM
    tmpfs:
      - /transcode:size=8g
```

```console
docker compose up -d --build
```

Then in **Plex → Settings → Transcoder**, enable
**"Use hardware acceleration when available"** (requires **Plex Pass**).

### 2. Verify the driver loads

```console
docker exec plex bash -c '
  export LD_LIBRARY_PATH=/usr/lib/plexmediaserver/lib
  export LIBVA_DRIVERS_PATH=/opt/vaapi/dri LIBVA_DRIVER_NAME=radeonsi
  "/usr/lib/plexmediaserver/Plex Transcoder" -hide_banner -loglevel verbose \
    -init_hw_device vaapi=amd:/dev/dri/renderD128 -filter_hw_device amd \
    -f rawvideo -pix_fmt nv12 -video_size 1280x720 -r 30 -i /dev/zero \
    -t 5 -vf hwupload -c:v h264_vaapi -b:v 4M -f null -'
```

Success looks like:

```
libva: VA-API version 1.22.0
libva: Found init function __vaDriverInit_1_13
Initialised VAAPI connection: version 1.22
VAAPI driver: Mesa Gallium driver 21.2.6 for AMD Radeon Graphics (RENOIR ...).
Stream #0:0 -> #0:0 (rawvideo (native) -> h264 (h264_vaapi))
frame=  150 fps=... speed=6.2x
```

`h264 (h264_vaapi)` + `vaapi(progressive)` = the encode ran on the GPU.

> **Note on `gpu_busy_percent`:** AMD's media engine (VCN) is separate from the
> shader engine that `/sys/class/drm/renderD128/device/gpu_busy_percent` reports,
> so that counter stays low during pure encode. Trust the `vaapi` pixel format
> and the >1× encode speed, or use `radeontop` (shows the VCN/UVD/VCE blocks).

### 3. Verify Plex itself chose hardware

With debug logging on (Settings → enable, or `PUT /:/prefs?logDebug=1`), the
transcode decision log shows the chosen encoder:

```
Video=(... decision=transcode ... encoder=h264_vaapi ...)
```

`encoder=h264_vaapi` (not `libx264`) confirms Plex selected the GPU.

---

## Picking the right Alpine version for *your* Plex

Plex periodically bumps its bundled musl. Check yours and pick the matching
Alpine (so the driver doesn't reference a musl symbol your Plex lacks):

```console
docker exec plex /usr/lib/plexmediaserver/lib/libc.so 2>&1 | grep Version
```

| Plex bundled musl | Use Alpine | musl shipped |
|---|---|---|
| 1.2.2 | **3.15** | 1.2.2 |
| 1.2.3 | 3.16 / 3.17 | 1.2.3 |
| 1.2.4 | 3.18 / 3.19 | 1.2.4 |
| 1.2.5 | 3.20 | 1.2.5 |

Rule of thumb: **never use an Alpine newer than your Plex's musl**; the driver
will reference symbols (`qsort_r`, etc.) the older Plex musl doesn't export.
Older Alpine is fine as long as its mesa is new enough for your GPU
(Renoir/Cezanne/Vega need mesa ≥ ~20; Alpine 3.15 = mesa 21.2, fine).

---

## Other GPUs

- **Intel (QSV/VAAPI):** Alpine's `intel-media-driver` (`iHD`) or
  `libva-intel-driver` (`i965`) — set `LIBVA_DRIVER_NAME=iHD` (or `i965`).
- **Older AMD / other VAAPI:** still `mesa-va-gallium`, driver name `radeonsi`.

The musl-matching principle is identical for any of them.

---

## Bonus: passing an AMD iGPU into a VM first (Proxmox)

If your Docker host is itself a VM (e.g. Proxmox), the iGPU must be passed
through before the container can see `/dev/dri`:

```console
# host: find the iGPU and confirm it's in its own IOMMU group
lspci -nnk | grep -iA3 'VGA\|Display'
# pass it to the VM (pcie=1; the VM needs the amdgpu kernel module)
qm set <vmid> -hostpci0 0000:04:00.0,pcie=1
```

Inside the VM, `amdgpu` binds it and `/dev/dri/renderD128` appears; then map
`/dev/dri` into the container as shown above.

---

## Credits / license

Written up from a real migration. MIT licensed — see [LICENSE](./LICENSE).
Plex, Alpine, mesa, and linuxserver.io are trademarks of their respective owners;
this project is not affiliated with or endorsed by any of them.
