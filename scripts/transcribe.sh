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
#   --preprocess MODE        off | safe (default: safe) - see "audio prep" below
#   --condition MODE         auto | on | off - carry decoded text between windows
#   --print-engine           print the engine that would be used, then exit
#   --self-test              check the gain policy against its cases, then exit

set -euo pipefail

LANGUAGE="auto"
MODEL="large-v3"
OUTPUT_DIR=""
ENGINE=""
PROMPT=""
THREADS=""
KEEP_WAV=0
PREPROCESS="safe"
CONDITION="auto"
PRINT_ENGINE=0
INPUT=""

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
info() { printf '==> %s\n' "$1" >&2; }

# ------------------------------------------------------------------ gain policy
# compute_gain INTEGRATED_LUFS TRUE_PEAK_DBFS -> gain in dB, toward -20 LUFS.
#
# The peak ceiling only ever limits how much we *boost*; it must never cause an
# attenuation. An earlier version let the ceiling win outright, which is wrong
# for audio that is already clipped, and it silently cost real speech: measured
# on a real meeting, integrated -28.3 LUFS with a true peak of +15.3 dBFS
# produced -16.3 dB of "correction", taking the signal to -44.6 LUFS - past the
# point where Whisper degrades sharply. Same five minutes of audio: 741 words
# unattenuated, 528 words after that gain, and 3.5 minutes of speech replaced by
# one stock phrase per 30-second window in the full run.
#
# Attenuating cannot undo clipping that is already baked into the samples; it
# only makes the speech quieter, which is the one thing that reliably hurts.
#
# Run `transcribe.sh --self-test` to check this against its cases.
compute_gain() {
  awk -v i="$1" -v p="$2" 'BEGIN{
    want = -20 - i;            # gain needed to reach the loudness target
    head = -1 - p;             # gain that would put the true peak at the ceiling
    if (want <= 0) { g = want }              # cutting also lowers the peak: safe
    else { if (head < 0) head = 0;           # already at/over the ceiling: no boost
           g = (want < head) ? want : head } # boost, but not into clipping
    if (g > 20) g = 20; if (g < -20) g = -20; printf "%.2f", g }'
}

# Self-test for the pure logic above. Deliberately part of the script rather than
# a separate file: the script is vendored into the app bundle and must stay
# standalone, and this is the coverage gap that let the bug above ship.
self_test() {
  local failures=0
  check() { # check DESCRIPTION INTEGRATED PEAK EXPECTED
    local got; got="$(compute_gain "$2" "$3")"
    if [[ "$got" == "$4" ]]; then
      printf '  ok    %-46s %sdB\n' "$1" "$got"
    else
      printf '  FAIL  %-46s got %sdB, want %sdB\n' "$1" "$got" "$4"; failures=$((failures+1))
    fi
  }
  echo "compute_gain:"
  # The regression: already-clipped and quiet must be left alone, never cut.
  check "clipped + quiet (real meeting)"        -28.3  15.3  "0.00"
  check "clipped + quiet, extreme peak"         -30.0  40.0  "0.00"
  check "quiet with headroom (boost, clamped)"  -50.2 -45.6  "20.00"
  check "quiet, headroom-limited boost"         -30.0  -6.0  "5.00"
  check "too loud (cutting is safe)"             -8.0  -3.0  "-12.00"
  check "already at target"                     -20.0  -6.0  "0.00"
  check "loud and clipped (cut toward target)"   -5.0   3.0  "-15.00"
  check "cut clamped at -20 dB"                  10.0  -1.0  "-20.00"
  check "peak exactly at the ceiling"           -25.0  -1.0  "0.00"
  if [[ $failures -eq 0 ]]; then echo "all passed"; return 0; fi
  echo "$failures failure(s)" >&2; return 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --language)     LANGUAGE="${2:-}"; shift 2 ;;
    --model)        MODEL="${2:-}"; shift 2 ;;
    --output-dir)   OUTPUT_DIR="${2:-}"; shift 2 ;;
    --engine)       ENGINE="${2:-}"; shift 2 ;;
    --prompt)       PROMPT="${2:-}"; shift 2 ;;
    --threads)      THREADS="${2:-}"; shift 2 ;;
    --keep-wav)     KEEP_WAV=1; shift ;;
    --preprocess)   PREPROCESS="${2:-}"; shift 2 ;;
    --condition)    CONDITION="${2:-}"; shift 2 ;;
    --print-engine) PRINT_ENGINE=1; shift ;;
    --self-test)    self_test; exit $? ;;
    -h|--help)      sed -n '2,15p' "$0"; exit 0 ;;
    -*)             die "unknown option: $1" ;;
    *)              [[ -n "$INPUT" ]] && die "more than one input file given"; INPUT="$1"; shift ;;
  esac
