#!/usr/bin/env bash
#
# Captures a windowed and a full-screen screenshot of every registered
# visualizer into web/src/assets/screenshots/<run>/, one folder per run with
# plain `<visualizer>-<windowed|fullscreen>.png` names inside it, plus an
# `app-store/` subfolder holding the same shots conformed to App Store Connect's
# requirements. `--run ''` writes the bare names straight into the output
# directory instead, which is how the site's committed assets get refreshed;
# they live under src/ so Astro runs them through its image pipeline.
#
# App Store Connect accepts a Mac screenshot only at 1280x800, 1440x900,
# 2560x1600 or 2880x1800 (16:10), as PNG or JPEG, and **with no alpha channel**.
# A window capture fails two of those on its own: it is whatever size the window
# was, and `screencapture -o` keeps the rounded corners transparent. So every
# shot is redrawn by `shotkit compose` onto an opaque canvas of exactly the
# target size — scaled to fit, never cropped, so nothing is lost — and the result
# is asserted to be alpha-free, because a stray alpha channel is a rejection that
# nothing else here would catch. The windowed size defaults to the largest 16:10
# box that fits the display, capped at 1440x900 points, which is 2880x1800 pixels
# at 2x: the largest accepted size, reached with no rescaling at all.
#
# The app is relaunched once per visualizer with `-visualizerID` in its
# argument domain (NSUserDefaults reads `-key value` pairs out of argv at the
# highest priority), which is both simpler and more deterministic than driving
# the Visualizer menu — every shot starts from a clean launch.
#
# Music.app is driven over Apple Events so the set isn't eight shots of one
# song: playback is started before the first capture and advanced one track per
# visualizer (`--music`, `--playlist`). The advance happens *after* the app is up,
# so the badge is filled by the distributed notification Synesthia listens for
# rather than by a launch-time poll — which is the only path the App Store build
# has, since `#if MUSIC_APP_SOURCE` strips PlayerRemote out of it. The default
# source is `systemAudio`, and `-playerControlEnabled YES` lets the Direct build
# also fetch cover art.
#
# Requires the invoking terminal to hold three permissions (System Settings ›
# Privacy & Security): Screen & System Audio Recording, for `screencapture`;
# Accessibility, for sizing the window and moving the pointer; and Automation ›
# Music, for the track changes. The script checks all three before it starts.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/Synesthia.xcodeproj"

OUT_DIR="$ROOT/web/src/assets/screenshots"
CONFIGURATION="Debug"
APP=""
SIZE=""
SOURCE_KIND="systemAudio"
SETTLE=8
MODE="window"
ONE_X=0
DO_BUILD=1
ONLY=()
# Every run writes into its own folder, so a run never overwrites the previous
# set — comparing two takes (or two window sizes) is just an `ls`.
RUN=""
RUN_SET=0
# The four sizes App Store Connect accepts for a Mac screenshot. 2880x1800 is
# the largest, and is what a 1440x900-point window captures as on a 2x display.
APPSTORE_SIZES=(1280x800 1440x900 2560x1600 2880x1800)
APPSTORE_SIZE="2880x1800"
DO_APPSTORE=1
# Fills the canvas behind the shot: the rounded corners the window capture
# leaves transparent, and the sliver of letterboxing a display that isn't
# exactly 16:10 produces. Black is the app's own canvas colour, so it hides.
BG="000000"
MUSIC="next"
PLAYLIST=""

