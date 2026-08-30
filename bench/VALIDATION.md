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

### Root cause and fix

**Fixed.** See [`patches/0001-avd-h264-weighted-pred.patch`](../patches/).

`stream_weights()` applied `weighted_bipred_idc` unconditionally, setting the
implicit-bipred header flag and ORing `LUMA(5)|CHROMA(5)` over the real
denominators. But `weighted_bipred_idc` governs **B slices only**; P slices take
their weighting from `weighted_pred_flag` and carry an explicit
`pred_weight_table`. On a P slice in a stream whose PPS also enables implicit
bi-prediction for B slices, the driver told the hardware to ignore the very
table it then sent, and advertised denominator 5 for weights computed at
denominator 0. The original code carried a `TODO` questioning exactly those two
checks.

Everything else was cleared first: the shim populates the control correctly, the
driver marshals it correctly (instrumentation showed 22 luma weight/offset pairs
emitted with correct values across 50 slices), and the firmware is not in this
path at all — `push()` is a `writel()` into a hardware instruction slot.

Gating both on `slice_type == V4L2_H264_SLICE_TYPE_B`:

| stream | before | after |
|---|---|---|
| H.264 weighted P | y:54.759314 | **y:inf** |
| H.264 no weighted P | y:inf | y:inf |

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

It is worse than a missing build flag. ALARM's PKGBUILD sets
`use_vaapi=false` **and** `use_v4l2_codec=true` — a deliberate choice, noted in
the file header as "disable vaapi, enable v4l2". The V4L2 stateless stack really
is compiled in (`V4L2StatelessVideoDecoderBackend`,
`V4L2VideoDecoderBackendStateless` are all present in the binary), and V4L2
stateless is exactly what AVD speaks. But no Chromium process ever opens
`/dev/video*`, with or without
`--enable-features=AcceleratedVideoDecodeLinuxGL,AcceleratedVideoDecodeLinuxZeroCopyGL`
and `--ignore-gpu-blocklist`. The path appears to be reachable only on ChromeOS.

So Chromium on Arch Linux ARM currently has no working hardware decode route at
all: VA-API compiled out, V4L2 compiled in but unreachable.

Firefox (`extra/firefox` 154.0.1) is not installed here and remains untested;
it is a separate question, and its RDD sandbox needs `MOZ_DISABLE_RDD_SANDBOX=1`
regardless.

## Resolution, frame size, seeking and concurrency

**4K works** — but only for HEVC unconditionally. The H.264 failure tracks
**compressed frame size**, not resolution:

| clip | avg frame | decoder errors |
|---|---|---|
| 4K HEVC Main, 15 Mbps | — | 0 |
| 4K H.264 Main, 4 Mbps | 18.0 KiB | 0 |
| 4K H.264 Main, 8 Mbps | 32.4 KiB | 5 |
| 4K H.264 Main, 20 Mbps | 62.7 KiB | 4 |

That matches 1080p, which is clean at 4 Mbps and starts erroring at 8 Mbps, and
puts the threshold somewhere around 20–30 KiB per compressed frame regardless of
resolution.

The mechanism is a **2 second poll timeout** waiting for an OUTPUT buffer to be
dequeued (`decode.c:350`), i.e. a decode that never completes rather than one
that is merely slow. The shim's OUTPUT buffer growth path is **not** involved —
instrumented counts over a failing run were `grew=0, overflow=0, failed_wait=1`,
so the bitstream buffer is never outgrown. Failures are intermittent (1–11 per
run on the same clip). Root cause not established; it is below the shim, in the
driver or the hardware, and is a separate defect from the High-profile failure.

**Seeking and concurrency are clean.** Loop/seek playback exercising the decoder
reset path reported zero errors, and two simultaneous decoders on the one device
— an H.264 and an HEVC stream at once — both ran with hardware decode and no
errors.

## Installed-package behaviour

Validated against real `pacman -U` installs rather than a build tree, which is
what every earlier test used.

`avd-fw` reinstalls as `Architecture: any` with the firmware at `0644`, and the
decoder stays healthy across the reinstall.

The shim installs with **no file conflicts**, and then:

```console
$ env -u LIBVA_DRIVERS_PATH -u LIBVA_DRIVER_NAME vainfo
libva-v4l2request: detected 1 Request API decoder
vainfo: Driver version: v4l2-request
      VAProfileH264ConstrainedBaseline / Main / High : VAEntrypointVLD
      VAProfileHEVCMain / HEVCMain10                 : VAEntrypointVLD
      VAProfileVP9Profile0 / VP9Profile2             : VAEntrypointVLD
```

**No environment variables at all** — the packaged `asahi_drv_video.so` alias is
picked up from `/usr/lib/dri`. Run before the shim was installed, the same
command fails with `vaInitialize failed with error code -1`, which confirms
there is no accidental fallback making things appear to work when the package is
absent.

One defect found and fixed by doing this: the `.install` file had been edited
after the last package build, so the shipped package still printed the old
message telling users to set `LIBVA_DRIVER_NAME`. The functional artifact was
correct; only the guidance was stale.

## Real-world content

Synthetic `testsrc2` is not evidence about real video, so the same checks were
run on actual encodes (Big Buck Bunny, Jellyfish; 1080p, real motion and grain,
varied GOP), through the **installed** package with no environment variables:

