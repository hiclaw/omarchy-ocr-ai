#!/usr/bin/env bash
#
# claw.ocr-ai — select a region of the screen and read the text in it.
#
# Usage:
#   capture-ocr.sh [LANGS]
#
# Exit codes (the caller uses these to tell "fine", "no text" and "broken" apart):
#   0  success: stdout holds the recognized text.
#      Also "the user cancelled the selection" — that exits 0 with no output.
#   3  a region was selected, but the image holds no recognizable text. Not an
#      error, but it should not be entirely silent either.
#   1  a real failure (missing dependency, capture or OCR error): the reason goes
#      to stderr, and the user has to see it.
#
# Environment:
#   OCR_LANGS   tesseract language argument, default eng (the LANGS argument wins)
#
# This is a pure "screen region → text" function: it writes no clipboard, shows
# no notification and produces no global side effect. Presentation and anything
# that follows are entirely the caller's business.
#
# Being interrupted by TERM/INT/HUP is normal: the caller does that when it
# hides the panel or restarts the shell. So this script has to hold the pids of
# its two background processes and reap them on every exit path. Leaving either
# one behind is a disaster: hyprpicker freezes the display, and slurp takes the
# input while showing nothing, so no later selection can ever come up.

set -uo pipefail

langs="${1:-${OCR_LANGS:-eng}}"
freeze_pid=""
slurp_pid=""
sel_file=""
tmp=""

cleanup() {
  [ -n "$slurp_pid" ] && kill "$slurp_pid" 2>/dev/null
  [ -n "$freeze_pid" ] && kill "$freeze_pid" 2>/dev/null
  [ -n "$sel_file" ] && rm -f "$sel_file"
  [ -n "$tmp" ] && rm -f "$tmp"
  return 0
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# A missing dependency must not just quietly do nothing — the user would have no
# way to tell what happened. Report it on stderr and exit 1, so the caller can
# put the reason on screen.
for cmd in hyprpicker slurp grim tesseract; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "Missing dependency: $cmd (OCR needs hyprpicker, slurp, grim and tesseract)" >&2
    exit 1
  }
done

# Freeze the display: the screen stands still while you select, and grim then
# captures that frozen frame, so transient things like an animation settling or
# this card closing never end up in the image (same as omarchy capture text).
hyprpicker -r -z >/dev/null 2>&1 &
freeze_pid=$!
sleep 0.1

# slurp runs in the background with its pid kept: Esc only makes it exit
# non-zero, while an interrupted script still has to be able to reap it (see the
# header).
sel_file="$(mktemp "${TMPDIR:-/tmp}/claw-ocr-ai-sel-XXXXXX")" \
  || { echo "Cannot create a temporary file (TMPDIR=${TMPDIR:-/tmp})" >&2; exit 1; }

slurp >"$sel_file" 2>/dev/null &
slurp_pid=$!
wait "$slurp_pid" || { slurp_pid=""; exit 0; }   # Esc: leave quietly
slurp_pid=""

selection="$(cat "$sel_file")"
[ -n "$selection" ] || exit 0

# Capture to a file and hand that to tesseract: in a pipeline the two exit codes
# cannot be told apart, so a failure would be indistinguishable between a broken
# capture and a broken OCR run — the only option left would be silence.
tmp="$(mktemp "${TMPDIR:-/tmp}/claw-ocr-ai-XXXXXX.png")" \
  || { echo "Cannot create a temporary file (TMPDIR=${TMPDIR:-/tmp})" >&2; exit 1; }

grim -g "$selection" "$tmp" 2>/dev/null \
  || { echo "Capture failed: grim could not grab the selected region" >&2; exit 1; }

raw="$(tesseract "$tmp" stdout --oem 1 --psm 6 -l "$langs" --dpi 300 \
        -c preserve_interword_spaces=1 2>/dev/null)" \
  || { echo "OCR failed: tesseract could not process that image" >&2; exit 1; }

# Strip trailing whitespace from every line and drop leading blank lines; a run
# that is nothing but whitespace counts as nothing recognized.
text="$(printf '%s' "$raw" | sed -e 's/[[:space:]]*$//' -e '/./,$!d')"
[ -n "${text//[[:space:]]/}" ] || exit 3

printf '%s' "$text"