usage() {
    cat <<'EOF'
Usage: scripts/take-screenshots.sh [options]

  --out DIR            Output directory (default: web/src/assets/screenshots)
  --run NAME           Folder for this run's images, created under --out
                       (default: a UTC timestamp, e.g. 20260729-174312Z).
                       Pass an empty string to write bare names into --out
                       itself, which is what the website's assets are.
  --size WxH           Windowed size in points (default: the largest 16:10 box
                       that fits this display, capped at 1440x900)
  --configuration NAME Debug | Direct | Release (default: Debug)
  --app PATH           Use an existing .app instead of building
  --no-build           Skip xcodebuild, use the last build of --configuration
  --source KIND        demo | systemAudio | inputDevice | audioFile
                       (default: systemAudio)
  --settle SECONDS     Wait after launch before capturing (default: 8)
  --only ID[,ID...]    Only these visualizer ids (default: all registered)
  --mode window|region Window capture keeps the rounded corners; region captures
                       the raw screen rect (default: window)
  --1x                 Downsample the raw output to the logical point size
                       (the app-store/ copies are unaffected)
  --appstore-size WxH  App Store canvas size: 1280x800 | 1440x900 | 2560x1600 |
                       2880x1800 (default: 2880x1800)
  --no-appstore        Skip the app-store/ copies entirely
  --bg RRGGBB          Canvas colour behind the shot (default: 000000)
  --music MODE         next | play | off (default: next)
                       next  advance Music one track per visualizer
                       play  start Music once, same track throughout
                       off   don't touch Music; assume something is playing
  --playlist NAME      Start from this Music playlist instead of resuming
  -h, --help           Show this message

Files are named <visualizer>-<windowed|fullscreen>.png inside the run folder,
with App Store-conformed copies of each under app-store/ and a manifest.txt
recording the sizes and the track in every shot.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --out) OUT_DIR="$2"; shift 2 ;;
        --run) RUN="$2"; RUN_SET=1; shift 2 ;;
        --size) SIZE="$2"; shift 2 ;;
        --configuration) CONFIGURATION="$2"; shift 2 ;;
        --app) APP="$2"; DO_BUILD=0; shift 2 ;;
        --no-build) DO_BUILD=0; shift ;;
        --source) SOURCE_KIND="$2"; shift 2 ;;
        --settle) SETTLE="$2"; shift 2 ;;
        --only) IFS=, read -r -a ONLY <<< "$2"; shift 2 ;;
        --mode) MODE="$2"; shift 2 ;;
        --1x) ONE_X=1; shift ;;
        --appstore-size) APPSTORE_SIZE="$2"; shift 2 ;;
        --no-appstore) DO_APPSTORE=0; shift ;;
        --bg) BG="$2"; shift 2 ;;
        --music) MUSIC="$2"; shift 2 ;;
        --playlist) PLAYLIST="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

case "$MUSIC" in
    next|play|off) ;;
    *) echo "invalid --music '$MUSIC' (expected next, play or off)" >&2; exit 2 ;;
esac
if [[ -n "$PLAYLIST" && "$MUSIC" == "off" ]]; then
    echo "--playlist '$PLAYLIST' cannot be honoured with --music off" >&2
    exit 2
fi

