#!/usr/bin/env python3
"""faster-whisper backend for transcribe.sh. Configured through environment
variables so the shell script does not have to quote a long argv."""

import json
import os
import sys

from faster_whisper import WhisperModel

WAV = os.environ["FW_WAV"]
OUT = os.environ["FW_OUT"]
MODEL = os.environ.get("FW_MODEL", "large-v3")
LANG = os.environ.get("FW_LANG", "auto")
PROMPT = os.environ.get("FW_PROMPT") or None
# "off" past the duration threshold: carrying decoded text between windows is how
# one hallucinated window poisons every window after it on long recordings.
CONDITION = os.environ.get("FW_CONDITION", "on") != "off"

# int8 on CPU keeps a large model usable on a laptop; float16 is picked up
# automatically when a CUDA device is present.
device = "cuda" if os.environ.get("CUDA_VISIBLE_DEVICES") else "auto"
model = WhisperModel(MODEL, device=device, compute_type="auto")

segments, info = model.transcribe(
    WAV,
    language=None if LANG == "auto" else LANG,
    initial_prompt=PROMPT,
    vad_filter=True,  # drops long silences, which otherwise invite hallucinated text
    beam_size=5,
    condition_on_previous_text=CONDITION,
)

print(f"detected language: {info.language} (p={info.language_probability:.2f})",
      file=sys.stderr)


def ts(seconds: float) -> str:
    h, rem = divmod(seconds, 3600)
    m, s = divmod(rem, 60)
    return f"{int(h):02d}:{int(m):02d}:{int(s):02d},{int((s % 1) * 1000):03d}"


collected = []
with open(f"{OUT}.txt", "w") as ftxt, open(f"{OUT}.srt", "w") as fsrt:
    for i, seg in enumerate(segments, start=1):
        text = seg.text.strip()
        ftxt.write(text + "\n")
        fsrt.write(f"{i}\n{ts(seg.start)} --> {ts(seg.end)}\n{text}\n\n")
        collected.append({"start": seg.start, "end": seg.end, "text": text})
        if i % 50 == 0:
            print(f"  {seg.end/60:.0f} min transcribed", file=sys.stderr)

with open(f"{OUT}.json", "w") as fjson:
    json.dump({"language": info.language, "segments": collected}, fjson,
              ensure_ascii=False, indent=1)
