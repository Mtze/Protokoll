#!/usr/bin/env bash
# Transcribe an audio or video recording locally. No audio leaves this machine.
#
# Usage: transcribe.sh RECORDING [options]
#   --language de            language code, or "auto" (pass one, auto-detect is unreliable)
#   --model large-v3         large-v3 | large-v3-turbo | medium | small
#   --output-dir DIR         default: the recording's directory
#   --engine NAME            mlx-whisper | whisper-cpp | faster-whisper | openai-whisper
#   --prompt "..."           domain vocabulary hint
#   --threads N              CPU threads (whisper.cpp only, default: core count)
#   --keep-wav               keep the intermediate 16 kHz wav

set -euo pipefail

LANGUAGE="auto"
MODEL="large-v3"
OUTPUT_DIR=""
ENGINE=""
PROMPT=""
THREADS=""
KEEP_WAV=0
INPUT=""

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
info() { printf '==> %s\n' "$1" >&2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --language)   LANGUAGE="${2:-}"; shift 2 ;;
    --model)      MODEL="${2:-}"; shift 2 ;;
    --output-dir) OUTPUT_DIR="${2:-}"; shift 2 ;;
    --engine)     ENGINE="${2:-}"; shift 2 ;;
    --prompt)     PROMPT="${2:-}"; shift 2 ;;
    --threads)    THREADS="${2:-}"; shift 2 ;;
    --keep-wav)   KEEP_WAV=1; shift ;;
    -h|--help)    sed -n '2,14p' "$0"; exit 0 ;;
    -*)           die "unknown option: $1" ;;
    *)            [[ -n "$INPUT" ]] && die "more than one input file given"; INPUT="$1"; shift ;;
  esac
done

[[ -n "$INPUT" ]] || die "no input file. Usage: transcribe.sh RECORDING [options]"
[[ -f "$INPUT" ]] || die "file not found: $INPUT"
command -v ffmpeg >/dev/null || die "ffmpeg is required. Install it with: brew install ffmpeg"

INPUT="$(cd "$(dirname "$INPUT")" && pwd)/$(basename "$INPUT")"
BASE="$(basename "${INPUT%.*}")"
[[ -n "$OUTPUT_DIR" ]] || OUTPUT_DIR="$(dirname "$INPUT")"
mkdir -p "$OUTPUT_DIR"

# ---------------------------------------------------------------- engine pick
detect_engine() {
  # Ordered by speed on the hardware people actually run this on.
  command -v mlx_whisper  >/dev/null && { echo "mlx-whisper";  return; }
  command -v whisper-cli  >/dev/null && { echo "whisper-cpp";  return; }
  command -v whisper-cpp  >/dev/null && { echo "whisper-cpp";  return; }
  python3 -c "import faster_whisper" 2>/dev/null && { echo "faster-whisper"; return; }
  command -v whisper      >/dev/null && { echo "openai-whisper"; return; }
  echo ""
}

[[ -n "$ENGINE" ]] || ENGINE="$(detect_engine)"

if [[ -z "$ENGINE" ]]; then
  cat >&2 <<'EOF'
error: no local transcription engine found.

Install one of these, then run this script again:

  Apple Silicon, fastest:   pip install mlx-whisper
  Portable, no Python:      brew install whisper-cpp   (then run scripts/setup.sh for the model)
  Nvidia GPU or CPU:        pip install faster-whisper

Do not substitute a cloud transcription service. Meeting audio stays on this machine.
EOF
  exit 1
fi

info "engine: $ENGINE, model: $MODEL, language: $LANGUAGE"

# ------------------------------------------------------------------ audio prep
# 16 kHz mono PCM is what every Whisper implementation wants internally.
# Doing the conversion here rather than letting the engine shell out to ffmpeg
# keeps behaviour identical across engines and surfaces decode errors early.
WORKDIR="$(mktemp -d)"
cleanup() { [[ $KEEP_WAV -eq 1 ]] || rm -rf "$WORKDIR"; }
trap cleanup EXIT