if [[ ! "$BG" =~ ^#?[0-9A-Fa-f]{6}$ ]]; then
    echo "invalid --bg '$BG' (expected six hex digits, e.g. 000000)" >&2
    exit 2
fi

# UTC to the second: sortable, and a full run takes far longer than a second,
# so it can't collide with itself.
[[ $RUN_SET -eq 1 ]] || RUN="$(date -u +%Y%m%d-%H%M%SZ)"
# A run name becomes a path component, so keep it to characters that survive
# both the filesystem and an Astro import.
if [[ -n "$RUN" && ! "$RUN" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "invalid --run '$RUN' (letters, digits, dot, underscore, hyphen)" >&2
    exit 2
fi

if [[ $DO_APPSTORE -eq 1 ]]; then
    if [[ " ${APPSTORE_SIZES[*]} " != *" $APPSTORE_SIZE "* ]]; then
        echo "invalid --appstore-size '$APPSTORE_SIZE'" >&2
        echo "App Store Connect accepts only: ${APPSTORE_SIZES[*]}" >&2
        exit 2
    fi
    APPSTORE_W="${APPSTORE_SIZE%%x*}"
    APPSTORE_H="${APPSTORE_SIZE##*x}"
fi

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
warn() { printf '    \033[33mwarning:\033[0m %s\n' "$*" >&2; }

# ------------------------------------------------------------------ music.app

# Runs each argument as one line of a `tell application "Music"` block. Errors
# come back on stdout (osascript writes them to stderr) with a non-zero status,
# so a caller can report the real message.
#
# Note every script below compares against `player state` rather than coercing
# it — `player state as text` is not reliable across constants (CLAUDE.md), and
# from the shell a thrown script is indistinguishable from "nothing playing".
music_tell() {
    local script=(-e 'tell application "Music"') line
    for line in "$@"; do script+=(-e "$line"); done
    script+=(-e 'end tell')
    osascript "${script[@]}" 2>&1
}

music_running() {
    [[ "$(osascript -e 'application "Music" is running' 2>/dev/null || true)" == "true" ]]
}

# "Title — Artist", or empty when nothing is playing or Music refused to answer.
now_playing() {
    local out
    if out="$(music_tell \
        'if player state is not playing then return ""' \
        'return (name of current track) & " — " & (artist of current track)')"; then
        printf '%s' "$out"
    fi
}

MUSIC_STARTED=0

# Puts a *different* song behind each visualizer. Never fatal: a screenshot run
# is still useful with a stale badge, and the fixable case (no Automation
# permission) is caught in the preflight instead.
cue_track() {
    [[ "$MUSIC" == "off" ]] && return 0
    local out escaped
    if [[ $MUSIC_STARTED -eq 0 ]]; then
        MUSIC_STARTED=1
        if [[ -n "$PLAYLIST" ]]; then
            escaped="${PLAYLIST//\\/\\\\}"
            escaped="${escaped//\"/\\\"}"
            out="$(music_tell "play playlist \"$escaped\"")" \
                || { warn "Music could not play playlist '$PLAYLIST' — $out"; return 0; }
        else
            out="$(music_tell 'if player state is not playing then play')" \
                || { warn "Music could not start playback — $out"; return 0; }
        fi
    elif [[ "$MUSIC" == "next" ]]; then
        # `next track` throws when the player is stopped, so start it first and
        # only advance once something is actually playing.
        out="$(music_tell \
            'if player state is not playing then play' \
            'if player state is playing then next track')" \
            || { warn "Music could not advance to the next track — $out"; return 0; }
    fi
    # Long enough for Music to swap the track and post the playerInfo
    # notification that fills the badge.
    sleep 1.5
}

# ------------------------------------------------------------- visualizers

# Resolved before the preflight, so a mistyped --only fails without having asked
# for a permission or launched Music first.
#
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

if [[ "$MUSIC" == "off" ]]; then
    info "Music: not used (--music off)"
else
    if ! music_running; then
        info "Music is not running — launching it in the background"
        open -ga Music || { echo "could not launch Music (pass --music off)" >&2; exit 1; }
        for _ in $(seq 1 40); do music_running && break; sleep 0.25; done
        music_running || { echo "Music did not start (pass --music off)" >&2; exit 1; }
    fi
    # Capture first, then match against the variable: piping into `grep -q`
    # would SIGPIPE osascript and, under `pipefail`, turn a match into a failed
    # pipeline (CLAUDE.md).
    PROBE="$(music_tell 'player state is playing' || true)"
    if grep -q -- '-1743' <<<"$PROBE"; then
        cat >&2 <<EOF
Music refused the Apple Event (-1743), so the track can't be changed between
shots.

  Open System Settings › Privacy & Security › Automation, find the app you are
  running this from — Terminal, iTerm, or your editor — and enable Music under
  it. Then run this script again, or pass --music off to leave Music alone.
EOF
        exit 1
    fi
    info "Music: ok"
fi

# ------------------------------------------------------------------- inputs

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

MOUSE_HOME="$("$SHOTKIT" mouse-get)"
read -r _ _ DISPLAY_W DISPLAY_H < <("$SHOTKIT" display)

# The window has to be 16:10 for the App Store copy to be a straight flatten
# rather than a letterbox, so the size is built out of 16:10 units rather than
# rounded per axis: the largest that clears the menu bar, capped at 1440x900 pt
# (2880x1800 px at 2x, the largest size Apple accepts).
if [[ -z "$SIZE" ]]; then
    UNIT=$(( (DISPLAY_W - 40) / 16 ))
    (( (DISPLAY_H - 76) / 10 < UNIT )) && UNIT=$(( (DISPLAY_H - 76) / 10 ))
    (( UNIT > 90 )) && UNIT=90
    (( UNIT > 0 )) || { echo "display ${DISPLAY_W}x${DISPLAY_H} is too small to size a window in" >&2; exit 1; }
    SIZE="$(( UNIT * 16 ))x$(( UNIT * 10 ))"
fi

WIDTH="${SIZE%%x*}"
HEIGHT="${SIZE##*x}"
if [[ ! "$WIDTH" =~ ^[0-9]+$ || ! "$HEIGHT" =~ ^[0-9]+$ ]]; then
    echo "invalid --size '$SIZE' (expected WxH, e.g. 1440x900)" >&2
    exit 2
fi
if [[ $DO_APPSTORE -eq 1 ]] && (( WIDTH * 10 != HEIGHT * 16 )); then
    warn "--size $SIZE is not 16:10, so the app-store/ windowed shots will be letterboxed"
fi

RUN_DIR="$OUT_DIR${RUN:+/$RUN}"
APPSTORE_DIR="$RUN_DIR/app-store"
mkdir -p "$RUN_DIR"
[[ $DO_APPSTORE -eq 1 ]] && mkdir -p "$APPSTORE_DIR"

step "Capturing ${#VISUALIZERS[@]} visualizer(s)"
info "app:       $APP"
info "source:    $SOURCE_KIND"
info "out:       $RUN_DIR"
info "window:    ${WIDTH}x${HEIGHT} pt on a ${DISPLAY_W}x${DISPLAY_H} pt display"
if [[ $DO_APPSTORE -eq 1 ]]; then
    info "app store: ${APPSTORE_W}x${APPSTORE_H} px, fit on #$BG, no alpha"
    # 1 to 10 per localization; 4 visualizers x 2 modes already leaves no room
    # for a fifth, which is worth knowing before the upload rejects the set.
    SHOT_COUNT=$(( ${#VISUALIZERS[@]} * 2 ))
    (( SHOT_COUNT <= 10 )) \
        || warn "$SHOT_COUNT shots, but App Store Connect takes at most 10 — pick a subset with --only"
fi
info "music:     $MUSIC${PLAYLIST:+ (playlist \"$PLAYLIST\")}"

# -------------------------------------------------------------------- driver

TRACK=""
# `<file>|<pixels>|<track>` rows, kept apart so the manifest lists the raw shots
# and their App Store copies as two blocks rather than interleaved.
MANIFEST=()
MANIFEST_STORE=()

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
        -playerControlEnabled YES \
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

pixel_size() {
    sips -g pixelWidth -g pixelHeight "$1" \
        | awk '/pixelWidth/{w=$2} /pixelHeight/{h=$2} END{print w, h}'
}

# Redraws a raw capture as an App Store-ready PNG: exactly the target size, no
# alpha channel, nothing cropped.
conform_for_appstore() {
    local raw="$1" name="$2" out="$APPSTORE_DIR/$2" composed alpha note=""
    local source_w source_h drawn_w drawn_h
    read -r source_w source_h <<<"$(pixel_size "$raw")"
    composed="$("$SHOTKIT" compose "$raw" "$out" "$APPSTORE_W" "$APPSTORE_H" fit "$BG")"
    read -r drawn_w drawn_h <<<"$composed"
    # A surviving alpha channel is an App Store Connect rejection, and this is
    # the only place in the pipeline that would notice.
    alpha="$(sips -g hasAlpha "$out" | awk '/hasAlpha/{print $2}')"
    [[ "$alpha" == "no" ]] || { echo "$out still has an alpha channel" >&2; return 1; }
    (( drawn_w < APPSTORE_W || drawn_h < APPSTORE_H )) && note=" — shot is ${drawn_w}x${drawn_h}, letterboxed"
    (( source_w < drawn_w )) && note="$note, upscaled from ${source_w}x${source_h}"
    info "app-store/$name  ${APPSTORE_W}x${APPSTORE_H}$note"
    MANIFEST_STORE+=("app-store/$name|${APPSTORE_W}x${APPSTORE_H}|${TRACK:-unknown}")
}

# capture <pid> <name.png>
capture() {
    local pid="$1" name="$2" out="$RUN_DIR/$2" id x y w h pixels
    read -r id x y w h < <("$SHOTKIT" window "$pid") || true
    [[ -n "${h:-}" ]] || { echo "lost the Synesthia window before capturing $name" >&2; return 1; }
    if [[ "$MODE" == "region" ]]; then
        screencapture -x -R "$x,$y,$w,$h" "$out"
    else
        screencapture -x -o -l "$id" "$out"
    fi
    [[ -s "$out" ]] || { echo "capture produced nothing for $name" >&2; return 1; }
    # Before any downsampling, so the App Store copy is composed from the
    # full-resolution capture.
    [[ $DO_APPSTORE -eq 1 ]] && conform_for_appstore "$out" "$name"
    if [[ $ONE_X -eq 1 ]]; then
        sips --resampleHeightWidth "$h" "$w" "$out" >/dev/null
    fi
    pixels="$(pixel_size "$out" | tr ' ' 'x')"
    info "$name  $pixels"
    MANIFEST+=("$name|$pixels|${TRACK:-unknown}")
}

for visualizer in "${VISUALIZERS[@]}"; do
    step "$visualizer"
    quit_app
    APP_PID="$(launch_app "$visualizer")"
    "$SHOTKIT" activate "$APP_PID"

    # The Accessibility window trails the window-server one by a moment, so wait
    # for it here rather than letting the first query die with a confusing
    # "pid N has no accessible window yet" on an app that is starting normally.
    FULLSCREEN=""
    for _ in $(seq 1 20); do
        FULLSCREEN="$("$SHOTKIT" is-fullscreen "$APP_PID" 2>/dev/null || true)"
        [[ -n "$FULLSCREEN" ]] && break
        sleep 0.25
    done
    # A previous run (or restored state) may have left the window full screen.
    if [[ "$FULLSCREEN" == "1" ]]; then
        "$SHOTKIT" fullscreen "$APP_PID" 0
        sleep 1.5
    fi
    for attempt in $(seq 1 20); do
        "$SHOTKIT" resize "$APP_PID" "$WIDTH" "$HEIGHT" 2>/dev/null && break
        [[ $attempt -lt 20 ]] || { "$SHOTKIT" resize "$APP_PID" "$WIDTH" "$HEIGHT"; }
        sleep 0.25
    done

    # Change the song now that the app is listening, so the badge is filled by
    # the notification rather than by a launch-time poll the store build lacks.
    cue_track
    TRACK="$(now_playing)"
    [[ -n "$TRACK" ]] && info "track:  $TRACK"

    # Long enough for capture to latch onto Music, the analyzer to fill, the
    # visuals to develop, and the artwork poll (which retries) to land.
    sleep "$SETTLE"

    read -r _ wx wy ww wh < <("$SHOTKIT" window "$APP_PID") || true
    [[ -n "${wh:-}" ]] || { echo "lost the Synesthia window" >&2; exit 1; }
    if (( ww != WIDTH || wh != HEIGHT )); then
        warn "window is ${ww}x${wh} pt, not ${WIDTH}x${HEIGHT} — the display may be too small"
    fi
    show_chrome_at "$((wx + ww / 2))" "$((wy + wh / 2))"
    capture "$APP_PID" "$visualizer-windowed.png"

    "$SHOTKIT" activate "$APP_PID"
    "$SHOTKIT" fullscreen "$APP_PID" 1
    sleep 2.5
    show_chrome_at "$((DISPLAY_W / 2))" "$((DISPLAY_H / 2))"
    capture "$APP_PID" "$visualizer-fullscreen.png"

    "$SHOTKIT" fullscreen "$APP_PID" 0
    sleep 1.5
done

quit_app
APP_PID=""

# ------------------------------------------------------------------ manifest

manifest_rows() {
    local row name pixels track
    for row in "$@"; do
        IFS='|' read -r name pixels track <<< "$row"
        printf '%-34s %-12s %s\n' "$name" "$pixels" "$track"
    done
}

# Built up here rather than expanded in the block below, so an empty
# MANIFEST_STORE (--no-appstore) is never expanded under `set -u`.
ROWS=("${MANIFEST[@]}")
[[ ${#MANIFEST_STORE[@]} -gt 0 ]] && ROWS+=("${MANIFEST_STORE[@]}")

{
    printf 'Synesthia screenshots — %s\n\n' "${RUN:-(flat, in the output directory)}"
    printf 'app          %s (%s)\n' "$APP" "$CONFIGURATION"
    printf 'source       %s\n' "$SOURCE_KIND"
    printf 'window       %sx%s pt\n' "$WIDTH" "$HEIGHT"
    if [[ $DO_APPSTORE -eq 1 ]]; then
        printf 'app store    %sx%s px, scaled to fit on #%s, no alpha channel\n' \
            "$APPSTORE_W" "$APPSTORE_H" "$BG"
    fi
    printf '\n%-34s %-12s %s\n' "file" "pixels" "track"
    manifest_rows "${ROWS[@]}"
} > "$RUN_DIR/manifest.txt"

step "Done"
info "$RUN_DIR"
info "${#MANIFEST[@]} screenshot(s), ${#MANIFEST_STORE[@]} App Store copy(ies), manifest.txt beside them"
