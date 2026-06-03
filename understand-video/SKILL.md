---
name: understand-video
description: >-
  Analyze a local video file: understand what is in it and answer the user's
  request. Internally builds three time-aligned tracks (on-screen text / OCR,
  visual sequence / plot, audio transcript) on a common timeline as working
  material, but returns a finished analysis tailored to the request, not tables.
  Use when the user gives a path to a video (.mp4/.mov/.mkv/.webm) and asks to
  describe, transcribe, find a moment, extract on-screen text/speech, or
  understand the plot. Triggers: "analyze video", "understand video", "what's in
  this video", "transcribe this clip", "read this video". Works with any language
  (speech is auto-detected; the reply matches the user's language).
---

# Understand video

Analyzes a video and **answers the user's request** with finished prose.
Internally it builds three tracks on a timeline (on-screen text / visual
sequence / audio transcript) as working material, but outputs coherent analysis
tailored to the request, not tables. All heavy work (slicing + reading dozens of
frames + whisper) runs in a **background subagent** so frame images don't
pollute the main context.

**Language: reply in the user's language.** Match the language the user wrote
their request in. This documentation is in English; the produced analysis
follows the user.

The helper scripts `extract.sh` and `filmstrip.sh` live **next to this SKILL.md**
(same folder). Below, `<SKILL_DIR>` is the absolute path to that folder;
substitute it into the commands (the main loop knows where the skill was loaded
from). If unsure of the path, find it:
`find ~/.claude -name extract.sh -path '*understand-video*'` (or check a
project-local `.claude/skills/`).

## How to run (IMPORTANT)

**Do not analyze the video yourself in the main conversation.** Delegate
immediately to a background agent via the Agent tool:

- `subagent_type: "general-purpose"`
- `run_in_background: true` — the pipeline is long, don't block the conversation
- In the prompt pass: the absolute path to the video, the mode (standard/ultra),
  the **user's request** (why they sent the video — verbatim or close; if they
  just dropped a file, treat it as "describe what's in this video") and the
  **full agent instruction** from the block below. The request is key: the agent
  answers it, it does not dump tables.

Tell the user briefly: "Started analyzing the video in the background, I'll send
the result." When the `<task-notification>` of completion arrives — show the
agent's finished analysis to the user (this is the answer to their request; the
agent does not return raw tracks).

**After the analysis — show the filmstrip (this is done by the MAIN
conversation, not the subagent).** The agent returns `WORK=<path>` as its last
line (the working folder; it does NOT delete it). The main conversation runs:
```
bash "<SKILL_DIR>/filmstrip.sh" "<WORK>"   # ANSI into the user's terminal
rm -rf "<WORK>"                            # then clean up
```
The filmstrip is colored ANSI output to the user's live terminal (key frames in
a row with timecodes; frame count and width adapt to the terminal). It cannot be
"shown" from a background agent, so it is always run in the main conversation.

Mode: **standard** by default. **ultra** — only if the user explicitly asks for
motion/dynamics analysis (then pass the agent the `--ultra` flag).

## Subagent prompt (template)

