# Decode correctness

Counting frames only proves the decoder produced *something*. H.264, HEVC and
VP9 all specify decoding as bit-exact: a conformant decoder must produce output
identical to the reference. So hardware output is compared against libavcodec's
software decode of the same file, per frame.

Method: decode twice to raw NV12 and compare with ffmpeg's `psnr` filter.
`inf` means bit-identical. Both control cases pass — software vs software is
`inf`, and hardware vs hardware is `inf`, so the reference is deterministic and
so is the hardware.

```sh
ffmpeg -i clip.mp4 -pix_fmt nv12 -f rawvideo sw.yuv
ffmpeg -hwaccel vaapi -hwaccel_device /dev/dri/renderD128 \
       -i clip.mp4 -pix_fmt nv12 -f rawvideo hw.yuv
ffmpeg -f rawvideo -pix_fmt nv12 -s 1280x720 -i sw.yuv \
       -f rawvideo -pix_fmt nv12 -s 1280x720 -i hw.yuv \
       -lavfi "[0:v][1:v]psnr" -f null -
```

## Results

| Stream | Luma | Chroma | Verdict |
|---|---|---|---|
| HEVC Main, 8-bit | `inf` | `inf` | bit-exact |
| VP9 Profile 0, 8-bit | `inf` | `inf` | bit-exact |
| H.264 Main, no weighted P | `inf` | `inf` | bit-exact |
| **H.264 Main, weighted P** | **~54 dB** | `inf` | **not bit-exact** |
| VP9 Profile 2, 10-bit | `inf` | ~61 dB | inconclusive, see below |

**HEVC and VP9 8-bit decode is correct.** So is H.264, as long as the stream
does not use weighted prediction.

## The H.264 weighted-prediction defect

Bisected with x264, 1280x720, profile Main, `-bf 3`, everything else held
constant:

| encoder settings | luma PSNR |
|---|---|
| `weightp=0 b-pyramid=none` | `inf` |
| `weightp=2 b-pyramid=none` | 53.95 dB |
| `weightp=0 b-pyramid=normal` | `inf` |
| `weightp=2 b-pyramid=normal` | 54.12 dB |

`weightp` alone decides it; B-pyramid is irrelevant. Narrowed further:
all-intra (`-g 1`) is exact, and I+P with no B-frames is exact, so the error
needs both inter prediction and weighting to appear. Chroma stays bit-exact in
every case, which points at the luma side of the `pred_weight_table` — carried
over the V4L2 stateless interface as `V4L2_CID_STATELESS_H264_PRED_WEIGHTS`.

The error is small — 54 dB is visually imperceptible — and it is deterministic
rather than drifting without bound. But it is non-conformant, and x264 enables
`weightp` by default, so ordinary encodes hit it.

Not yet root-caused to the shim, the kernel driver, or the firmware.

## VP9 10-bit

VP9 Profile 2 decodes with bit-exact luma but chroma differing by about 61 dB.
This is **not** confirmed as a defect: AVD emits NV12 only, so both sides of the
comparison were forced through a 10-to-8-bit conversion that may simply round
differently. A native 10-bit comparison (P010) is needed before calling this
anything.

HEVC Main10 is advertised by `vainfo` but remains **untested** — the libx265
build available here produces only 8-bit, so no Main10 stream could be
generated.

## ffmpeg `hwdownload` path

`-hwaccel_output_format vaapi -vf hwdownload,format=nv12` produces **zero
frames** while exiting 0, and segfaulted once (core dump captured, SIGSEGV in
`/usr/bin/ffmpeg`). Letting ffmpeg download implicitly — `-hwaccel vaapi`
without `-hwaccel_output_format` — works and yields all frames. Worth chasing;
the explicit-surface path is what most transcoding scripts use.

## Chromium cannot use this at all on Arch Linux ARM

Tested because browsers are the main reason anyone wants hardware decode. On
this system Chromium never loads the driver — and it cannot:

```console
$ readelf -d /usr/lib/chromium/chromium | grep NEEDED | grep -i va
    (nothing; libdrm.so.2 is there, libva is not)
$ strings /usr/lib/chromium/chromium | grep -c libva
0
```

**VA-API is compiled out of the `extra/chromium` aarch64 build** (Chromium
151.0.7922.137). Confirmed at runtime as well: with a video playing, no
Chromium process — including the GPU process — maps `libva.so`, let alone this
driver, and `Media.VideoDecoderFallback.H264` is recorded. No combination of
`--enable-features=VaapiVideoDecoder,AcceleratedVideoDecodeLinuxGL` changes
that, because the code is not in the binary.

So on Arch Linux ARM today the practical beneficiaries are mpv, ffmpeg and
GStreamer. Getting `use_vaapi=true` into the ALARM Chromium build is a separate
and probably higher-impact contribution than anything in this repo.

Firefox (`extra/firefox` 154.0.1) is not installed here and remains untested;
it is a separate question, and its RDD sandbox needs `MOZ_DISABLE_RDD_SANDBOX=1`
regardless.

## Not yet validated

Listed so nobody mistakes this page for a clean bill of health.

- **Firefox.** Untested; not installed here. (Chromium is now tested — see
  above.)
- **Real-world content.** Every clip above is synthetic `testsrc2`. No real
  camera footage, film grain, interlacing, or varied GOP structures.
- **4K.** Untested, though Asahi's own announcement mentions 4K H.264.
- **Seeking and non-linear playback**, which exercise decoder reset paths.
- **Concurrent decoders** — two players at once, contending for the device.
- **Long-running stability.** Nothing here ran longer than 60 seconds.
- **Installed-package behaviour.** All testing used `LIBVA_DRIVERS_PATH`
  against a build tree; the packaged `asahi_drv_video.so` alias and the
  `conflicts` with the stock `libva-v4l2_request` have not been exercised
  through a real `pacman -U`.
- **Reboot persistence.** `avd-fw` is expected to be picked up at boot, but
  this machine has not been rebooted since installing it.
- **Clean-chroot build.** Both packages build on a developer machine with a
  populated toolchain; neither has been built with `makechrootpkg`, which is
  what would catch a missing `makedepends`.