done

case "$PREPROCESS" in off|safe) ;; *) die "--preprocess must be off or safe" ;; esac
case "$CONDITION" in auto|on|off) ;; *) die "--condition must be auto, on or off" ;; esac

# ---------------------------------------------------------------- engine pick
detect_engine() {
  # Ordered by speed on the hardware people actually run this on. Diagnostics
  # mirrors this order; `--print-engine` is the single source of truth.
  command -v mlx_whisper  >/dev/null && { echo "mlx-whisper";  return; }
  command -v whisper-cli  >/dev/null && { echo "whisper-cpp";  return; }
  command -v whisper-cpp  >/dev/null && { echo "whisper-cpp";  return; }
  python3 -c "import faster_whisper" 2>/dev/null && { echo "faster-whisper"; return; }
  command -v whisper      >/dev/null && { echo "openai-whisper"; return; }
  echo ""
}

[[ -n "$ENGINE" ]] || ENGINE="$(detect_engine)"

if [[ $PRINT_ENGINE -eq 1 ]]; then
  printf '%s\n' "${ENGINE:-none}"
  exit 0
fi

[[ -n "$INPUT" ]] || die "no input file. Usage: transcribe.sh RECORDING [options]"
[[ -f "$INPUT" ]] || die "file not found: $INPUT"
command -v ffmpeg >/dev/null || die "ffmpeg is required. Install it with: brew install ffmpeg"

INPUT="$(cd "$(dirname "$INPUT")" && pwd)/$(basename "$INPUT")"
BASE="$(basename "${INPUT%.*}")"
[[ -n "$OUTPUT_DIR" ]] || OUTPUT_DIR="$(dirname "$INPUT")"
mkdir -p "$OUTPUT_DIR"

if [[ -z "$ENGINE" ]]; then
  cat >&2 <<'EOF'
error: no local transcription engine found.

Install one of these, then run this script again:

  Apple Silicon, fastest:   uv tool install mlx-whisper
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
#
# --preprocess safe (the default) adds two provably-conservative steps:
#
#   highpass=f=80   removes mains hum, HVAC rumble and desk thumps. Male speech
#                   F0 bottoms out near 85 Hz, so this is transparent to speech.
#   volume=NdB      a single *static* gain toward -20 LUFS, measured first with
#                   ebur128 and clamped so the true peak never exceeds -1 dBFS.
#
# Deliberately NOT here:
#   * loudnorm - its LRA parameter is dynamic-range compression, i.e. a
#     time-varying non-linear transform, and it costs ~75 s per hour of audio
#     versus ~6 s for measure-then-apply.
#   * any denoiser (afftdn/arnndn/DeepFilterNet) - spectral denoising is
#     measured to *raise* WER for large Whisper models (ICAART 2024: helps
#     base/small, hurts medium/large/large-v2). Do not enable one without an
#     A/B on real audio.
#   * silenceremove - it compacts the output timeline, which would desynchronise
#     every transcript timestamp after the first pause and break tap-to-seek.
WORKDIR="$(mktemp -d)"
cleanup() { [[ $KEEP_WAV -eq 1 ]] || rm -rf "$WORKDIR"; }
trap cleanup EXIT

WAV="$WORKDIR/$BASE.wav"
FILTERS=""

if [[ "$PREPROCESS" == "safe" ]]; then
  info "measuring loudness (ebur128)"
  # Measure through the same highpass the apply pass uses, so the figures match
  # what the engine will actually see.
  STATS="$(ffmpeg -nostdin -hide_banner -i "$INPUT" -vn \
    -af "aresample=16000,highpass=f=80,ebur128=framelog=quiet:peak=true" \
    -f null - 2>&1 || true)"
  INTEGRATED="$(printf '%s\n' "$STATS" | awk '/^ +I: /{print $2}' | tail -1)"
  TRUEPEAK="$(printf '%s\n' "$STATS" | awk '/^ +Peak: /{print $2}' | tail -1)"

  if [[ -n "$INTEGRATED" && -n "$TRUEPEAK" ]]; then
    GAIN="$(compute_gain "$INTEGRATED" "$TRUEPEAK")"
    if awk -v p="$TRUEPEAK" 'BEGIN{exit !(+p > 0)}'; then
      # Worth saying out loud: the recording is already clipped, so some detail is
      # gone before we ever see it. Check the input level at the source.
      info "warning: source audio is clipped (true peak ${TRUEPEAK} dBFS); lower the input level when recording"
    fi
    info "loudness ${INTEGRATED} LUFS, true peak ${TRUEPEAK} dBFS -> applying ${GAIN} dB"
    FILTERS="highpass=f=80,volume=${GAIN}dB"
  else
    # ebur128 output not parseable (very short or odd input): high-pass only.
    info "could not measure loudness; applying high-pass only"
    FILTERS="highpass=f=80"
  fi