| Stream | Result | Correctness |
|---|---|---|
| H.264 High, 4 Mbps | **fails**, falls back to software (38 errors) | — |
| H.264 High, 24 Mbps | **fails**, falls back to software (64 errors) | — |
| HEVC Main | clean | **bit-exact** |
| VP9 Profile 0 | clean | **bit-exact** |

Both real H.264 clips are **High profile**, because that is what real-world
H.264 uses. So in practice H.264 hardware decode is unusable on this stack
today, while HEVC and VP9 work and are bit-exact on real footage.

## 10-bit

**VP9 Profile 2 (10-bit) is bit-exact.** The earlier inconclusive result was an
artefact of the test, not a defect: both sides had been forced through an 8-bit
NV12 conversion that rounds differently. Compared natively at P010 it is
`y:inf u:inf v:inf` with zero decode errors.

Worth knowing: `v4l2-ctl --list-formats` reports NV12 only, but that queries an
idle device before codec controls are set, and the driver configures the CAPTURE
queue lazily. For a 10-bit stream the shim negotiates **P010**.

One loose end: decoding the 10-bit clip unconstrained yields 116 frames from
hardware against 120 from software, with no errors reported. Limited to the same
count the output is identical, so this looks like frames dropped at end-of-stream
flush rather than corruption — but it has not been chased down.

**HEVC Main10 remains untested.** Neither the local x265 nor Arch Linux ARM's is
built with 10-bit support, so no Main10 stream could be produced, and no ready
sample was found.

## Clean-environment build

`makechrootpkg` needs root, so the equivalent was done in a pristine Arch Linux
ARM container holding only base-devel (170 packages). Both packages build with
`makepkg -s` from **their declared dependencies alone**, producing
`avd-fw-0.1-1-any.pkg.tar.xz` and
`libva-v4l2_request-avd-1.3-1-aarch64.pkg.tar.xz`. No undeclared `makedepends`.

## Robustness

Deliberate attempts to break it, all through the installed package.

**Resolutions**, HEVC, including dimensions that are not multiples of 16 — every
one decoded with hardware and was bit-exact:

| resolution | errors | correctness |
|---|---|---|
| 320x240 | 0 | `y:inf` |
| 640x360 | 0 | `y:inf` |
| 1282x722 | 0 | `y:inf` |
| 1920x1080 | 0 | `y:inf` |
| 1918x1078 | 0 | `y:inf` |

**Malformed input** is handled gracefully rather than hanging or wedging the
device. A stream truncated to half its length, and a stream with 400 bytes
flipped at random through the back three quarters, both terminated cleanly — and
a normal clip decoded with hardware immediately afterwards, so the decoder
recovers rather than needing a rebind.

**Concurrency**: four simultaneous decoders across mixed codecs (two HEVC, two
VP9) all ran on hardware with zero errors, on top of the earlier two-stream
test.

## Large H.264 frames stalled the decoder — FIXED

> Re-verified against upstream `asahi-wip` at ccce11ae after PR #581 landed:
> this fix is still required there, 0/10 before and 10/10 after, and was
> submitted as [AsahiLinux/linux#585](https://github.com/AsahiLinux/linux/pull/585).
> The other two H.264 fixes documented here apply to the shipped `linux-asahi`
> 7.1.6 but are redundant on `asahi-wip` — see [`patches/README.md`](../patches/README.md).

See [`patches/0003-avd-hw-t8103-vp-insn-fifo-mask.patch`](../patches/).

`t8103_configure_stream()` programmed the VP instruction FIFO limit to `0x100000`
(1 MiB) while `fifo_size()` allocates 12 MiB. Frames whose instruction stream
exceeded 1 MiB wrapped inside the larger buffer and the hardware never signalled
completion. t8112 and t8122 program `0`; only t8103 carried the stale value.

Swept as a module parameter, 10 runs per value per clip:

| fifo_mask | small frame | large frame | real-world |
|---|---|---|---|
| `0x100000` (stock) | 10/10 | **0/10** | **1/10** |
| `0` | 10/10 | 10/10 | 10/10 |
| `0xc00000` | 10/10 | 10/10 | 10/10 |

With the fix, real-world H.264 is bit-exact against libavcodec, as are the big
keyframe, small control, weighted-prediction, HEVC and VP9 clips.

Found by exploiting a codec asymmetry: a real 1080p VP9 clip with a 127 KiB
keyframe decoded cleanly while H.264 failed 20/20 at 140 KiB, which ruled out
shared buffers and pointed at per-codec register programming. Five hypotheses
were falsified by measurement before it: the 8x8 transform path, `pps_tile[0]`
sizing, the multi-slice `readl_poll_timeout`, a lost mailbox interrupt under
`IRQF_ONESHOT`, and the H.264-only slice-offset scan.

### Latent bug noticed in passing

H.264 has no `data_byte_offset` field (HEVC does), so `stream_slice()` re-derives
the offset by scanning for emulation-prevention bytes with an unbounded
`data[off]` read. Measured correct on every clip tested, so it is not this
defect, but it is an out-of-bounds read worth reporting separately.

## Not yet validated

Listed so nobody mistakes this page for a clean bill of health.

- **Firefox.** Untested; not installed here. (Chromium is now tested — see
  above.)
- **Long-running stability.** Nothing here ran longer than 60 seconds.
- **Reboot persistence.** `avd-fw` is expected to be picked up at boot, but
  this machine has not been rebooted since installing it.
