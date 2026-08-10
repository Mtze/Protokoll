#!/usr/bin/env bash
# One-time setup for local transcription.
#
# Usage: setup.sh [--model large-v3] [--engine whisper-cpp|mlx]
#
# Installs ffmpeg plus one transcription engine and downloads a model.
# Show the user what this will install before running it.

set -euo pipefail

MODEL="large-v3"
ENGINE="whisper-cpp"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model)  MODEL="${2:-}"; shift 2 ;;
    --engine) ENGINE="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

command -v brew >/dev/null || {
  echo "Homebrew not found. Install it from https://brew.sh, or install ffmpeg and" >&2
  echo "an engine (pip install mlx-whisper / faster-whisper) by hand." >&2
  exit 1
}

command -v ffmpeg >/dev/null || { echo "==> installing ffmpeg"; brew install ffmpeg; }

case "$ENGINE" in
  mlx)
    echo "==> installing mlx-whisper (Apple Silicon only)"
    pip install --upgrade mlx-whisper
    echo "==> done. Models download automatically on first use."
    ;;

  whisper-cpp)
    command -v whisper-cli >/dev/null || command -v whisper-cpp >/dev/null || {
      echo "==> installing whisper-cpp"; brew install whisper-cpp;
    }

    DEST="$HOME/.cache/whisper.cpp"
    mkdir -p "$DEST"
    TARGET="$DEST/ggml-$MODEL.bin"

    if [[ -f "$TARGET" ]]; then
      echo "==> model already present: $TARGET"
    else
      URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-$MODEL.bin"
      echo "==> downloading ggml-$MODEL.bin (about 1.6 GB for the large models)"
      echo "    from $URL"
      curl -L --fail --progress-bar -o "$TARGET.part" "$URL"
      mv "$TARGET.part" "$TARGET"
      echo "==> saved to $TARGET"
    fi
    ;;

  *)
    echo "unknown engine: $ENGINE (expected whisper-cpp or mlx)" >&2
    exit 1
    ;;
esac

echo
echo "Setup complete. Test it with:"
echo "  scripts/transcribe.sh some-recording.m4a --language de"
