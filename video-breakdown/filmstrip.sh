#!/usr/bin/env bash
# video-breakdown / filmstrip.sh
# Composes a "filmstrip" right in the terminal as text: 6 key frames
# (first, last + 4 in between) in one row. chafa draws only the frames
# themselves in symbols mode (even text blocks), while the film perforation,
# struts, and timecodes are drawn by us as ANSI text. No PNG, no transcript.
#
# Usage: filmstrip.sh <WORK_dir>
#   <WORK_dir> — the *-breakdown folder from extract.sh (with frames/)
# Env: FW (frame width in cells, default 22), FH (height, 11), N (frames, 6)
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

FH="${FH:-11}"   # frame height, rows (target for chafa)
N="${N:-6}"      # how many frames in the row
# The actual chafa block width in symbols mode is learned at runtime (depends on
# aspect ratio), so FW here is only a target for chafa.
FW_TARGET="${FW:-22}"

# UTF-8 required: both chafa and the symbol counting rely on it
export LC_ALL="${LC_ALL:-en_US.UTF-8}" LANG="${LANG:-en_US.UTF-8}"
# visible length of the first line in CHARACTERS (not bytes): strip ANSI → wc -m
vis_len() { sed $'s/\033\\[[0-9;]*m//g' | head -1 | tr -d '\n' | wc -m | tr -d ' '; }

# ANSI
ESC=$'\033'; RST="${ESC}[0m"
FILM="${ESC}[48;5;233m"        # film background (near-black)
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
    # evenly from 0 to TOTAL-1 including the ends
    idx=$(( j*(TOTAL-1)/(N-1) ))
    pick+=("${ALL[$idx]}"); times+=("$idx")
  done
fi

# 2. Each frame → a fixed-size symbols block, lines into an array
#    Stored line by line: CELL[cell_index][row]
TMP="$WORK/.fs"; rm -rf "$TMP"; mkdir -p "$TMP"
c=0
for f in "${pick[@]}"; do
  chafa -f symbols --size="${FW_TARGET}x${FH}" --stretch --polite on "$f" > "$TMP/cell_$c.txt"
  c=$((c+1))
done
NC=$c
# actual block width and height (same for all frames)
FW=$(vis_len < "$TMP/cell_0.txt")
FH=$(wc -l < "$TMP/cell_0.txt"); FH=$((FH))

# 3. Perforation FW chars wide: a hole every 4 cells
PERF=""; k=0
while [ $k -lt "$FW" ]; do
  if [ $(( k % 4 )) -eq 2 ]; then PERF="${PERF}▦"; else PERF="${PERF} "; fi
  k=$((k+1))
done
GAP="│"           # strut between frames (film border)

# repeat GAP for the timecode row using the same character
# pad a frame line up to FW CHARACTERS (chafa sometimes trims the tail)
pad_to_fw() { # stdin: a frame line → pads with spaces up to FW visible chars
  local line="$1"
  local vis; vis=$(printf '%s' "$line" | sed $'s/\033\\[[0-9;]*m//g' | tr -d '\n' | wc -m | tr -d ' ')
  local need=$(( FW - vis ))
  printf '%s' "$line"
  while [ "$need" -gt 0 ]; do printf ' '; need=$((need-1)); done
}

emit_row() { # $1 = row index (0..FH-1) → one composed line
  local idx=$(( $1 + 1 )) out="$FILM$GAP" c
  for ((c=0; c<NC; c++)); do
    local line; line=$(sed -n "${idx}p" "$TMP/cell_$c.txt")
    out="$out$(pad_to_fw "$line")${RST}${FILM}${GAP}"
  done
  printf '%s%s\n' "$out" "$RST"
}
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
  printf -v cell "%*s%s%*s" "$pad" "" "$t" "$rpad" ""
  tc_row="$tc_row$cell "
done
printf '%s%s\n\n' "$tc_row" "$RST"

rm -rf "$TMP"
