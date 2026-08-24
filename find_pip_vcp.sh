#!/usr/bin/env bash
#
# find_pip_vcp.sh — Discover the DDC/CI VCP code that BenQ Display Pilot
# sends to a PD3220U to toggle Picture-in-Picture (PIP), by scanning the
# monitor's manufacturer-specific VCP registers before and after you flip
# PIP on in Display Pilot, and diffing the results.
#
# WHY THIS TOOL:
# ddcutil does not run on macOS at all (Linux-only). ddcctl and m1ddc don't
# support Apple Silicon machines like a Mac Studio (M2 Pro/Max/Ultra).
# BetterDisplay (free, https://betterdisplay.dev) is the one tool with a
# working DDC/CI channel on Apple Silicon Macs, and as of v3.5.0 its CLI
# can get/set arbitrary raw VCP codes, not just its own named features.
#
# REQUIRES:
#   1. BetterDisplay.app installed (brew install --cask betterdisplay, or
#      download from betterdisplay.dev) and opened at least once, with
#      both PD3220U displays showing up in its own Displays list.
#   2. The betterdisplaycli tool, installed SEPARATELY from the app:
#        brew install waydabber/betterdisplay/betterdisplaycli
#      or download a release binary, or `sudo make install` from source.
#      (If you'd rather not install it separately, the app itself can run
#      CLI commands via /Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay
#      — edit the CLI= line below to point at that instead.)
#
# LISTING YOUR DISPLAYS (you have two identical PD3220U's, so -namelike
# alone is ambiguous — it would match both):
#
#   ./find_pip_vcp.sh list
#
#   Prints every connected display with its stable identifiers (tagID,
#   UUID, serial, alphanumericSerial, displayID, name). Note the -tagID=
#   or -serial= value for the unit you're testing — those are unique per
#   physical monitor, unlike the shared model name.
#
# CHECKING WHAT THE MONITOR ACTUALLY DECLARES SUPPORTED:
#
#   ./find_pip_vcp.sh caps '-tagID=12345'
#
#   Prints the monitor's raw DDC capabilities string — the set of VCP
#   codes it *claims* to support. Worth running before a scan: codes NOT
#   in this list are far more likely to produce noisy/garbage readings
#   (DDC monitors often reply with a "Null Message" for both "not ready,
#   retry" and "unsupported feature" — client tools can't always tell
#   those apart, so unsupported codes can read back stale or nonsense
#   values instead of a clean error).
#
# USAGE:
#   chmod +x find_pip_vcp.sh
#   ./find_pip_vcp.sh list                    # list displays, then exit
#   ./find_pip_vcp.sh caps '-tagID=12345'      # show declared capabilities, then exit
#   ./find_pip_vcp.sh '-tagID=12345'           # run the before/after PIP scan
#   ./find_pip_vcp.sh '-tagID=12345' full      # full 0x00-0xFF scan (slower)
#
#   The selector argument must be a SINGLE flag exactly as betterdisplaycli
#   expects it (quote it so the shell treats it as one token).

set -uo pipefail

CLI="$(command -v betterdisplaycli || true)"
if [[ -z "$CLI" ]]; then
  ALT="/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay"
  if [[ -x "$ALT" ]]; then
    CLI="$ALT"
  else
    echo "Could not find betterdisplaycli or $ALT."
    echo "Install with: brew install waydabber/betterdisplay/betterdisplaycli"
    echo "(or download from https://github.com/waydabber/betterdisplaycli, or"
    echo " point CLI at the BetterDisplay.app binary directly)."
    exit 1
  fi
fi

# --- Just list displays and exit -------------------------------------------
if [[ "${1:-}" == "list" ]]; then
  echo "Using CLI: $CLI"
  echo "Connected displays and their identifiers:"
  echo
  "$CLI" get -identifiers
  echo
  echo "Pick the -tagID= or -serial= value for the display you want to test,"
  echo "then run:  ./find_pip_vcp.sh '-tagID=<value>'"
  exit 0
fi

# --- Just show declared capabilities and exit -------------------------------
if [[ "${1:-}" == "caps" ]]; then
  SELECTOR="${2:?Usage: ./find_pip_vcp.sh caps '-tagID=<value>'}"
  echo "Using CLI: $CLI"
  echo "Raw DDC capabilities string for $SELECTOR:"
  echo
  "$CLI" get "$SELECTOR" -ddcCapabilitiesString
  echo
  echo "Look for a parenthesized list of hex VCP codes (same format ddcutil"
  echo "uses). Anything in the manufacturer range (0xE0-0xFF, sometimes shown"
  echo "without the leading '0x') that's declared here is a much stronger PIP"
  echo "candidate than a code that isn't listed at all."
  exit 0
fi

SELECTOR="${1:?Usage: ./find_pip_vcp.sh list | caps '-tagID=<value>' | '-tagID=<value>' [full]}"
SCAN_MODE="${2:-mfg}"

echo "Using CLI: $CLI"
echo "Targeting display: $SELECTOR"
echo

# --- Sanity check: can we talk DDC to this display at all? -----------------
# 0x10 is the standard "Brightness" VCP code, virtually every monitor
# supports it, so this just proves the DDC channel + selector work and
# that you've picked the display you think you've picked.
echo "Sanity check (reading brightness, VCP 0x10)..."
SANITY=$("$CLI" get "$SELECTOR" -feature=ddc -vcp=0x10 2>&1)
echo "  -> $SANITY"
if [[ -z "$SANITY" || "$SANITY" == *error* || "$SANITY" == *Error* ]]; then
  echo
  echo "That didn't look like a valid reading. Double-check the selector"
  echo "value against './find_pip_vcp.sh list' output before continuing —"
  echo "with two identical monitors it's easy to grab the wrong tagID/serial."