> Analyze the video `<ABSOLUTE_PATH>` per the understand-video skill.
> **User's request:** "<WHAT THE USER ASKED, verbatim or close>"
> (if the user just gave a file with no details — treat the request as "describe
> what's in this video"). Your goal is to answer that request, not to emit
> tables. **Reply in the user's language.**
>
> 1. Run the slicing:
>    `bash "<SKILL_DIR>/extract.sh" "<PATH>"`
>    (append ` --ultra` if dynamics analysis is needed).
>    The script prints `WORK=<folder>` as its last line — the working folder with
>    subfolders `frames/` (visual sequence, 2 fps), `ocr/` (text, 1 fps),
>    `audio/transcript.txt` (transcript with timings), `meta.txt`.
> 2. Read `meta.txt` and `audio/transcript.txt`.
> 3. Read **every** frame in `frames/` with the Read tool — describe the plot for
>    yourself (setting, characters, actions, dynamics). Step 0.5 s (f_0001 = 0.0s,
>    f_0002 = 0.5s, …). With --ultra also review `dynamics/` (step 0.1 s).
> 4. Read **every** frame in `ocr/` — transcribe all on-screen text verbatim
>    (subtitles, captions, watermark, labels). Step 1.0 s. Keep typos as-is.
> 5. This is INTERNAL material: build three tracks on a timeline (text / visual /
>    audio), aligned to 0.5 s (0.1 s with --ultra). Do NOT output these tables to
>    the user — they are intermediate.
> 6. **Synthesize a finished answer to the user's request** (see above), drawing
>    on the three tracks. Format follows the request, not a fixed template:
>    - "what's it about / describe" → coherent description: what happens, who,
>      where, what is said, the point/outcome;
>    - "transcribe" → clean speech text (+ translation if asked);
>    - "find moment X / is there Y" → direct answer with a timecode;
>    - "extract on-screen text" → the collected text;
>    - a specific question → a direct answer to it.
>    Add timecodes where they genuinely help, not everywhere. If what's needed for
>    the answer isn't in the video — say so plainly. Transcript
>    `unavailable`/`none` — honestly note speech wasn't transcribed (and why),
>    don't invent lines.
> 7. Do NOT delete the working folder — the main conversation needs it for the
>    filmstrip.
> 8. Return **only the finished analysis** (it becomes the result; don't write
>    "here's your report", don't show raw tracks). As the very last line add:
>    `WORK=<path to the working folder>`.
>
> IMPORTANT about the "filmstrip": do NOT run it inside the subagent — it is ANSI
> output to the user's live terminal, which a background agent cannot write to.
> The filmstrip is shown by the MAIN conversation (see below).

## Dependencies (installed automatically)

`extract.sh` checks and installs on first run via the detected package manager
(macOS `brew`, Linux `apt`/`dnf`/`pacman`):

- `ffmpeg` / `ffprobe` — slicing (required).
- whisper binary (`whisper-cli`, or `whisper-cpp`/`main`) — transcript. On brew
  it's `whisper-cpp`; on most Linux distros it isn't packaged — install it
  yourself, then the transcript turns on automatically.
- a whisper model. Looked up in `$WHISPER_MODEL_DIR`, else common prefixes
  (`/opt/homebrew/share/whisper-cpp`, `/usr/local/share/...`, `~/.local/share/...`).
  None present → downloads `ggml-base.bin` (~148 MB). The script picks the best
  available: `large-v3-turbo` → `large-v3` → `medium` → `base` → `small`.

If no package manager is found — auto-install is skipped with a warning; install
deps manually. If whisper/model is missing — slicing and OCR still work, the
transcript is marked `unavailable` (lines are not invented). Windows: use WSL.

For better non-English speech, fetch a larger model once (into your model dir):
`curl -L -o "$WHISPER_MODEL_DIR/ggml-large-v3-turbo.bin" \
https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin`

## Slicing parameters

| Artifact   | Rate    | Quality            | Purpose                       |
|------------|---------|--------------------|-------------------------------|
| frames/    | 2 fps   | jpeg q60, ≤800×600 | visual sequence (0.5 s step)  |
| ocr/       | 1 fps   | jpeg q80, full     | on-screen text (1.0 s step)   |
| audio.wav  | —       | 16kHz mono         | input for whisper             |
| dynamics/  | 10 fps  | jpeg q~30, ≤256px  | --ultra: motion (0.1 s step)  |

## Filmstrip (filmstrip.sh)

A preview strip for the user's live terminal (not a file, ANSI output):
- key frames in one row (default 4: first, last + evenly-spaced in between);
- **width adapts to the terminal** — frame width = terminal cols / N, all frames
  equal width, rows stay aligned; a narrow terminal reduces N automatically;
- frames drawn by `chafa -f symbols` (text blocks); film perforation `▦`,
  borders `│` and timecodes under frames composed as ANSI text;
- no transcript on the strip (that's only in the text report);
- run by the MAIN conversation: `filmstrip.sh "<WORK>"`. Needs `chafa`
  (installed automatically). Tuning: env `N` (frames), `COLS` (override width),
  `FW`/`FH` (force frame size), `FILM` colors.
