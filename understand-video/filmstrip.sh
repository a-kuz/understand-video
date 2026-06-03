#!/usr/bin/env bash
# video-breakdown / filmstrip.sh
# Composes a "filmstrip" right in the terminal as text: N key frames
# (first, last + evenly spaced in between) in one row. chafa draws the frames in
# symbols mode; the film perforation, struts, and timecodes are drawn by us as
# ANSI text. No PNG, no transcript.
#
# Frame width is derived from the TERMINAL WIDTH: the strip always fits across,
# all frames are the same width, and the rows never drift out of alignment.
#
# Usage: filmstrip.sh <WORK_dir>
#   <WORK_dir> — the *-breakdown folder from extract.sh (with frames/)
# Env: N (frames in the row, default 4), COLS (override terminal width),
#      FW (force frame width in cells), FH (force frame height in rows)
set -euo pipefail

WORK="${1:?Usage: filmstrip.sh <WORK_dir>}"
FR="$WORK/frames"
[ -d "$FR" ] || { echo "ERROR: no $FR" >&2; exit 1; }
if ! command -v chafa >/dev/null; then
  echo "chafa is required — installing…" >&2
  if   command -v brew >/dev/null;    then brew install chafa >&2
  elif command -v apt-get >/dev/null; then sudo apt-get install -y chafa >&2
  elif command -v dnf >/dev/null;     then sudo dnf install -y chafa >&2
  elif command -v pacman >/dev/null;  then sudo pacman -S --noconfirm chafa >&2
  else echo "ERROR: install chafa manually, then retry" >&2; exit 1; fi
fi

N="${N:-4}"      # how many frames in the row

# UTF-8 required: both chafa and the symbol counting rely on it
export LC_ALL="${LC_ALL:-en_US.UTF-8}" LANG="${LANG:-en_US.UTF-8}"

# --- Terminal width → per-frame width ---
# A "│" border sits before each frame and after the last → N+1 separators.
# Divide the available width by N. A narrow terminal → fewer frames.
if [ -z "${COLS:-}" ]; then
  COLS=$(tput cols 2>/dev/null || echo 80)
fi
[ "$COLS" -ge 24 ] 2>/dev/null || COLS=80

# If N frames don't fit (min 8 cells per frame) — reduce N.
while [ "$N" -gt 1 ] && [ $(( (COLS - (N+1)) / N )) -lt 8 ]; do N=$((N-1)); done

if [ -z "${FW:-}" ]; then
  FW=$(( (COLS - (N+1)) / N ))
fi
[ "$FW" -ge 4 ] 2>/dev/null || FW=4
# Frame height from width: a terminal cell is ~2:1 (tall), a frame is ~16:9 →
# FH ≈ FW * 9/16 / 2. Clamp to a sane range.
if [ -z "${FH:-}" ]; then
  FH=$(( FW * 9 / 16 / 2 ))
  [ "$FH" -lt 5 ] && FH=5
  [ "$FH" -gt 16 ] && FH=16
fi

# ANSI
ESC=$'\033'; RST="${ESC}[0m"
FILM="${ESC}[48;5;233m"            # film background (near-black)
PERFC="${ESC}[48;5;233;38;5;250m"  # perforation: light holes on dark
TCC="${ESC}[48;5;233;38;5;252m"    # timecodes