fi

info "converting to 16 kHz mono wav"
if [[ -n "$FILTERS" ]]; then
  ffmpeg -nostdin -loglevel error -y -i "$INPUT" -vn -ac 1 -ar 16000 -c:a pcm_s16le \
    -af "$FILTERS" "$WAV" || die "ffmpeg could not decode $INPUT"
else
  ffmpeg -nostdin -loglevel error -y -i "$INPUT" -vn -ac 1 -ar 16000 -c:a pcm_s16le "$WAV" \
    || die "ffmpeg could not decode $INPUT"
fi

DURATION="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$WAV" 2>/dev/null || echo 0)"
printf '==> audio: %.1f minutes\n' "$(echo "$DURATION" | awk '{print $1/60}')" >&2

if [[ $KEEP_WAV -eq 1 ]]; then
  cp "$WAV" "$OUTPUT_DIR/$BASE.wav"
fi

# ------------------------------------------------------- previous-text conditioning
# Whisper feeds each window's decoded text to the next as a prompt. It helps
# local fluency, but it is also how one hallucinated window poisons everything
# after it: on a real 52-minute German meeting this produced 6 degenerate runs
# (the worst 141 consecutive 1-second segments) and made the run 4.3x slower,
# because the engine re-decodes a looping window at escalating temperatures.
#
# It is duration-gated, not off outright: on a short clip disabling it measurably
# *hurt* (lowercase, unpunctuated output), while on the full-length file it was
# decisively better. `auto` therefore keeps conditioning for short recordings and
# drops it past the threshold, where collapse becomes the dominant risk.
CONDITION_THRESHOLD_SECONDS=${CONDITION_THRESHOLD_SECONDS:-600}
CONDITION_EFFECTIVE="$CONDITION"
if [[ "$CONDITION" == "auto" ]]; then
  # `+d` and `+t` force numeric coercion. Without it a non-numeric ffprobe
  # result ("N/A") would be compared as a *string*, and "N/A" > "600" is true,
  # silently disabling conditioning on files whose duration could not be read.
  if awk -v d="$DURATION" -v t="$CONDITION_THRESHOLD_SECONDS" 'BEGIN{exit !(+d > +t)}'; then
    CONDITION_EFFECTIVE="off"
  else
    CONDITION_EFFECTIVE="on"
  fi
fi
info "previous-text conditioning: $CONDITION_EFFECTIVE (audio ${DURATION}s, threshold ${CONDITION_THRESHOLD_SECONDS}s)"

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
    [[ "$CONDITION_EFFECTIVE" == "off" ]] && ARGS+=(--condition-on-previous-text False)
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
    # whisper.cpp spells this as --no-context (-nc): do not carry the previous
    # window's transcription forward as the next window's initial prompt.
    [[ "$CONDITION_EFFECTIVE" == "off" ]] && ARGS+=(--no-context)
    "$BIN" "${ARGS[@]}"
    ;;

  faster-whisper)
    FW_LANG="$LANGUAGE" FW_PROMPT="$PROMPT" FW_MODEL="$MODEL" \
    FW_WAV="$WAV" FW_OUT="$OUTPUT_DIR/$BASE" FW_CONDITION="$CONDITION_EFFECTIVE" \
    python3 "$(dirname "$0")/faster_whisper_run.py"
    ;;

  openai-whisper)
    ARGS=(--model "$MODEL" --output_dir "$OUTPUT_DIR" --output_format all --verbose False)
    [[ "$LANGUAGE" != "auto" ]] && ARGS+=(--language "$LANGUAGE")
    [[ -n "$PROMPT" ]] && ARGS+=(--initial_prompt "$PROMPT")
    [[ "$CONDITION_EFFECTIVE" == "off" ]] && ARGS+=(--condition_on_previous_text False)
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
