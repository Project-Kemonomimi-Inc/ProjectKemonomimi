#!/usr/bin/env bash
set -euo pipefail

########################################
# Config
########################################

# Output formats (extensions, no dot)
# Example: OUT_FORMATS=("jpg" "webp")
OUT_FORMATS=("jpg")

# Default quality (if no per-format override)
QUALITY_DEFAULT=90      # decent baseline

# Optional per-format quality overrides:
# QUALITY_jpg=92
# QUALITY_webp=85
# QUALITY_avif=60
# QUALITY_heif=90
# (Uncomment / add as desired)
QUALITY_jpg=95          # a bit higher for fewer artifacts
#QUALITY_webp=85         # WebP compresses well; 80 is often visually lossles
#QUALITY_avif=60         # AVIF is much more efficient; lower numbers look good
#QUALITY_heif=90         # HEIF compresses

# Optional extra per-format arguments (passed to convert/ magick/ gm):
# ARGS_jpg='-sampling-factor 4:2:0'
# ARGS_webp='-define webp:method=6'
# ARGS_avif='-define heic:speed=4 -define heic:chroma-subsampling=4:2:0'
# ARGS_heif='-define heic:speed=2'
ARGS_DEFAULT=''
ARGS_jpg='-sampling-factor 4:4:4 -interlace JPEG -define jpeg:dct-method=float'
# (and maybe omit -strip if you want full metadata)

########################################
# Cleanup old outputs in current dir
########################################
for ext in "${OUT_FORMATS[@]}"; do
  rm -rfv *."$ext"
done

# --- tool detection (ImageMagick preferred, fallback to GraphicsMagick) ---
if command -v magick >/dev/null 2>&1; then
  export CONV_BIN="magick"
  export CONV_IS_GM=0
elif command -v gm >/dev/null 2>&1; then
  export CONV_BIN="gm"
  export CONV_IS_GM=1
else
  echo "❌ Neither ImageMagick (magick) nor GraphicsMagick (gm) found. Aborting."
  exit 1
fi
echo "✅ Using ${CONV_BIN} for image conversion"

########################################
# Gather PNGs
########################################
mapfile -d '' files < <(find . -type f -name "*.png" -print0 | sort -z || true)

