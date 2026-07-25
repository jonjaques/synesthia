#!/usr/bin/env bash
#
# Captures a windowed and a full-screen screenshot of every registered
# visualizer into web/src/assets/screenshots/, under a prefix unique to this
# run (`--prefix`) so successive takes accumulate instead of overwriting. They
# live under src/ so the Astro site can run them through its image pipeline.
#
# The app is relaunched once per visualizer with `-visualizerID` in its
# argument domain (NSUserDefaults reads `-key value` pairs out of argv at the
# highest priority), which is both simpler and more deterministic than driving
# the Visualizer menu — every shot starts from a clean launch.
#
# Assumes Music.app is already playing: the default source is `musicApp`, and
# Synesthia latches system-audio capture onto it ~1.5 s after launch, so the
# now-playing badge and artwork appear on their own.
#
# Requires the invoking terminal to hold two permissions (System Settings ›
# Privacy & Security): Screen & System Audio Recording, for `screencapture`,
# and Accessibility, for sizing the window and moving the pointer. The script
# checks both before it starts.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/Synesthia.xcodeproj"

OUT_DIR="$ROOT/web/src/assets/screenshots"
CONFIGURATION="Debug"
APP=""
SIZE="1024x768"
SOURCE_KIND="musicApp"
SETTLE=8
MODE="window"
ONE_X=0
DO_BUILD=1
ONLY=()
# Every run writes under its own prefix, so a run never overwrites the previous
# set — comparing two takes (or two window sizes) is just an `ls`.
PREFIX=""
PREFIX_SET=0

usage() {
    cat <<'EOF'
Usage: scripts/take-screenshots.sh [options]

  --out DIR            Output directory (default: web/src/assets/screenshots)
  --size WxH           Windowed size in points (default: 1024x768)
  --configuration NAME Debug | Direct | Release (default: Debug)
  --app PATH           Use an existing .app instead of building
  --no-build           Skip xcodebuild, use the last build of --configuration
  --source KIND        demo | musicApp | systemAudio | inputDevice | audioFile
                       (default: musicApp)
  --settle SECONDS     Wait after launch before capturing (default: 8)
  --only ID[,ID...]    Only these visualizer ids (default: all registered)
  --mode window|region Window capture keeps rounded corners on transparency;
                       region captures the raw screen rect (default: window)
  --1x                 Downsample Retina output to the logical point size
  --prefix STR         Prefix for this run's filenames (default: a UTC
                       timestamp, e.g. 20260725-174312Z-nebula-windowed.png).
                       Pass an empty string for unprefixed names.
  -h, --help           Show this message

Files are named <prefix>-<visualizer>-<windowed|fullscreen>.png, so each run
lands beside the previous one instead of overwriting it.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --out) OUT_DIR="$2"; shift 2 ;;
        --size) SIZE="$2"; shift 2 ;;
        --configuration) CONFIGURATION="$2"; shift 2 ;;
        --app) APP="$2"; DO_BUILD=0; shift 2 ;;
        --no-build) DO_BUILD=0; shift ;;
        --source) SOURCE_KIND="$2"; shift 2 ;;
        --settle) SETTLE="$2"; shift 2 ;;
        --only) IFS=, read -r -a ONLY <<< "$2"; shift 2 ;;
        --mode) MODE="$2"; shift 2 ;;
        --1x) ONE_X=1; shift ;;
        --prefix) PREFIX="$2"; PREFIX_SET=1; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

WIDTH="${SIZE%%x*}"
HEIGHT="${SIZE##*x}"
if [[ ! "$WIDTH" =~ ^[0-9]+$ || ! "$HEIGHT" =~ ^[0-9]+$ ]]; then
    echo "invalid --size '$SIZE' (expected WxH, e.g. 1024x768)" >&2
    exit 2
fi

