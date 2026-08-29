# Hardware video decode on Asahi Arch (Apple Silicon)

Two Arch packages that turn on the Apple Video Decoder (AVD) — H.264, HEVC and
VP9 hardware decode — on Apple Silicon Macs running Asahi Arch, Omarchy, or any
Arch Linux ARM install on this hardware.

| Package | What it does |
|---|---|
| [`avd-fw`](avd-fw/) | Builds and installs the AVD firmware, so the in-tree `apple-avd` driver can probe at all |
| [`libva-v4l2_request-avd`](libva-v4l2_request-avd/) | VA-API → V4L2-stateless translation, so ordinary apps can actually use the decoder |

## Why these exist

The `apple-avd` driver has been in the kernel for a while, and Asahi wrote a
clean MIT-licensed [replacement firmware](https://github.com/AsahiLinux/avd-fw)
for it rather than extracting Apple's. But that firmware was packaged nowhere —
not in `asahi-alarm`, not in `extra`, not in the AUR. So on a stock install the
driver tries to probe on every boot and fails:

```
avd 269080000.avd: Direct firmware load for apple/avd-fw-v2-t0.bin failed with error -2
avd 269080000.avd: probe with driver avd failed with error -2
```

The hardware was sitting idle for want of a PKGBUILD.

Firmware alone isn't enough, though. AVD is a *stateless* decoder, which almost
no desktop software speaks — ffmpeg's `v4l2m2m` decoders are stateful and will
never negotiate with it. The second package is the translation layer that
bridges VA-API to the V4L2 stateless API, which is what lets mpv, Chromium and
friends reach the hardware.

## Install

```sh
yay -S avd-fw libva-v4l2_request-avd
```

`avd-fw` needs no configuration — the driver picks the firmware up at boot.

libva can't auto-select the translation driver on Apple Silicon, because it
derives the driver name from the DRM render node, which points at `asahi`. Set
it explicitly, e.g. in `/etc/environment`:

```
LIBVA_DRIVER_NAME=v4l2_request
```

Then `mpv --hwdec=vaapi video.mp4`. Firefox additionally needs
`MOZ_DISABLE_RDD_SANDBOX=1`, because its RDD sandbox blocks the `/dev/video*`
and `/dev/media*` access the driver needs — that weakens Firefox's media
sandbox, so it's your call whether the tradeoff is worth it.

## Verification

Measured on a MacBook Pro 13" M1 (j293 / t8103), Omarchy 4.0.1, linux-asahi
7.1.6.

After installing `avd-fw` the driver binds without a reboot and a decoder node
appears:

```
$ echo 269080000.avd | sudo tee /sys/bus/platform/drivers/avd/bind
$ v4l2-ctl --list-devices
avd (platform:avd):
        /dev/video1
        /dev/media1

$ v4l2-ctl -d /dev/video1 --list-formats-out
        [0]: 'S265' (HEVC Parsed Slice Data, compressed)
        [1]: 'S264' (H.264 Parsed Slice Data, compressed)
        [2]: 'VP9F' (VP9 Frame, compressed)
```

Decoding a 90-frame 720p clip straight through the kernel API with GStreamer —
every frame accounted for, no errors:

| Codec | Element | Frames | Errors |
|---|---|---|---|
| H.264 | `v4l2slh264dec` | 90 / 90 | 0 |
| HEVC | `v4l2slh265dec` | 90 / 90 | 0 |
| VP9 | `v4l2slvp9dec` | 90 / 90 | 0 |

The H.264 pipeline ran in 0.095s for 3 seconds of video, roughly 950 fps.

With `libva-v4l2_request-avd` installed, mpv reaches the same hardware through
VA-API:

```
$ LIBVA_DRIVER_NAME=v4l2_request mpv --hwdec=vaapi test.mp4
libva-v4l2request: detected 1 Request API decoder
libva-v4l2request: decoding h264 via /dev/video1 [avd] (media /dev/media1)
libva-v4l2request: using CAPTURE format NV12 (1280x720)
Using hardware decoding (vaapi).
```

Confirmed the same way for `hevc` and `vp9`.

### Known gap: `--vo=dmabuf-wayland`

`--vo=gpu` (mpv's default) works, as above, and so does `--hwdec=vaapi-copy`.
But the fully zero-copy `--vo=dmabuf-wayland` path — frames handed straight to
the compositor without touching the GPU — fails to initialise and falls back to
software:

```
$ mpv --hwdec=vaapi --vo=dmabuf-wayland test.mp4
libva-v4l2request: detected 1 Request API decoder
[vd] Could not create device.
[vd] Using software decoding.
```

The driver is found and probes the decoder, so this is the dma-buf import
handshake rather than decode itself. Reproduced under Hyprland 0.56.1; not yet
isolated to the compositor, mpv, or the driver. Worth chasing — it is the
cheapest display path on a laptop, and the one that matters most for battery.

## Packaging notes

Things that are easy to get wrong, recorded so the next person doesn't have to
rediscover them.

**`avd-fw` is a bare-metal Cortex-M3 build.** `options=('!buildflags')` is
load-bearing — makepkg's aarch64 host `CFLAGS`/`LDFLAGS` would otherwise be
injected into firmware for a completely different CPU. `!strip` stops the host
`strip` running over raw firmware images.

Optimization is pinned to `-O2` to match upstream's Makefile. Meson's default
buildtype is `debug` (`-O0 -g`), so upstream's own CI artifact is unoptimized;
that looks like an oversight in the meson port rather than a decision. `-O2` is
safe here because `src/util.h` does `typedef volatile unsigned int u32`, so the
MMIO accessors can't be optimized away.

No `arm-none-eabi` toolchain is needed — clang cross-compiles to
`arm-none-eabi` natively, so makedepends is just `meson clang llvm`.

Meson and upstream's Makefile produce non-identical images, differing by two
bytes of `.text` alignment purely because they link the objects in a different
order. Both are valid: `.vectors` and `.rodata` are byte-identical at identical
addresses, and `vector_table` sits at 0x0 in both.

**`libva-v4l2_request-avd` tracks a fork.** It packages
[sofus13's fork](https://github.com/sofus13/libva-v4l2_request) at tag 1.3,
which is [megi's driver](https://xff.cz/git/libva-v4l2_request/) plus the
commits that make AVD work (HEVC entry point offsets, surface sizing, HEVC
slice params). It sets `provides`/`conflicts` on `libva-v4l2_request`, the
stock AUR package, which is the same driver without those fixes.

The codec set is decided by configure-time checks against the kernel uapi
headers, so `linux-api-headers` governs what gets built in — all six codecs
compile in against 7.2.

## Linting

`avd-fw` is namcap-clean.

`libva-v4l2_request-avd` reports four warnings, all of which were checked and
are being kept deliberately:

- `libc.so.6` / `ld-linux-aarch64.so.1` "uninstalled dependency" is a namcap
  soname-resolution quirk on Arch Linux ARM — official ALARM packages such as
  `a52dec` and `aalib` emit exactly the same warning.
- `glibc` "may not be needed" is the flip side of that same failed resolution;
  the library really does link `libc.so.6`.
- `libva` "may not be needed" is correct that nothing is linked, but the
  driver is dlopen()ed *by* libva and exports `__vaDriverInit_1_24`, so libva
  is a genuine runtime dependency with a version-pinned ABI.

`libdrm` was moved to `makedepends` on namcap's advice, which was right — it
is only used for `drm_fourcc.h` constants at compile time.

## Credits

Essentially all of the engineering here belongs to other people. These are
packages around their work.

- [Asahi Linux](https://asahilinux.org/) — the `apple-avd` driver and the
  replacement AVD firmware
- Ondrej Jirman (megi) — [`libva-v4l2_request`](https://xff.cz/git/libva-v4l2_request/)
- sofus13 — the AVD fixes on top of it
- anarsoul — maintains the stock `libva-v4l2_request` AUR package

## License

The PKGBUILDs in this repo are offered under the MIT license. The software they
build carries its own: `avd-fw` is MIT, `libva-v4l2_request` is GPL-3.0-or-later.
