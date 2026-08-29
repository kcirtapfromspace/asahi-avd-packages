# Kernel patches

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
