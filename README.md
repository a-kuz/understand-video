# understand-video

A Claude Code / agent **Skill** that analyzes a local video file and answers a
user's question about it. Give it a path to an `.mp4 / .mov / .mkv / .webm` and
it returns a written answer to what was asked — describe the contents,
transcribe speech, find a moment by timecode, or pull text off the screen.

Internally it builds three time-aligned tracks — on-screen text (OCR), the
visual sequence (frames), and the audio transcript — and synthesizes an answer
from them. It also prints a filmstrip (key frames with timecodes) as ANSI
directly in the terminal, sized to the terminal width.

The skill replies in the user's language; the documentation here is in English.

## How it works

1. `extract.sh` slices the video with `ffmpeg`:
   - `frames/` — 2 fps, jpeg q60, boxed to 800×600 (visual sequence, 0.5 s step)
   - `ocr/` — 1 fps, jpeg q80, full resolution (on-screen text, 1.0 s step)
   - `audio/transcript.txt` — `whisper-cli` transcript with timings
   - `dynamics/` — 10 fps small frames, only with `--ultra` (motion)
2. A background subagent reads the frames, builds the three internal tracks, and
   synthesizes an answer to the query. Frame images stay in the subagent's
   context, not the main thread.
3. The main thread renders the filmstrip to the terminal (frame count and width
   adapt to the terminal), then cleans up the working directory.

Notes: local files only (no URL download), fixed-fps sampling (no scene
detection). Auto-install uses the detected package manager — `brew` on macOS,
`apt`/`dnf`/`pacman` on Linux; Windows via WSL. If whisper or a model is
missing, the transcript is marked `unavailable` and frames + OCR still work.

## Install

```bash
npx skills add a-kuz/understand-video@understand-video -g -y
```

Or clone into a skills directory:

```bash
git clone https://github.com/a-kuz/understand-video ~/.claude/skills/understand-video-repo
# point your agent at understand-video/SKILL.md
```

## Dependencies (auto-installed on first run)

Installed via the detected package manager (`brew` / `apt` / `dnf` / `pacman`):

- `ffmpeg` / `ffprobe` — slicing (required)
- `whisper-cpp` (`whisper-cli`) — transcript (optional; on Linux usually
  installed manually)
- a whisper model — looked up in `$WHISPER_MODEL_DIR` or common prefixes;
  auto-downloads `ggml-base.bin` (~148 MB) if none present; picks the best
  available (`large-v3-turbo` → `large-v3` → `medium` → `base` → `small`)
- `chafa` — the in-terminal filmstrip

For better non-English speech, a larger model can be fetched once:

```bash
curl -L -o "$WHISPER_MODEL_DIR/ggml-large-v3-turbo.bin" \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin
```

## Usage (inside an agent)

Give it a file and a question, e.g.:

> here's a screen recording ~/Desktop/rec.mov — the UI keeps jumping, figure
> out what's going on

(an "is the UI jumping / flickering" request triggers the `--ultra` motion pass —
10 fps frames so the subagent can see the jitter between adjacent frames.)

> transcribe ~/Downloads/talk.mp4

> what text is on screen in screen-rec.mkv?

Internals and parameters are documented in
[`understand-video/SKILL.md`](understand-video/SKILL.md).

## License

MIT — see [LICENSE](LICENSE).