fi
echo

# --- Scan function -----------------------------------------------------
# We scan the DDC/CI manufacturer-reserved range (0xE0-0xFF) by default,
# since that's where custom features like BenQ/Dell PIP/PBP toggles almost
# always live (e.g. Dell's PBP toggle turned out to be 0xE9). Pass "full"
# as the 2nd argument to instead scan the entire 0x00-0xFF range (slower,
# ~4x longer, only useful if the manufacturer range comes back empty).
dump_vcp() {
  local outfile="$1"
  local mode="${2:-mfg}"
  local start=224 end=255   # 0xE0-0xFF
  if [[ "$mode" == "full" ]]; then
    start=0; end=255
  fi

  : > "$outfile"
  for ((i=start; i<=end; i++)); do
    code=$(printf '0x%02x' "$i")
    val=$("$CLI" get "$SELECTOR" -feature=ddc -vcp="$code" 2>/dev/null)
    if [[ -n "$val" && "$val" != *error* && "$val" != *Error* ]]; then
      echo "$code: $val" >> "$outfile"
    fi
  done
  local n
  n=$(wc -l < "$outfile" | tr -d ' ')
  echo "  -> $n responsive codes in $outfile."
}

# changed_codes f1 f2 — prints (sorted, unique) VCP codes whose value
# differs between f1 and f2, or that appear only in f2. Format of each
# line is "0xXX: <value>".
changed_codes() {
  awk -F': ' '
    NR==FNR { a[$1]=$2; next }
    { if (!($1 in a) || a[$1] != $2) print $1 }
  ' "$1" "$2" | sort -u
}

echo "=================================================================="
echo "STEP 0 — noise control"
echo "Taking two back-to-back readings of the SAME (unchanged) state, to"
echo "find any codes that are simply unstable/noisy on this monitor —"
echo "these should NOT be trusted later even if they also change between"
echo "your real before/after. Don't touch PIP or anything else yet."
echo "=================================================================="
dump_vcp control_a.txt "$SCAN_MODE"
dump_vcp control_b.txt "$SCAN_MODE"
NOISY="$(changed_codes control_a.txt control_b.txt)"
if [[ -n "$NOISY" ]]; then
  echo
  echo "These codes changed value with NOTHING actually changing — treat them"
  echo "as noise/unsupported, not as real PIP-related state, however they"
  echo "behave in the real diff below:"
  echo "$NOISY"
else
  echo "  -> No noise detected at rest. Good — any real diff below can be trusted."
fi

echo
echo "=================================================================="
echo "STEP 1"
echo "Make sure PIP is currently OFF on THIS display (check Display Pilot"
echo "/ the monitor's own OSD menu — confirm it's the right physical unit)."
echo "Press Enter when ready to take the BEFORE snapshot."
echo "=================================================================="
read -r
dump_vcp before.txt "$SCAN_MODE"

echo
echo "=================================================================="
echo "STEP 2"
echo "Now turn PIP ON on that same display — either in Display Pilot, or"
echo "directly via the monitor's own OSD joystick/buttons. Press Enter"
echo "once it's ON."
echo "=================================================================="
read -r
dump_vcp after.txt "$SCAN_MODE"

CHANGED="$(changed_codes before.txt after.txt)"
REAL="$(comm -23 <(printf '%s\n' "$CHANGED") <(printf '%s\n' "$NOISY") 2>/dev/null | grep -v '^$' || true)"

echo
echo "=================================================================="
echo "RESULTS"
echo "=================================================================="
echo "Full before -> after diff (for reference):"
diff before.txt after.txt || true
echo
echo "Codes that changed between before/after: ${CHANGED:-none}"
echo "Of those, codes that were ALSO noisy at rest (ignore these): ${NOISY:-none}"
echo "Codes that changed AND were stable at rest — your real candidates:"
echo "${REAL:-  (none — see notes below)}"
echo
if [[ -z "$REAL" ]]; then
  echo "No stable candidates survived. Two likely reasons:"
  echo "  1. PIP's VCP code is outside 0xE0-0xFF — re-run with 'full':"
  echo "       ./find_pip_vcp.sh '$SELECTOR' full"
  echo "  2. This monitor's DDC layer is generally noisy for unsupported"
  echo "     codes (common) — cross-check candidates against the declared"
  echo "     capabilities string first:"
  echo "       ./find_pip_vcp.sh caps '$SELECTOR'"
fi
echo
echo "Full dumps saved in $(pwd): control_a.txt, control_b.txt, before.txt, after.txt"
echo
echo "Next: once you've picked a real candidate code (say 0xXX), confirm it"
echo "standalone WITHOUT touching Display Pilot:"
echo
echo "  $CLI set $SELECTOR -feature=ddc -vcp=0xXX -value=0x00   # try PIP off"
echo "  $CLI set $SELECTOR -feature=ddc -vcp=0xXX -value=0x01   # try PIP on"
echo
echo "Remember: since you have two identical PD3220U's, re-run the whole"
echo "discovery against the SECOND display's selector too — BenQ units"
echo "usually share the same VCP map, but it's worth confirming before you"
echo "wire this into Home Assistant with per-monitor targeting."