WAV="$WORKDIR/$BASE.wav"
info "converting to 16 kHz mono wav"
ffmpeg -nostdin -loglevel error -y -i "$INPUT" -vn -ac 1 -ar 16000 -c:a pcm_s16le "$WAV" \
  || die "ffmpeg could not decode $INPUT"

DURATION="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$WAV" 2>/dev/null || echo 0)"
printf '==> audio: %.1f minutes\n' "$(echo "$DURATION" | awk '{print $1/60}')" >&2

if [[ $KEEP_WAV -eq 1 ]]; then
  cp "$WAV" "$OUTPUT_DIR/$BASE.wav"
fi

# ----------------------------------------------------------------- model names
mlx_model() {
  case "$1" in
    large-v3-turbo) echo "mlx-community/whisper-large-v3-turbo" ;;
    large-v3)       echo "mlx-community/whisper-large-v3-mlx" ;;
    *)              echo "mlx-community/whisper-$1-mlx" ;;
  esac
}

find_ggml_model() {
  local name="$1" f
  for f in \
    "$HOME/.cache/whisper.cpp/ggml-$name.bin" \
    "$HOME/Library/Application Support/whisper.cpp/ggml-$name.bin" \
    "/opt/homebrew/share/whisper-cpp/ggml-$name.bin" \
    "/usr/local/share/whisper-cpp/ggml-$name.bin" \
    "./models/ggml-$name.bin"
  do
    [[ -f "$f" ]] && { echo "$f"; return 0; }
  done
  return 1
}

# --------------------------------------------------------------------- run it
START=$(date +%s)

case "$ENGINE" in
  mlx-whisper)
    ARGS=(--model "$(mlx_model "$MODEL")" --output-dir "$OUTPUT_DIR"
          --output-name "$BASE" --output-format all --verbose False)
    [[ "$LANGUAGE" != "auto" ]] && ARGS+=(--language "$LANGUAGE")
    [[ -n "$PROMPT" ]] && ARGS+=(--initial-prompt "$PROMPT")
    mlx_whisper "$WAV" "${ARGS[@]}"
    ;;

  whisper-cpp)
    BIN="$(command -v whisper-cli || command -v whisper-cpp)"
    if ! MODEL_PATH="$(find_ggml_model "$MODEL")"; then
      die "ggml model for '$MODEL' not found. Run scripts/setup.sh --model $MODEL to download it."
    fi
    info "model file: $MODEL_PATH"
    ARGS=(-m "$MODEL_PATH" -f "$WAV" -otxt -osrt -oj -of "$OUTPUT_DIR/$BASE" -pp)
    [[ "$LANGUAGE" != "auto" ]] && ARGS+=(-l "$LANGUAGE")
    [[ -n "$PROMPT" ]] && ARGS+=(--prompt "$PROMPT")
    [[ -n "$THREADS" ]] && ARGS+=(-t "$THREADS")
    "$BIN" "${ARGS[@]}"
    ;;

  faster-whisper)
    FW_LANG="$LANGUAGE" FW_PROMPT="$PROMPT" FW_MODEL="$MODEL" \
    FW_WAV="$WAV" FW_OUT="$OUTPUT_DIR/$BASE" \
    python3 "$(dirname "$0")/faster_whisper_run.py"
    ;;

  openai-whisper)
    ARGS=(--model "$MODEL" --output_dir "$OUTPUT_DIR" --output_format all --verbose False)
    [[ "$LANGUAGE" != "auto" ]] && ARGS+=(--language "$LANGUAGE")
    [[ -n "$PROMPT" ]] && ARGS+=(--initial_prompt "$PROMPT")
    whisper "$WAV" "${ARGS[@]}"
    ;;

  *)
    die "unknown engine: $ENGINE"
    ;;
esac

ELAPSED=$(( $(date +%s) - START ))

printf '\n==> done in %dm %ds\n' $((ELAPSED/60)) $((ELAPSED%60)) >&2
for ext in txt srt json; do
  [[ -f "$OUTPUT_DIR/$BASE.$ext" ]] && printf '    %s\n' "$OUTPUT_DIR/$BASE.$ext" >&2
done
exit 0
