# Kernel patches

**Which of these you need depends on your kernel.** They were developed against
the `asahi` branch, which is what `linux-asahi` 7.1.6 ships. While that was
happening, upstream's `asahi-wip` branch moved: [PR #581][581] landed a batch of
AVD buffer-sizing work on 2026-08-29.

Re-tested against `asahi-wip` at ccce11ae, each fix in isolation:

| fix | on shipped `linux-asahi` 7.1.6 | on current `asahi-wip` |
|---|---|---|
| `0001` weighted prediction | needed, verified | **already fixed upstream** by #581 |
| `0002` High profile scaling | needed, verified | **no longer changes anything** |
| `0003` t8103 FIFO mask | needed, verified | **still needed** — submitted as [#585][585] |

So on a current development kernel only `0003` applies. On the kernel Arch Linux
ARM actually ships today, all three do.

[581]: https://github.com/AsahiLinux/linux/pull/581
[585]: https://github.com/AsahiLinux/linux/pull/585

## Credit where it is due

The weighted-prediction bug was found independently here and upstream. **Their
fix is better than mine**: it gates on `!pred_weight_req` — "we are not sending
an explicit weight table" — rather than on `slice_type == B`, which is more
direct and covers cases mine would not.

The High-profile fix is the one I got least right. It resolved a real failure on
`asahi`, but measured in isolation on `asahi-wip` it changes nothing: the
buffer-sizing work in #581 had already removed that stall, so the mechanism I
described was not the operative cause on their tree. It is kept here because it
is still needed on the shipped kernel, not because the root cause writeup below
is the last word.

## `0001-avd-h264-weighted-pred.patch`

Fixes H.264 weighted prediction on the Apple Video Decoder. Against
`AsahiLinux/linux` branch `asahi`,
`drivers/media/platform/apple/avd/avd-h264.c`.

### The bug

Streams using weighted P prediction decoded with luma differing from the
reference — about 54 dB PSNR, chroma bit-exact. H.264 decoding is specified to
be bit-exact, so this is non-conformant. x264 enables `weightp` by default.

### Root cause

`stream_weights()` applied `weighted_bipred_idc` unconditionally:

```c
AVD_OP_WEIGHTS_HDR_FLAG1(pps->weighted_bipred_idc == 2) | ...
(pps->weighted_bipred_idc == 2 ? DEFAULT_WEIGHT_DENOM : 0)
```

`weighted_bipred_idc` governs **B slices only** — it selects implicit weighted
bi-prediction, whose weights come from POC distance. P slices take their
weighting from `weighted_pred_flag` and carry an explicit `pred_weight_table`.

On a P slice in a stream whose PPS also enables implicit bi-prediction for its
B slices, the driver therefore both set the implicit-bipred flag — telling the
hardware to disregard the explicit table it was about to send — and ORed
`LUMA(5)|CHROMA(5)` over the real denominators, advertising a denominator of 5
for weights computed at `luma_log2_weight_denom = 0`.

The original code carried a `TODO` questioning exactly these two checks.

### How it was found

Instrumenting the driver showed the weights *were* being emitted correctly:

```
PWTRACE hdr pred_weight=1 bipred_idc=2 ldenom=0 cdenom=0
PWTRACE EMIT luma list=0 idx=1 w=1 o=-1
```

50 slices reached `stream_weights()`, 27 correctly early-returned, and 22 luma
weight/offset pairs were emitted with correct values. That ruled out the
userspace shim, the control plumbing and the firmware (the command stream is a
`writel()` into a hardware instruction slot, so `avd-fw` is not in this path),
and pointed at the header flags — the one thing the hardware would read *before*
the weights themselves.

### Verification

Decoded output compared per-frame against libavcodec with ffmpeg's `psnr`
filter. `inf` means bit-identical.

| stream | before | after |
|---|---|---|
| H.264 weighted P | y:54.759314 u:inf v:inf | **y:inf u:inf v:inf** |
| H.264 no weighted P | y:inf u:inf v:inf | y:inf u:inf v:inf |

Controls: software-vs-software and hardware-vs-hardware are both `inf`, so the
reference and the hardware are each deterministic.

The change is confined to `stream_weights()`, which is H.264-only; HEVC and VP9
do not reach this code and were already bit-exact.

## `0002-avd-h264-high-profile.patch`

Fixes H.264 High profile, which is what essentially all real-world H.264 uses.

`stream_hdr()` advertises `transform_8x8_mode` to the hardware, which then
expects the scaling section — including the 8x8 lists — to follow. But that
section was gated on `pic_scaling_matrix_present_flag`, which says only whether
the stream *signalled* matrices, not whether the hardware needs them. A stream
with `transform_8x8_mode_flag=1` and `pic_scaling_matrix_present_flag=0` — x264's
High profile default — got an end-of-section marker instead of data, and the
hardware stalled waiting for what never arrived.

`stream_scaling()` already contained `default_8x8_intra`/`default_8x8_inter`
fallback tables; they were simply unreachable. The scaling matrix control carries
the effective (flat) lists in this case, so streaming it is correct.

Verified bit-exact at 720p and 1080p, 30 and 60 fps, with Main, weighted-Main,
HEVC and VP9 unregressed.

## `0003-avd-hw-t8103-vp-insn-fifo-mask.patch`

Fixes large-frame H.264 decode on M1 (t8103). This is the one that makes H.264
usable on real video.

### The bug

Any H.264 frame whose coded size was large enough — every real 1080p keyframe —
made the hardware start and never finish, with the watchdog firing after two
seconds (`Frame processing timed out!`) and zero frames produced. HEVC and VP9
were unaffected even at larger frame sizes.

### Root cause

`t8103_configure_stream()` programs the VP instruction FIFO limit to `0x100000`
(1 MiB), while `fifo_size()` allocates `0x100000 * 12` (12 MiB). The limit does
not describe the buffer it points at. A frame whose instruction stream exceeds
1 MiB wraps inside the much larger allocation, and the hardware never signals
completion. t8112 and t8122 program `0` in the equivalent register; only t8103
carries the stale value, and the defect is M1-specific.

### How it was found

By exploiting a codec asymmetry: a real 1080p VP9 clip with a **127 KiB**
keyframe decoded cleanly while H.264 failed 20/20 at **140 KiB**. That ruled out
shared buffers and codec-agnostic limits, and pointed at per-codec register
programming — which led to `avd-hw.c`, where t8103 is the only variant setting a
nonzero mask.

Five hypotheses were falsified by measurement first: the 8x8 transform path,
`pps_tile[0]` sizing, the multi-slice `readl_poll_timeout`, a lost mailbox
interrupt under `IRQF_ONESHOT`, and the H.264-only slice-offset scan.

### Verification

`fifo_mask` swept as a module parameter, 10 runs per value per clip:

| fifo_mask | small frame | large frame | real-world |
|---|---|---|---|
| `0x100000` (stock) | 10/10 | **0/10** | **1/10** |
| `0` | 10/10 | 10/10 | 10/10 |
| `0xc00000` (12 MiB) | 10/10 | 10/10 | 10/10 |
| `0x800000` | 10/10 | 10/10 | 10/10 |

Output correctness against libavcodec, with both `0` and `0xc00000` — all
bit-exact:

| stream | PSNR |
|---|---|
| H.264 real-world 1080p | `y:inf u:inf v:inf` |
| H.264 big keyframe | `y:inf u:inf v:inf` |
| H.264 small (control) | `y:inf u:inf v:inf` |
| H.264 Main weighted | `y:inf u:inf v:inf` |
| HEVC real-world | `y:inf u:inf v:inf` |
| VP9 real-world | `y:inf u:inf v:inf` |

`0` is proposed rather than `0xc00000` because matching the other variants is a
smaller and more clearly correct claim than asserting what the register means on
undocumented hardware. Both work; `0x100000` appears to be a stale bring-up
constant from when the FIFO allocation was smaller.
