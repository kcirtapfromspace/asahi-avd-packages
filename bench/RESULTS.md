# Measured results

MacBook Pro 13" M1 (j293 / t8103), Omarchy 4.0.1, linux-asahi 7.1.6, mpv 0.41,
`libva-v4l2_request-avd` 1.3. Produced by [`measure.sh`](measure.sh).

Method: 60 s clips played at realtime with `--vo=gpu`, the two conditions
differing only in `--hwdec`. "Total System Power" comes from the macsmc hwmon
sensor and covers the whole machine — display, background load and this shell
are present in every condition, so the **delta** is the result, not the
absolute figure. The first 5 s of each run is discarded as startup transient.
Each run is checked afterwards for which decoder actually ran; a run that fell
back to software is reported `INVALID` rather than scored.

## H.264 Main, 1280x720, 4.0 Mbps

```
idle              6.925 W   sd 0.366
software decode   7.768 W   sd 0.254   cpu 37.90s / 61s wall   sw-verified
hardware decode   7.546 W   sd 0.084   cpu  6.13s / 60s wall   hw-verified
idle              6.686 W   sd 0.051
```

## H.264 Main, 1920x1080, 4.0 Mbps

```
idle              6.837 W   sd 0.303
software decode   7.871 W   sd 0.053   cpu 45.39s / 61s wall   sw-verified
hardware decode   7.660 W   sd 0.059   cpu  7.27s / 61s wall   hw-verified
idle              6.724 W   sd 0.079
```

## What this actually says

| | 720p | 1080p |
|---|---|---|
| CPU time, software | 37.90 s | 45.39 s |
| CPU time, hardware | 6.13 s | 7.27 s |
| **CPU time reduction** | **84%** | **84%** |
| Power above idle, software | 0.96 W | 1.09 W |
| Power above idle, hardware | 0.74 W | 0.88 W |
| **Power saved during playback** | **0.22 W** | **0.21 W** |
| …as a share of total system draw | 2.9% | 2.7% |

**The CPU result is large and unambiguous: decode work drops by about 84%.**

**The battery result is real but modest.** Roughly 0.2 W off a machine drawing
about 7.8 W during playback. On this laptop's 58.2 Wh battery that is the
difference between about 7.4 and 7.6 hours of continuous video — call it ten to
fifteen minutes per charge. It is not the transformative battery win the CPU
number might suggest, and it does not grow between 720p and 1080p.

The reason is that on an M1 the display, GPU and baseline SoC draw dominate,
and the efficiency cores decode H.264 cheaply enough that removing that work
frees a fifth of the marginal playback power rather than most of it. The freed
CPU is still worth having — it shows up as headroom for everything else running
during playback, less thermal pressure, and it would matter considerably more
at 4K or while multitasking, neither of which is measured here.

## Caveats

- Both conditions use `--vo=gpu`, so GPU compositing is in both. A working
  `--vo=dmabuf-wayland` path would avoid the GPU entirely and should measure
  better; it does not currently work (see the README).
- Single machine, single run per condition. The standard deviations are small
  (0.05–0.37 W) and idle is stable across the two bracketing measurements, but
  these are not averaged over repeated trials.
- Measured on AC. The sensor reports whole-system power either way, but a
  battery-discharge measurement would be a useful cross-check.
- Synthetic `testsrc2` content, not real video.