# UTC to the second: sortable, and a full run takes far longer than a second,
# so it can't collide with itself.
[[ $PREFIX_SET -eq 1 ]] || PREFIX="$(date -u +%Y%m%d-%H%M%SZ)"
# A prefix becomes a filename, so keep it to characters that survive the web.
if [[ -n "$PREFIX" && ! "$PREFIX" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "invalid --prefix '$PREFIX' (letters, digits, dot, underscore, hyphen)" >&2
    exit 2
fi
NAME_PREFIX="${PREFIX:+$PREFIX-}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/synesthia-screenshots.XXXXXX")"
SHOTKIT="$WORK/shotkit"
APP_PID=""
MOUSE_HOME=""

cleanup() {
    if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then
        kill "$APP_PID" 2>/dev/null || true
    fi
    if [[ -n "$MOUSE_HOME" && -x "$SHOTKIT" ]]; then
        # shellcheck disable=SC2086 # MOUSE_HOME is a deliberate "x y" pair
        "$SHOTKIT" jiggle $MOUSE_HOME 2>/dev/null || true
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }

# ---------------------------------------------------------------- preflight

step "Building the shotkit helper"
xcrun swiftc -O -o "$SHOTKIT" "$ROOT/scripts/shotkit.swift"

step "Checking permissions"
if [[ "$("$SHOTKIT" ax-trusted || true)" != "yes" ]]; then
    cat >&2 <<EOF
This terminal is not trusted for Accessibility, so the window can't be resized
or the pointer moved.

  Open System Settings › Privacy & Security › Accessibility, add (or enable)
  the app you are running this from — Terminal, iTerm, or your editor — then
  quit and reopen it and run this script again.
EOF
    exit 1
fi
info "Accessibility: ok"

if ! screencapture -x -R 0,0,8,8 "$WORK/probe.png" 2>/dev/null || [[ ! -s "$WORK/probe.png" ]]; then
    cat >&2 <<EOF
\`screencapture\` produced nothing, which means this terminal lacks screen
recording access.

  Open System Settings › Privacy & Security › Screen & System Audio Recording,
  add (or enable) the app you are running this from, then quit and reopen it
  and run this script again.
EOF
    exit 1
fi
info "Screen recording: ok"

# ------------------------------------------------------------------- inputs

# Registry order (which is also the Visualizer menu's Cmd-N order) comes from
# VisualizerCore.swift; each descriptor's id comes from its own file, so a
# newly registered visualizer is picked up without touching this script.
registered_visualizers() {
    local core="$ROOT/Synesthia/Visualizers/VisualizerCore.swift"
    local type file id
    while read -r type; do
        file="$ROOT/Synesthia/Visualizers/$type.swift"
        [[ -f "$file" ]] || continue
        id="$(grep -m1 -oE 'id: "[^"]+"' "$file" | sed -E 's/id: "(.*)"/\1/')"
        [[ -n "$id" ]] && echo "$id"
    done < <(sed -n '/static var all/,/^ *\]/p' "$core" \
             | grep -oE '[A-Za-z]+Visualizer\.descriptor' \
             | sed 's/\.descriptor//')
}

IFS=$'\n' read -r -d '' -a VISUALIZERS < <(registered_visualizers && printf '\0')
if [[ ${#VISUALIZERS[@]} -eq 0 ]]; then
    echo "found no visualizers in VisualizerRegistry" >&2
    exit 1
fi
if [[ ${#ONLY[@]} -gt 0 ]]; then
    # An unregistered id would silently fall back to the first visualizer and
    # be saved under the wrong name, so reject it here instead.
    for wanted in "${ONLY[@]}"; do
        [[ " ${VISUALIZERS[*]} " == *" $wanted "* ]] \
            || { echo "unknown visualizer '$wanted' (registered: ${VISUALIZERS[*]})" >&2; exit 2; }
    done
    VISUALIZERS=("${ONLY[@]}")
fi

if [[ -z "$APP" ]]; then
    if [[ $DO_BUILD -eq 1 ]]; then
        step "Building Synesthia ($CONFIGURATION)"
        xcodebuild -project "$PROJECT" -scheme Synesthia \
                   -configuration "$CONFIGURATION" build >"$WORK/build.log" 2>&1 \
            || { tail -40 "$WORK/build.log" >&2; echo "build failed — full log: $WORK/build.log" >&2; exit 1; }
    fi
    PRODUCTS_DIR="$(xcodebuild -project "$PROJECT" -scheme Synesthia \
                               -configuration "$CONFIGURATION" -showBuildSettings 2>/dev/null \
                    | awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $2; exit}')"
    APP="$PRODUCTS_DIR/Synesthia.app"
fi
if [[ ! -d "$APP" ]]; then
    echo "no app bundle at $APP (build it, or pass --app PATH)" >&2
    exit 1
fi

mkdir -p "$OUT_DIR"
MOUSE_HOME="$("$SHOTKIT" mouse-get)"
read -r _ _ DISPLAY_W DISPLAY_H < <("$SHOTKIT" display)

step "Capturing ${#VISUALIZERS[@]} visualizer(s)"
info "app:    $APP"
info "source: $SOURCE_KIND"
info "out:    $OUT_DIR"
info "prefix: ${NAME_PREFIX:-(none)}"

# -------------------------------------------------------------------- driver

quit_app() {
    pkill -x Synesthia 2>/dev/null || true
    for _ in $(seq 1 40); do
        pgrep -x Synesthia >/dev/null || return 0
        sleep 0.25
    done
    pkill -9 -x Synesthia 2>/dev/null || true
    sleep 0.5
}

# Launches the app for one visualizer and echoes its pid. `hasSeenWelcome`
# keeps the first-run sheet from covering the canvas; none of these argument
# values are written back to the user's preferences.
launch_app() {
    local visualizer="$1" pid=""
    open -a "$APP" --args \
        -hasSeenWelcome YES \
        -sourceKind "$SOURCE_KIND" \
        -visualizerID "$visualizer"
    for _ in $(seq 1 60); do
        pid="$(pgrep -x Synesthia | head -1 || true)"
        [[ -n "$pid" ]] && break
        sleep 0.25
    done
    [[ -n "$pid" ]] || { echo "Synesthia did not start" >&2; return 1; }
    # The process exists well before the window does.
    for _ in $(seq 1 60); do
        "$SHOTKIT" window "$pid" >/dev/null 2>&1 && { echo "$pid"; return 0; }
        sleep 0.25
    done
    echo "Synesthia opened no window" >&2
    return 1
}

# The bottom chrome fades out after 3 s of pointer stillness, so every capture
# is preceded by a pointer nudge inside the window plus enough time for the
# 0.35 s fade-in to finish.
show_chrome_at() {
    "$SHOTKIT" jiggle "$1" "$2"
    sleep 0.6
}

# capture <pid> <output.png>
capture() {
    local pid="$1" out="$2" id x y w h
    read -r id x y w h < <("$SHOTKIT" window "$pid") || true
    [[ -n "${h:-}" ]] || { echo "lost the Synesthia window before capturing $out" >&2; return 1; }
    if [[ "$MODE" == "region" ]]; then
        screencapture -x -R "$x,$y,$w,$h" "$out"
    else
        screencapture -x -o -l "$id" "$out"
    fi
    [[ -s "$out" ]] || { echo "capture produced nothing for $out" >&2; return 1; }
    if [[ $ONE_X -eq 1 ]]; then
        sips --resampleHeightWidth "$h" "$w" "$out" >/dev/null
    fi
    info "$(basename "$out")  $(sips -g pixelWidth -g pixelHeight "$out" \
        | awk '/pixelWidth/{w=$2} /pixelHeight/{h=$2} END{print w"x"h}')"
}

for visualizer in "${VISUALIZERS[@]}"; do
    step "$visualizer"
    quit_app
    APP_PID="$(launch_app "$visualizer")"
    "$SHOTKIT" activate "$APP_PID"

    # A previous run (or restored state) may have left the window full screen.
    if [[ "$("$SHOTKIT" is-fullscreen "$APP_PID")" == "1" ]]; then
        "$SHOTKIT" fullscreen "$APP_PID" 0
        sleep 1.5
    fi
    # The Accessibility window can trail the window-server one by a moment.
    for attempt in $(seq 1 20); do
        "$SHOTKIT" resize "$APP_PID" "$WIDTH" "$HEIGHT" 2>/dev/null && break
        [[ $attempt -lt 20 ]] || { "$SHOTKIT" resize "$APP_PID" "$WIDTH" "$HEIGHT"; }
        sleep 0.25
    done

    # Long enough for capture to latch onto Music, the analyzer to fill, the
    # visuals to develop, and the artwork poll (which retries) to land.
    sleep "$SETTLE"

    read -r _ wx wy ww wh < <("$SHOTKIT" window "$APP_PID") || true
    [[ -n "${wh:-}" ]] || { echo "lost the Synesthia window" >&2; exit 1; }
    show_chrome_at "$((wx + ww / 2))" "$((wy + wh / 2))"
    capture "$APP_PID" "$OUT_DIR/$NAME_PREFIX$visualizer-windowed.png"

    "$SHOTKIT" activate "$APP_PID"
    "$SHOTKIT" fullscreen "$APP_PID" 1
    sleep 2.5
    show_chrome_at "$((DISPLAY_W / 2))" "$((DISPLAY_H / 2))"
    capture "$APP_PID" "$OUT_DIR/$NAME_PREFIX$visualizer-fullscreen.png"

    "$SHOTKIT" fullscreen "$APP_PID" 0
    sleep 1.5
done

quit_app
APP_PID=""

step "Done"
# This run only — earlier runs are still sitting in the same directory.
ls -1 "$OUT_DIR/$NAME_PREFIX"*.png
