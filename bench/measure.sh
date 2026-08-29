#!/bin/bash
# Measure the power cost of software vs hardware video decode on Apple Silicon.
#
# Reads "Total System Power" from the macsmc hwmon sensor, which reports
# whole-machine draw in microwatts and works on AC as well as on battery. The
# display, the shell and any background load are present in every condition, so
# the delta between conditions is the quantity of interest, not the absolute
# numbers. CPU time comes from /proc/<pid>/stat, so nothing beyond coreutils,
# python3 and mpv is required.
#
# Usage: ./measure.sh [clip.mp4]
#   With libva able to find the driver (see README), --hwdec=vaapi reaches the
#   Apple Video Decoder; --hwdec=no forces libavcodec's software decoder.

set -u
CLIP="${1:-bench1080.mp4}"
SAMPLE_S=0.5
WARMUP=5              # seconds of startup transient excluded from the power mean
TICKS=$(getconf CLK_TCK)

HWMON=""
for h in /sys/class/hwmon/hwmon*; do
  [[ -r $h/name ]] || continue
  [[ $(<"$h/name") == macsmc_hwmon ]] || continue
  [[ -r $h/power1_input ]] && HWMON="$h" && break
done
[[ -n $HWMON ]] || { echo "no macsmc_hwmon power sensor found" >&2; exit 1; }

# Samples power while pid $1 lives; also tracks that pid's cumulative CPU time.
# Writes "mean_w sd_w nsamples cpu_s" to $2.
watch_pid() {
  local pid=$1 out=$2
  local -a w=()
  local cpu=0 st
  # The sampling loop must stay cheap or it perturbs what it measures: only
  # sleep forks per iteration, the two reads are bash builtins, and the warmup
  # gate is integer arithmetic on $SECONDS.
  local start=$SECONDS
  while kill -0 "$pid" 2>/dev/null; do
    if st=$(< "/proc/$pid/stat") 2>/dev/null; then
      st=${st#*") "}                     # drop "pid (comm) "
      # shellcheck disable=SC2086
      set -- $st
      cpu=$(( ${12} + ${13} ))           # utime + stime, renumbered after comm
    fi
    (( SECONDS - start >= WARMUP )) && w+=( "$(<"$HWMON/power1_input")" )
    sleep "$SAMPLE_S"
  done
  local wall=$(( SECONDS - start ))
  python3 - "$cpu" "$TICKS" "$wall" "${w[@]:-}" <<'PY' > "$out"
import sys
cpu_j, ticks, wall, *vals = sys.argv[1:]
vals = [int(v) for v in vals if v]
cpu = int(cpu_j) / int(ticks)
if vals:
    m = sum(vals)/len(vals)/1e6
    var = sum((v/1e6 - m)**2 for v in vals)/len(vals)
    print(f"{m:.3f} {var**0.5:.3f} {len(vals)} {cpu:.2f} {wall}")
else:
    print(f"0 0 0 {cpu:.2f} {wall}")
PY
}

run_case() {
  local label=$1; shift
  local pfile; pfile=$(mktemp)
  local log;   log=$(mktemp)
  if [[ $label == idle ]]; then
    sleep 45 & local pid=$!
  else
    # Keep mpv's decoder chatter so the run can be verified afterwards. A power
    # number is meaningless unless the decoder it claims to measure was the one
    # that actually ran, so each case is checked rather than assumed.
    mpv "$@" --no-audio --msg-level=all=info,vd=v "$CLIP" >"$log" 2>&1 & local pid=$!
  fi
  watch_pid "$pid" "$pfile"
  wait "$pid" 2>/dev/null
  read -r mean sd n cpu wall < "$pfile"

  if [[ $label == idle ]]; then
    printf '%-18s %7s W   sd %-6s n=%-4s\n' "$label" "$mean" "$sd" "$n"
  else
    local hw sw er verdict
    hw=$(grep -ci "Using hardware decoding" "$log")
    sw=$(grep -ci "Using software decoding" "$log")
    er=$(grep -ciE "failed waiting|Failed to (begin|end) picture" "$log")
    if [[ $label == *hardware* ]]; then
      { (( hw > 0 )) && (( sw == 0 )) && (( er == 0 )); } && verdict="hw-verified" || verdict="INVALID(hw=$hw sw=$sw err=$er)"
    else
      { (( sw > 0 )) && (( hw == 0 )); } && verdict="sw-verified" || verdict="INVALID(hw=$hw sw=$sw)"
    fi
    printf '%-18s %7s W   sd %-6s n=%-4s cpu %6ss / %ss wall   %s\n' \
      "$label" "$mean" "$sd" "$n" "$cpu" "$wall" "$verdict"
  fi
  rm -f "$pfile" "$log"
}
echo "sensor : $HWMON ($(<"$HWMON/power1_label"))"
echo "clip   : $CLIP"
echo "method : realtime playback, --vo=gpu, identical except for the decoder"
echo
run_case idle
run_case "software decode" --hwdec=no    --vo=gpu
run_case "hardware decode" --hwdec=vaapi --vo=gpu
run_case idle