total=${#files[@]}
(( total )) || { echo "No PNG files found."; exit 1; }

# --- decide parallelism ---
jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
if [[ -z "${jobs}" ]]; then jobs="$(nproc 2>/dev/null || echo 4)"; fi
if ! [[ "${jobs}" =~ ^[0-9]+$ ]]; then jobs=4; fi

# --- progress + logging setup ---
progress_file="$(mktemp)"
: > "$progress_file"
log_file="convert.log"
: > "$log_file"
printf 'Seq\tStartEpoch\tDurSec\tExit\tHost\tPID\tInput\tOutput\n' >> "$log_file"

is_tty=0
if [ -t 1 ]; then is_tty=1; fi

draw_bar() {
  local c=$1 t=$2
  local cols barw fill left pct
  cols=$(tput cols 2>/dev/null || echo 80)
  barw=$(( cols - 32 )); (( barw < 10 )) && barw=10
  pct=$(( c * 100 / t ))
  fill=$(( c * barw / t ))
  left=$(( barw - fill ))
  local eta="--:--"
  if (( c > 0 )); then
    local now start dur avg rem secs
    start=$(head -n1 "$progress_file")
    now=$(date +%s)
    dur=$(( now - start ))
    avg=$(( dur / c ))
    rem=$(( t - c ))
    secs=$(( avg * rem ))
    if (( secs > 0 && secs < 36000 )); then
      printf -v eta "%02d:%02d" $(( secs / 60 )) $(( secs % 60 ))
    fi
  fi
  printf '\r[%3d%%] [%-*s] %d/%d ETA %s' \
    "$pct" "$barw" "$(printf '%*s' "$fill" '' | tr ' ' '#')" \
    "$c" "$t" "$eta"
}

########################################
# Progress monitor (background)
########################################
if (( is_tty )); then
  {
    date +%s > "$progress_file"
    local completed=0
    while true; do
      lines=$(wc -l < "$progress_file")
      if (( lines > 1 )); then completed=$(( lines - 1 )); fi
      draw_bar "$completed" "$total"
      (( completed >= total )) && break
      sleep 0.1
    done
    echo
  } &
  monitor_pid=$!
fi

# Helper in subshells: runs the right tool based on CONV_IS_GM / CONV_BIN
run_convert() {
  local in="$1" out="$2" q="$3"

  # Use CURRENT_EXT to look up any extra args for this format
  local ext="$CURRENT_EXT"
  local args_var="ARGS_${ext}"
  local args_str="${!args_var:-$ARGS_DEFAULT}"

  local -a extra_args=()
  if [[ -n "$args_str" ]]; then
    # shellcheck disable=SC2206
    extra_args=($args_str)
  fi

  if [[ "${CONV_IS_GM}" -eq 1 ]]; then
    # GraphicsMagick
    "$CONV_BIN" convert -verbose "$in" -strip "${extra_args[@]}" -quality "$q" "$out"
  else
    # ImageMagick (v7: magick)
    "$CONV_BIN" -verbose "$in" -strip "${extra_args[@]}" -quality "$q" "$out"
  fi
}

export -f run_convert

# make formats + quality config available to subshell
OUT_FORMATS_STR="${OUT_FORMATS[*]}"
export OUT_FORMATS_STR QUALITY_DEFAULT ARGS_DEFAULT
# Export per-format QUALITY_* and ARGS_* vars if defined
for ext in "${OUT_FORMATS[@]}"; do
  v="QUALITY_${ext}"
  if [[ -v "$v" ]]; then
    export "$v"
  fi
  a="ARGS_${ext}"
  if [[ -v "$a" ]]; then
    export "$a"
  fi
done

emit_pairs() {
  local i=1
  for f in "${files[@]}"; do
    printf '%s\0%s\0' "$i" "$f"
    (( i++ ))
  done
}

emit_pairs | xargs -0 -n2 -P "$jobs" bash -c '
  idx="$1"; f="$2"
  host=$(hostname 2>/dev/null || printf localhost)
  start=$(date +%s)

  echo "[$idx/'"$total"'] Converting: $f"
  exitcode=0

  for ext in $OUT_FORMATS_STR; do
    CURRENT_EXT="$ext"
    out="${f%.png}.$ext"

    # pick quality: QUALITY_<ext> or QUALITY_DEFAULT
    var="QUALITY_${ext}"
    q="${!var:-$QUALITY_DEFAULT}"

    echo "  ↳ to: $out (q=$q)"

    # smarter skipping: if out exists and is newer, skip; else reconvert
    if [[ -e "$out" && "$out" -nt "$f" ]]; then
      echo "    ↳ exists & up-to-date, skipping"
      continue
    fi

    local_start=$(date +%s)
    if run_convert "$f" "$out" "$q" 1>>"'"$log_file"'.verbose" 2>&1; then
      local_end=$(date +%s)
      local_dur=$(( local_end - local_start ))

      # copy mtime from input PNG to this output
      touch -r "$f" "$out" || echo "    ↳ warning: failed to copy mtime for $out"

      printf "%d\t%d\t%d\t%d\t%s\t%d\t%s\t%s\n" \
        "$idx" "$local_start" "$local_dur" 0 "$host" "$$" "$f" "$out" >> "'"$log_file"'"
    else
      ec=$?
      exitcode=$ec
      local_end=$(date +%s)
      local_dur=$(( local_end - local_start ))

      printf "%d\t%d\t%d\t%d\t%s\t%d\t%s\t%s\n" \
        "$idx" "$local_start" "$local_dur" "$ec" "$host" "$$" "$f" "$out" >> "'"$log_file"'"
    fi
  done

  echo "$idx" >> "'"$progress_file"'"
  exit "$exitcode"
' _

if [[ -n "${monitor_pid:-}" ]]; then
  wait "$monitor_pid" 2>/dev/null || true
fi

completed=$(( $(wc -l < "$progress_file") - 1 ))
echo "Done: $completed/$total PNG file(s) processed. Logs: $log_file (summary), ${log_file}.verbose (details)."

rm -f "$progress_file"