# Hardware video decode on Asahi Arch (Apple Silicon)

Two Arch packages that turn on the Apple Video Decoder (AVD) — H.264, HEVC and
VP9 hardware decode — on Apple Silicon Macs running Asahi Arch, Omarchy, or any
Arch Linux ARM install on this hardware.

| Package | What it does |
|---|---|
| [`avd-fw`](avd-fw/) | Builds and installs the AVD firmware, so the in-tree `apple-avd` driver can probe at all |
| [`libva-v4l2_request-avd`](libva-v4l2_request-avd/) | VA-API → V4L2-stateless translation, so ordinary applications can use the decoder |

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

Firmware alone isn't enough. AVD is a *stateless* decoder, which almost no
desktop software speaks — ffmpeg's `v4l2m2m` decoders are stateful and will
never negotiate with it. The second package bridges VA-API to the V4L2
stateless API, which is what lets mpv, Chromium and friends reach the hardware.

## Install

```sh
yay -S avd-fw libva-v4l2_request-avd
```

**No configuration is required.** `avd-fw` is picked up by the driver at boot.

libva selects a driver by the DRM driver name of the render node, which on
Apple Silicon is `asahi`, so it looks for `asahi_drv_video.so`. Nothing else
ships that name, so `libva-v4l2_request-avd` installs itself under it as well
and VA-API applications find the decoder on their own:

```console
$ env -u LIBVA_DRIVER_NAME vainfo
vainfo: Driver version: v4l2-request
$ mpv --hwdec=vaapi video.mp4
Using hardware decoding (vaapi).
```

If something does not pick it up, select it explicitly with
`LIBVA_DRIVER_NAME=v4l2_request`. Firefox additionally needs
`MOZ_DISABLE_RDD_SANDBOX=1`, because its RDD sandbox blocks the `/dev/video*`
and `/dev/media*` access the driver needs — that weakens Firefox's media
sandbox, so it's your call whether the tradeoff is worth it.

## What works

Measured on a MacBook Pro 13" M1 (j293 / t8103), Omarchy 4.0.1, linux-asahi
7.1.6. `vainfo` advertises:

```
VAProfileH264ConstrainedBaseline / Main / High : VAEntrypointVLD
VAProfileHEVCMain / HEVCMain10                 : VAEntrypointVLD
VAProfileVP9Profile0 / VP9Profile2             : VAEntrypointVLD
```

Decode only — there is no encode entrypoint, and no AV1. Neither is a packaging
gap: AV1 needs AVD v5 silicon (M3 and later), and the video *encoder* is a
separate block that upstream lists as not currently being worked on.

Playing 720p clips through mpv over VA-API, counting decoder errors across the
whole file rather than sampling the first lines of output:

| Codec | Result |
|---|---|
| H.264 Main | works |
| **H.264 High** | **fails** — falls back to software |
| HEVC Main | works |
| VP9 Profile 0 | works |

### The H.264 High profile problem

This is the significant caveat, and it is worth stating plainly: **High is the
profile essentially all real-world H.264 uses.** Bisected against Main at
matched frame sizes, so it is the profile and not the bitrate or the
resolution:

| clip | profile | avg frame | decoder errors |
|---|---|---|---|
| `main_small` | Main | 12.4 KiB | 0 |
| `high_small` | High | 12.6 KiB | 105 |
| `main_big` | Main | 14.2 KiB | 0 |
| `high_big` | High | 14.5 KiB | 75 |

The VA-API path reports `failed waiting on OUTPUT buffer` and mpv falls back to
software. GStreamer's `v4l2slh264dec` fails on the same content earlier, in
`gst_v4l2_codec_h264_dec_ensure_bitstream`, with `Not enough memory to decode
H264 stream`. Both paths break on High and both work on Main, so this is below
the packages in this repo — in the shim, the kernel driver, or the firmware.
Not yet root-caused.

At 1080p Main the decoder is clean at 2 and 4 Mbps but starts reporting
occasional `failed waiting on OUTPUT buffer` at 8 Mbps, which may be the same
underlying problem showing up as a function of compressed frame size.

HEVC and VP9 have no equivalent failure, and between them cover a large share
of modern streaming video.

### H.264 weighted prediction is not bit-exact

H.264 decoding is specified to be bit-exact. Comparing hardware output against
libavcodec frame by frame, HEVC and VP9 pass exactly — and so does H.264, until
the stream uses weighted prediction, at which point luma diverges by about
54 dB while chroma stays exact:

| encoder settings (x264, profile Main, -bf 3) | luma PSNR |
|---|---|
| `weightp=0` | `inf` (bit-exact) |
| `weightp=2` | 53.95 dB |

Root-caused: **AVD ignores `V4L2_CID_STATELESS_H264_PRED_WEIGHTS` entirely.**
Suppressing the control, or filling it with deliberately absurd values, produces
byte-identical output to sending it correctly — the hardware never reads it. The
shim submits it properly, so the fix belongs in the kernel driver or the
firmware.

