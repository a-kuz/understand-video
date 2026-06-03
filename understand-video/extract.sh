#!/usr/bin/env bash
# video-breakdown / extract.sh
# Deterministic slicing of a video into artifacts for later breakdown.
#
# Usage:  extract.sh <video> [--ultra]
# Output: creates <video_dir>/<video_stem>-breakdown/ with subfolders
#         frames/ (visual sequence), ocr/ (text), audio/ (+transcript), [dynamics/ with --ultra]
#         and prints the absolute path to that folder to stdout (last line WORK=...).
#
# Slicing parameters:
#   frames : 2 fps, jpeg q60 (qscale 8), downscale into an 800x600 box (no upscale)
#   ocr    : 1 fps, jpeg q80 (qscale 5), full resolution (text matters)
#   audio  : 16kHz mono WAV (whisper format) + transcript via whisper-cli
#   ultra  : extra 10 fps, small resolution / low quality — for motion analysis
set -euo pipefail

SRC="${1:?Usage: extract.sh <video> [--ultra]}"
MODE="${2:-standard}"
[ -f "$SRC" ] || { echo "ERROR: file not found: $SRC" >&2; exit 1; }

# --- 0. Dependencies: check and install (macOS brew / Linux apt|dnf|pacman) ---
# Detect a package manager. Returns the install command prefix on stdout.
PKG=""
detect_pkg() {
  if command -v brew >/dev/null;   then PKG="brew install"; return 0; fi
  if command -v apt-get >/dev/null;then PKG="sudo apt-get install -y"; return 0; fi
  if command -v dnf >/dev/null;    then PKG="sudo dnf install -y"; return 0; fi
  if command -v pacman >/dev/null; then PKG="sudo pacman -S --noconfirm"; return 0; fi
  return 1
}
detect_pkg || echo "WARN: no known package manager (brew/apt/dnf/pacman) — auto-install disabled" >&2

pkg_install() { # $@ = package names; no-op (with warning) if no PKG
  [ -n "$PKG" ] || { echo "WARN: cannot auto-install $* (no package manager)" >&2; return 1; }
  $PKG "$@" >&2
}

if ! command -v ffmpeg >/dev/null || ! command -v ffprobe >/dev/null; then
  echo "ffmpeg not found — installing ($PKG)…" >&2
  pkg_install ffmpeg || { echo "ERROR: install ffmpeg manually, then retry" >&2; exit 1; }
fi

# whisper binary: brew ships `whisper-cli`; some distros ship `whisper-cpp` or `main`
WCLI=""
for b in whisper-cli whisper-cpp main; do command -v "$b" >/dev/null && { WCLI="$b"; break; }; done
if [ -z "$WCLI" ]; then
  echo "whisper-cpp not found — installing ($PKG)…" >&2
  # package name is whisper-cpp on brew; on most distros it isn't packaged — warn only
  pkg_install whisper-cpp 2>/dev/null || echo "WARN: whisper-cpp not auto-installable here — transcript will be skipped" >&2
  for b in whisper-cli whisper-cpp main; do command -v "$b" >/dev/null && { WCLI="$b"; break; }; done
fi

# whisper model dir: honor $WHISPER_MODEL_DIR, else probe common prefixes
WSHARE="${WHISPER_MODEL_DIR:-}"
if [ -z "$WSHARE" ]; then
  for d in /opt/homebrew/share/whisper-cpp /usr/local/share/whisper-cpp \
           /usr/share/whisper-cpp "$HOME/.local/share/whisper-cpp"; do
    [ -d "$d" ] && { WSHARE="$d"; break; }
  done
  [ -n "$WSHARE" ] || WSHARE="$HOME/.local/share/whisper-cpp"
fi
have_model() {
  for m in ggml-large-v3-turbo ggml-large-v3 ggml-medium ggml-base ggml-small; do
    [ -f "$WSHARE/$m.bin" ] && return 0
  done
  return 1
}
if [ -n "$WCLI" ]; then
  if ! have_model; then
    echo "whisper model not found — downloading ggml-base.bin into $WSHARE…" >&2
    mkdir -p "$WSHARE"
    curl -L -fsS -o "$WSHARE/ggml-base.bin" \
      "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin" >&2 \
      || echo "WARN: model did not download — transcript will be skipped" >&2
  fi
fi

