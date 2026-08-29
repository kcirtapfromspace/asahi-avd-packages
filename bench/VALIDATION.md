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

**Root cause: AVD ignores `V4L2_CID_STATELESS_H264_PRED_WEIGHTS` entirely.**

The shim is not at fault. `codec_h264.c` populates the control from VA-API and
submits it correctly: the values arrive right, the struct layout matches
`v4l2_ctrl_h264_pred_weights`, the PPS flags gate it correctly, and AVD reports
`h264_decode_mode: 0 (Slice-Based)` so the control really is appended.

Demonstrated by instrumenting the shim with three env-gated variants and
comparing raw output:

| variant | luma PSNR vs software | vs "weights sent" |
|---|---|---|
| weights sent, as upstream does | 54.759314 | — |
| `PRED_WEIGHTS` control suppressed entirely | 54.759314 | **byte-identical** |
| all 32 L0 offsets sabotaged to `-64` | 54.759314 | **byte-identical** |

Feeding the hardware deliberately absurd weights changes nothing at all. It
never reads them. (Reproduced independently after the diagnostic build was
reverted, on a pristine tree, at the same 54.759314.)

### Why chroma escapes

Not a luma-specific hardware bug — an artefact of what the encoder emits.
Instrumenting every slice carrying a weight table showed one pattern, 25 times:

```
luma_nn=1 chroma_nn=0 ldenom=0 lw=[1,1] lo=[0,-1]
```

`chroma_nn=0` — x264's `weightp` weights **luma only**, leaving chroma weights
neutral. So when the table is dropped, only luma can differ. A stream that
weighted chroma would break there too.

The weighting here is `luma_log2_weight_denom=0, weight=1, offset=-1`. Per
H.264 §8.4.2.3.2, `logWD == 0` takes the `pred = Clip1(ref*w + o)` branch, so
correct output is `ref - 1` and AVD produces `ref`. A 1-LSB error confined to
macroblocks referencing the weighted entry lands at about 54 dB, which is what
is measured.

### It is content-dependent

An earlier framing here — "x264 enables `weightp` by default, so ordinary
encodes hit it" — was too strong. A fade clip carrying 29 non-neutral weight
tables decoded **bit-exact**. The trigger is not "the stream uses weighted
prediction" but "a macroblock actually references a weighted reference index".
Many `weightp` streams will decode correctly.

### Where the fix belongs

In the AVD kernel driver or the `avd-fw` firmware, whichever is meant to
consume the control — not in `libva-v4l2_request`, which already does the right
thing. Which of the two is unresolved: this machine has no kernel source tree
installed, and the `avd_h264.c` paths tried on the Asahi GitHub mirror 404.
`apple-avd.ko` does carry `v4l2_ctrl_h264_pred_weights` and `luma_weight` in
its BTF type data, but that only proves the struct is in its type universe, not
that anything reads it.

Next step is to find `avd_h264.c` in the Asahi tree and check whether the
request-completion path fetches the control and marshals it into the firmware
command. If it does, the defect is in the firmware.

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