# 1. Build a list of N frames: first, last + evenly spaced in between
ALL=()
for f in "$FR"/f_*.jpg; do [ -e "$f" ] && ALL+=("$f"); done
TOTAL=${#ALL[@]}
[ "$TOTAL" -gt 0 ] || { echo "ERROR: no frames" >&2; exit 1; }

pick=()
times=()
if [ "$TOTAL" -le "$N" ]; then
  for idx in "${!ALL[@]}"; do pick+=("${ALL[$idx]}"); times+=("$idx"); done
else
  for ((j=0; j<N; j++)); do
    idx=$(( j*(TOTAL-1)/(N-1) ))   # evenly from 0 to TOTAL-1 including the ends
    pick+=("${ALL[$idx]}"); times+=("$idx")
  done
fi
NC=${#pick[@]}

# 2. Each frame → a symbols block of EXACTLY FWxFH. --stretch forces it to fill
#    the box (otherwise chafa fits to aspect and frames come out varied widths).
TMP="$WORK/.fs"; rm -rf "$TMP"; mkdir -p "$TMP"
c=0
for f in "${pick[@]}"; do
  chafa -f symbols --size="${FW}x${FH}" --stretch --polite on "$f" > "$TMP/cell_$c.txt"
  c=$((c+1))
done

# Strip ANSI and return the visible length of a line in characters
strip_ansi() { sed $'s/\033\\[[0-9;]*m//g'; }

# Trim/pad a frame line to EXACTLY FW visible chars. chafa in symbols mode may
# emit a line slightly wider/narrower than the box — normalize hard so rows
# don't drift.
fit_fw() { # $1 = line (with ANSI) → prints a line of exactly FW visible chars
  local line="$1"
  local vis; vis=$(printf '%s' "$line" | strip_ansi | tr -d '\n' | wc -m | tr -d ' ')
  if [ "$vis" -le "$FW" ]; then
    printf '%s' "$line"
    local need=$(( FW - vis )); while [ "$need" -gt 0 ]; do printf ' '; need=$((need-1)); done
  else
    # wider than FW: cut by visible chars, preserving ANSI codes (count printables only)
    awk -v want="$FW" '
      BEGIN{ RS="\0"; n=0; out="" }
      {
        s=$0; i=1; L=length(s)
        while (i<=L) {
          c=substr(s,i,1)
          if (c=="\033") { # ANSI sequence \033[...m — copy verbatim
            j=i+1; seq=c
            while (j<=L) { ch=substr(s,j,1); seq=seq ch; if (ch ~ /[A-Za-z]/) break; j++ }
            out=out seq; i=j+1; continue
          }
          if (n<want) { out=out c; n++ }
          i++
        }
        printf "%s", out
      }' <<< "$line"
  fi
}

emit_row() { # $1 = row index (0..FH-1) → one composed line
  local idx=$(( $1 + 1 )) out="$FILM$GAP" c
  for ((c=0; c<NC; c++)); do
    local line; line=$(sed -n "${idx}p" "$TMP/cell_$c.txt")
    out="$out$(fit_fw "$line")${RST}${FILM}${GAP}"
  done
  printf '%s%s\n' "$out" "$RST"
}

# 3. Perforation FW chars wide: a hole every 4 cells
PERF=""; k=0
while [ $k -lt "$FW" ]; do
  if [ $(( k % 4 )) -eq 2 ]; then PERF="${PERF}▦"; else PERF="${PERF} "; fi
  k=$((k+1))
done
GAP="│"           # strut between frames (film border)

emit_perf() {
  local out="$FILM$GAP" c
  for ((c=0; c<NC; c++)); do out="$out${PERFC}${PERF}${RST}${FILM}${GAP}"; done
  printf '%s%s\n' "$out" "$RST"
}

echo
emit_perf
for ((rr=0; rr<FH; rr++)); do emit_row "$rr"; done
emit_perf

# 4. Timecodes under the frames (centered in the FW field)
tc_row="${FILM}${TCC} "
for ((c=0; c<NC; c++)); do
  t=$(awk "BEGIN{printf \"%.1f\", ${times[$c]}*0.5}")s   # 2fps → 0.5s step
  len=${#t}; pad=$(( (FW-len)/2 )); rpad=$(( FW-len-pad ))
  [ "$pad" -lt 0 ] && pad=0; [ "$rpad" -lt 0 ] && rpad=0
  printf -v cell "%*s%s%*s" "$pad" "" "$t" "$rpad" ""
  tc_row="$tc_row$cell "
done
printf '%s%s\n\n' "$tc_row" "$RST"

rm -rf "$TMP"
