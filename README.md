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
# Alpine that ships musl 1.2.2 -> Alpine 3.15. (3.16+ = musl 1.2.3..1.2.6 = too new)
ARG ALPINE_VERSION=3.15
FROM alpine:${ALPINE_VERSION} AS vaapi
RUN apk add --no-cache mesa-va-gallium libva patchelf
# ... gather radeonsi_drv_video.so + its musl deps into /opt/vaapi, patchelf RPATH ...

ARG PLEX_VERSION=1.43.4.10903-e5521bd8c-ls325   # pinned linuxserver/plex tag
FROM lscr.io/linuxserver/plex:${PLEX_VERSION}
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
    build:
      context: .                  # this repo's Dockerfile
      args:
        # linuxserver/plex base tag (default in the Dockerfile; bump to update)
        PLEX_VERSION: "1.43.4.10903-e5521bd8c-ls325"
        # ALPINE_VERSION: "3.15"  # musl driver source, see "Picking the right Alpine"
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

Or without compose:

```console
docker build -t plex-amd .                                             # pinned default
docker build --build-arg PLEX_VERSION=1.43.4.10903-e5521bd8c-ls325 -t plex-amd .
```

The base image is **pinned** to a specific `lscr.io/linuxserver/plex` tag via the
`PLEX_VERSION` build arg (default in the `Dockerfile`), so rebuilds are
reproducible. Pick any tag from
[linuxserver/docker-plex releases](https://github.com/linuxserver/docker-plex/releases)
-- the `<plex-version>-ls<N>` form pins both PMS and the linuxserver layer;
`version-<plex-version>` tracks the newest linuxserver build of that PMS
release; `latest` restores the old floating behaviour.

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
| 1.2.2 | **3.15** (default) | 1.2.2 |
| 1.2.3 | 3.16 / 3.17 | 1.2.3 |
| 1.2.4 | 3.18 / 3.19 | 1.2.4 |
| 1.2.5 | 3.20 / 3.21 / 3.22 / 3.23 | 1.2.5 |
| 1.2.6 | 3.24 | 1.2.6 |

The Alpine release is a build arg, so you don't need to edit the `Dockerfile`:

```console
docker build --build-arg ALPINE_VERSION=3.20 -t plex-amd .
# or in compose:  build: { context: ., args: { ALPINE_VERSION: "3.20" } }
```

Rule of thumb: **never use an Alpine newer than your Plex's musl**; the driver
will reference symbols (`qsort_r`, etc.) the older Plex musl doesn't export.
Older Alpine is fine as long as its mesa is new enough for your GPU
(Renoir/Cezanne/Vega need mesa ≥ ~20; Alpine 3.15 = mesa 21.2, fine).

### Why Alpine 3.15 (and why not newer)

Alpine 3.15 reached end-of-life in November 2023, which naturally raises the
question of bumping it. As of **Plex Media Server 1.43.4** (September 2026) the
answer is still *no*, and here is the evidence (the `radeonsi` driver from every
release's `mesa-va-gallium` was checked against the symbols exported by the
`ld-musl-x86_64.so.1` that PMS 1.43.4 bundles):

| Alpine | musl | mesa | driver file | libc symbols missing from Plex's musl 1.2.2 |
|---|---|---|---|---|
| 3.15 | 1.2.2 | 21.2.6 | `/usr/lib/dri/radeonsi_drv_video.so` | **none** |
| 3.16 | 1.2.3 | 21.3.9 | `/usr/lib/dri/radeonsi_drv_video.so` | `qsort_r` |
| 3.17 | 1.2.3 | 22.2.5 | `/usr/lib/dri/radeonsi_drv_video.so` | `qsort_r` |
| 3.18 | 1.2.4 | 23.0.4 | `/usr/lib/dri/radeonsi_drv_video.so` | `qsort_r` |
| 3.19 | 1.2.4 | 23.3.6 | symlink → `dri/libgallium_drv_video.so` | `qsort_r` |
| 3.20 | 1.2.5 | 24.0.9 | symlink → `dri/libgallium_drv_video.so` | `qsort_r` |
| 3.21 | 1.2.5 | 24.2.8 | symlink → `/usr/lib/libgallium-24.2.8.so` (pkg `mesa`) | `qsort_r` |
| 3.22 | 1.2.5 | 25.1.9 | symlink → `/usr/lib/libgallium-25.1.9.so` (pkg `mesa`) | `qsort_r` |
| 3.24 | 1.2.6 | 26.1.6 | symlink → `/usr/lib/libgallium-26.1.6.so` (pkg `mesa`) | `qsort_r` |

So every supported Alpine produces a driver that dies with
`Error relocating .../radeonsi_drv_video.so: qsort_r: symbol not found` under
Plex's loader. Mitigating factors for staying on 3.15:

- It is a **build stage only**. Nothing from Alpine runs in the final image; the
  only things copied out are the driver and its `.so` dependencies, which are
  dlopen'd by Plex's own musl. The EOL status affects the apk toolchain in that
  stage, not the shipped container.
- The `v3.15` package mirror (`dl-cdn.alpinelinux.org/alpine/v3.15`) is still
  served, so the build keeps working.
- `mesa-va-gallium` still ships `radeonsi_drv_video.so` on every newer release
  (from 3.21 as a symlink into the `mesa` package); the `Dockerfile` copies it
  with `cp -aL`, so **bumping `ALPINE_VERSION` needs no other change** the day
  Plex's bundled musl catches up. Check with:

  ```console
  docker exec plex /usr/lib/plexmediaserver/lib/libc.so 2>&1 | grep Version
  ```

---

## Keeping Plex updated (important with a custom image)

Because this is a **locally-built** image, **Watchtower / auto-updaters can't
update it** — there's nothing to pull from a registry. Plan for two independent
update tracks:

**1. Plex Media Server itself** — let linuxserver self-update it. Set in your
compose `environment:`:

```yaml
- VERSION=latest      # newest STABLE Plex, downloaded on each container start
# - VERSION=plexpass  # newest BETA (Plex Pass) instead
# - VERSION=docker    # pinned to whatever's baked in the image (no self-update)
```

With `latest`/`plexpass`, a `docker restart` (or recreate) pulls the newest PMS.
**The VAAPI driver is unaffected** — it lives in `/opt/vaapi`, decoupled from PMS,
and is referenced only by env var.

**2. The base image + the VAAPI driver** — rebuild occasionally (e.g. monthly, or
after a linuxserver release) to refresh the OS layer and the Alpine musl driver.
Because the base tag is pinned, bump `PLEX_VERSION` to the new
[linuxserver tag](https://github.com/linuxserver/docker-plex/releases) first
(in the `Dockerfile` default, or in your compose `build.args`), then:

```console
docker compose build --pull plex && docker compose up -d plex
```

The included [`update-plex.sh`](./update-plex.sh) does exactly this and then
re-runs the hardware-encode self-test, warning you if a Plex musl bump ever needs
a different Alpine pin:

```console
./update-plex.sh                      # defaults: service=plex container=plex
./update-plex.sh plex plex-v2         # custom compose service / container name
PLEX_VERSION=1.43.4.10903-e5521bd8c-ls325 ./update-plex.sh   # rebuild on a newer base tag
```

### Will a Plex update break HW transcoding?

Almost certainly not — and the design is deliberately safe. The driver is built on
musl **1.2.2** (the *floor*). If Plex bumps its bundled musl *upward* (1.2.3+), the
1.2.2-built driver still loads, because newer musl is a **superset** of older
symbols. The only break direction is a driver built on musl *newer* than Plex's —
which only happens if you bump the Alpine base too far ahead. So: **leave the
`ALPINE_VERSION` pin alone**, and re-check only if a `--pull` rebuild ever changes
Plex's musl. Verify after any update:

```console
docker exec plex /usr/lib/plexmediaserver/lib/libc.so 2>&1 | grep Version
```

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