Chroma escapes only because x264's `weightp` weights luma and leaves chroma
neutral. The effect is content-dependent: it needs a macroblock that actually
references a weighted reference index, so many `weightp` streams still decode
bit-exact. The error is 1 LSB, visually imperceptible, deterministic — but
non-conformant. Full method and proof in
[`bench/VALIDATION.md`](bench/VALIDATION.md).

### Known gap: `--vo=dmabuf-wayland`

`--vo=gpu` (mpv's default) and `--hwdec=vaapi-copy` both work. The fully
zero-copy `--vo=dmabuf-wayland` path — frames handed to the compositor without
touching the GPU — fails to initialise and falls back to software:

```
libva-v4l2request: detected 1 Request API decoder
[vd] Could not create device.
[vd] Using software decoding.
```

The driver is found and probes the decoder, so this is the dma-buf import
handshake rather than decode. Reproduced under Hyprland 0.56.1; not isolated to
the compositor, mpv, or the driver.

## Does it actually save battery?

Measured rather than asserted. Full method, raw numbers and caveats in
[`bench/RESULTS.md`](bench/RESULTS.md); the harness is
[`bench/measure.sh`](bench/measure.sh) and verifies which decoder actually ran
before scoring a result.

Playing 60 s of H.264 Main at realtime, software versus hardware decode:

| | 720p | 1080p |
|---|---|---|
| CPU time, software | 37.90 s | 45.39 s |
| CPU time, hardware | 6.13 s | 7.27 s |
| **CPU time reduction** | **84%** | **84%** |
| **Total system power saved** | **0.22 W** | **0.21 W** |
| …as a share of system draw | 2.9% | 2.7% |

**The CPU win is large: about 84% less decode work.** The battery win is real
but modest — roughly 0.2 W off a machine drawing about 7.8 W, which on this
laptop's 58.2 Wh battery is ten to fifteen minutes of extra video playback per
charge, and it does not grow from 720p to 1080p.

On an M1 the display, GPU and baseline SoC draw dominate, and the efficiency
cores decode H.264 cheaply enough that offloading it frees about a fifth of the
marginal playback power rather than most of it. The freed CPU is still worth
having — headroom for everything else running during playback, less thermal
pressure — and would matter more at 4K or while multitasking, neither of which
is measured here.

## Verification

After installing `avd-fw` the driver binds without a reboot and a decoder node
appears:

```console
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

Decoding a 90-frame 720p clip straight through the kernel API with GStreamer,
every frame accounted for:

| Codec | Element | Frames | Errors |
|---|---|---|---|
| H.264 Main | `v4l2slh264dec` | 90 / 90 | 0 |
| HEVC | `v4l2slh265dec` | 90 / 90 | 0 |
| VP9 | `v4l2slvp9dec` | 90 / 90 | 0 |

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
safe because `src/util.h` does `typedef volatile unsigned int u32`, so the MMIO
accessors can't be optimized away.

No `arm-none-eabi` toolchain is needed — clang cross-compiles to
`arm-none-eabi` natively, so makedepends is just `meson clang llvm`.

It is an `arch=('any')` package: the images are raw Cortex-M3 firmware,
identical whatever host builds them, as with `linux-firmware`.

Meson and upstream's Makefile produce non-identical images, differing by two
bytes of `.text` alignment purely because they link the objects in a different
order. Both are valid: `.vectors` and `.rodata` are byte-identical at identical
addresses, and `vector_table` sits at 0x0 in both.

**`libva-v4l2_request-avd` tracks a fork.** It packages
[sofus13's fork](https://github.com/sofus13/libva-v4l2_request) at tag 1.3,
which is [megi's driver](https://xff.cz/git/libva-v4l2_request/) plus the
commits that make AVD work. It sets `provides`/`conflicts` on
`libva-v4l2_request`, the stock AUR package, which is the same driver without
them.

The driver links only libc and is `dlopen()`ed by libva, exporting the
versioned `__vaDriverInit_1_24`, so `libva` belongs in `depends` even though
namcap reports it as possibly unneeded — and a libva ABI bump requires a
rebuild. `libdrm` is `makedepends` only, for `drm_fourcc.h` constants.

The `asahi_drv_video.so` alias is what removes the need for
`LIBVA_DRIVER_NAME`. If mesa ever ships its own `asahi_drv_video.so` this will
collide, and pacman will say so at install time.

## Linting

`avd-fw` is namcap-clean.

`libva-v4l2_request-avd` reports four warnings, all checked and kept
deliberately: `libc.so.6` / `ld-linux-aarch64.so.1` "uninstalled dependency"
and `glibc` "may not be needed" are a namcap soname-resolution quirk on Arch
Linux ARM — official ALARM packages such as `a52dec` and `aalib` emit exactly
the same warnings. `libva` "may not be needed" is correct that nothing is
linked, but wrong about the conclusion, for the dlopen reason above.

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