DIR="$(cd "$(dirname "$SRC")" && pwd)"
STEM="$(basename "$SRC")"; STEM="${STEM%.*}"
WORK="$DIR/$STEM-breakdown"
rm -rf "$WORK"
mkdir -p "$WORK/frames" "$WORK/ocr" "$WORK/audio"

# --- metadata (for the report) ---
ffprobe -v error -show_entries format=duration:stream=codec_type,codec_name,width,height,r_frame_rate,channels,sample_rate \
  -of default=noprint_wrappers=1 "$SRC" > "$WORK/meta.txt" 2>&1 || true
HAS_AUDIO=$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$SRC" 2>/dev/null | head -1)

# --- 1. Visual sequence: 2fps, q60, 800x600 box ---
ffmpeg -y -loglevel error -i "$SRC" \
  -vf "fps=2,scale='min(800,iw)':'min(600,ih)':force_original_aspect_ratio=decrease" \
  -q:v 8 "$WORK/frames/f_%04d.jpg"

# --- 2. OCR: 1fps, q80, full resolution ---
ffmpeg -y -loglevel error -i "$SRC" -vf "fps=1" -q:v 5 "$WORK/ocr/o_%04d.jpg"

# --- 3. Audio + transcript ---
if [ -n "$HAS_AUDIO" ]; then
  ffmpeg -y -loglevel error -i "$SRC" -vn -acodec pcm_s16le -ar 16000 -ac 1 "$WORK/audio/audio.wav"
  # silence? (very low mean_volume → probably no speech)
  MEAN=$(ffmpeg -hide_banner -i "$WORK/audio/audio.wav" -af volumedetect -f null - 2>&1 \
         | sed -n 's/.*mean_volume: \(.*\) dB.*/\1/p' | head -1)
  echo "audio_mean_volume_dB=${MEAN:-NA}" >> "$WORK/meta.txt"

  # whisper transcript: prefer the precise model, otherwise any available one
  WMODEL=""
  for m in ggml-large-v3-turbo.bin ggml-large-v3.bin ggml-medium.bin ggml-base.bin ggml-small.bin; do
    if [ -f "$WSHARE/$m" ]; then WMODEL="$WSHARE/$m"; break; fi
  done
  if [ -n "$WCLI" ] && [ -n "$WMODEL" ]; then
    # -ml 0 = natural segments; -l auto = auto language detection
    ( cd "$WORK/audio" && "$WCLI" -m "$WMODEL" -f audio.wav -l auto -oj -of transcript >/dev/null 2>&1 ) || true
    if [ -f "$WORK/audio/transcript.json" ]; then
      python3 - "$WORK/audio/transcript.json" > "$WORK/audio/transcript.txt" 2>/dev/null <<'PY' || true
import json,sys
d=json.load(open(sys.argv[1]))
lang=d.get("result",{}).get("language","?")
print(f"# language: {lang}")
for s in d.get("transcription",[]):
    o=s["offsets"]; print(f"{o['from']/1000:.1f}-{o['to']/1000:.1f}\t{s['text'].strip()}")
PY
      echo "transcript=ok (model=$(basename "$WMODEL"))" >> "$WORK/meta.txt"
    else
      echo "transcript=failed" >> "$WORK/meta.txt"
    fi
  else
    echo "transcript=unavailable (whisper-cli or model missing)" >> "$WORK/meta.txt"
  fi
else
  echo "audio=none" >> "$WORK/meta.txt"
fi

# --- 4. Ultra: dynamics, 10fps small ---
if [ "$MODE" = "--ultra" ] || [ "$MODE" = "ultra" ]; then
  mkdir -p "$WORK/dynamics"
  ffmpeg -y -loglevel error -i "$SRC" \
    -vf "fps=10,scale='min(256,iw)':'min(256,ih)':force_original_aspect_ratio=decrease" \
    -q:v 12 "$WORK/dynamics/d_%05d.jpg"
fi

# Print a summary and the path (last line is machine-readable)
echo "frames=$(ls "$WORK/frames" 2>/dev/null | wc -l | tr -d ' ')"
echo "ocr=$(ls "$WORK/ocr" 2>/dev/null | wc -l | tr -d ' ')"
[ -d "$WORK/dynamics" ] && echo "dynamics=$(ls "$WORK/dynamics" | wc -l | tr -d ' ')"
echo "WORK=$WORK"
