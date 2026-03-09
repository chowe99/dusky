#!/usr/bin/env bash
# ==============================================================================
# HYPRLAND SCREENSHOT ARCHITECTURE (SATTY OPTIMIZED)
# Bash 5.3+ | Atomic flock IPC | Daemon Capability Polling
# ==============================================================================

set -euo pipefail

readonly SCRIPT_NAME="${0##*/}"
readonly PREFIX="screenshot"

readonly BASE_PICS=$(xdg-user-dir PICTURES 2>/dev/null || echo "$HOME/Pictures")
readonly SAVE_DIR="${BASE_PICS}/Screenshots"

MODE="region"
declare -i COPY_CLIP=1
declare -i NOTIFY=1
declare -i ANNOTATE=0
declare -i HAS_ACTION_SUPPORT=0
SELECTION=""
TEMP_FILE=""
SATTY_TOOL=""

# --- 1. ARGUMENT PARSING ---
while (($# > 0)); do
    case "$1" in
        -f|--fullscreen)   MODE="fullscreen"; shift ;;
        -r|--region)       MODE="region"; shift ;;
        -w|--window)       MODE="window"; shift ;;
        -a|--annotate)     ANNOTATE=1; shift ;;
        -t|--tool)         SATTY_TOOL="$2"; ANNOTATE=1; shift 2 ;; # Auto-enables annotation
        --no-copy)         COPY_CLIP=0; shift ;;
        --no-notify)       NOTIFY=0; shift ;;
        -h|--help)
            cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS]
  -f, --fullscreen   Capture the entire screen
  -r, --region       Draw a rectangle to capture
  -w, --window       Select a specific window
  -a, --annotate     Open Satty immediately after capturing
  -t, --tool <tool>  Open Satty with specific tool (arrow, blur, text, etc.)
  --no-copy          Do not copy to the clipboard
  --no-notify        Disable desktop notifications
EOF
            exit 0 ;;
        *) echo "Fatal: Unknown option: $1" >&2; exit 1 ;;
    esac
done

# --- 2. ENVIRONMENT & CAPABILITY POLLING ---
mkdir -p "$SAVE_DIR"

declare -a REQ_CMDS=("grim" "flock")
(( COPY_CLIP )) && REQ_CMDS+=("wl-copy")
(( NOTIFY ))    && REQ_CMDS+=("notify-send")

[[ "$MODE" == "region" ]] && REQ_CMDS+=("slurp")
[[ "$MODE" == "window" ]] && REQ_CMDS+=("slurp" "hyprctl" "jq")
(( ANNOTATE )) && REQ_CMDS+=("satty")

for cmd in "${REQ_CMDS[@]}"; do
    command -v "$cmd" >/dev/null || { echo "Fatal: Missing dependency '$cmd'" >&2; exit 1; }
done

if (( NOTIFY )) && ! (( ANNOTATE )) && command -v satty >/dev/null; then
    while IFS= read -r capability; do
        if [[ "$capability" == "actions" ]]; then
            HAS_ACTION_SUPPORT=1
            break
        fi
    done < <(notify-send --capabilities 2>/dev/null || true)
fi

cleanup() {
    [[ -n "${TEMP_FILE:-}" && -f "$TEMP_FILE" ]] && rm -f "$TEMP_FILE"
}
trap cleanup EXIT

# --- 3. SELECTION LOGIC ---
case "$MODE" in
    region)
        set +e
        SELECTION=$(slurp)
        STATUS=$?
        set -e
        [[ $STATUS -eq 1 ]] && exit 0 
        [[ $STATUS -ne 0 ]] && { echo "Fatal: Slurp failed." >&2; exit 1; }
        [[ -z "$SELECTION" ]] && exit 0
        ;;
    window)
        WINDOW_DATA=$(hyprctl -j clients | jq -r '
            .[] | select(.mapped and (.hidden | not) and .size[0] > 0 and .size[1] > 0)
            | "\(.at[0]),\(.at[1]) \(.size[0])x\(.size[1])"
        ') || { echo "Fatal: Failed to query Hyprland socket." >&2; exit 1; }

        [[ -z "$WINDOW_DATA" ]] && exit 0 

        set +e
        SELECTION=$(slurp -r <<< "$WINDOW_DATA")
        STATUS=$?
        set -e
        [[ $STATUS -eq 1 ]] && exit 0 
        [[ $STATUS -ne 0 ]] && { echo "Fatal: Slurp failed." >&2; exit 1; }
        [[ -z "$SELECTION" ]] && exit 0
        ;;
esac

# --- 4. CAPTURE ---
TEMP_FILE=$(mktemp --tmpdir="$SAVE_DIR" ".${PREFIX}.XXXXXX.png")

if [[ "$MODE" == "fullscreen" ]]; then
    grim "$TEMP_FILE" || { echo "Fatal: Grim capture failed." >&2; exit 1; }
else
    grim -g "$SELECTION" "$TEMP_FILE" || { echo "Fatal: Grim capture failed." >&2; exit 1; }
fi

# --- 5. ATOMIC FLOCK IPC & PUBLISHING ---
readonly LOCK_FILE="${SAVE_DIR}/.${PREFIX}.lock"
exec {lock_fd}>"$LOCK_FILE"
flock -x "$lock_fd"

shopt -s nullglob extglob
MAX_NUM=0
for file in "${SAVE_DIR}/${PREFIX}"-*.png; do
    basename="${file##*/}"
    num_text=${basename#"${PREFIX}-"}
    num_text=${num_text%.png}
    
    if [[ "$num_text" == +([0-9]) ]]; then
        num=$((10#$num_text))
        ((num > MAX_NUM)) && MAX_NUM=$num
    fi
done
shopt -u nullglob extglob

NEXT_NUM=$((MAX_NUM + 1))
FILE_PATH="${SAVE_DIR}/${PREFIX}-${NEXT_NUM}.png"

if PUBLISH_ERR=$(mv -T --no-copy --update=none-fail -- "$TEMP_FILE" "$FILE_PATH" 2>&1); then
    TEMP_FILE="" 
else
    echo "Fatal: ${PUBLISH_ERR:-Publish failed.}" >&2
    exit 1
fi

flock -u "$lock_fd"
exec {lock_fd}>&-

# --- 6. ANNOTATION HANDLER ---
# We build the satty command dynamically to include tools and suppress double-notifications
run_satty() {
    local -a satty_args=("--filename" "$FILE_PATH" "--output-filename" "$FILE_PATH" "--early-exit" "--disable-notifications")
    [[ -n "$SATTY_TOOL" ]] && satty_args+=("--initial-tool" "$SATTY_TOOL")
    
    if ! satty "${satty_args[@]}"; then
        echo "Warning: Satty exited with an error. Original image retained." >&2
        return 1
    fi
    return 0
}

# --- 7. DISPATCH & NOTIFICATIONS ---
if (( ANNOTATE )); then
    run_satty || true
fi

if (( COPY_CLIP )); then
    wl-copy --type image/png < "$FILE_PATH" || echo "Warning: Clipboard copy failed." >&2
fi

if (( NOTIFY )); then
    if (( ANNOTATE )) || ! (( HAS_ACTION_SUPPORT )); then
        notify-send -a "$SCRIPT_NAME" -i "$FILE_PATH" "Screenshot Captured" "Saved as ${PREFIX}-${NEXT_NUM}.png" || true
    else
        (
            ACTION=$(notify-send -a "$SCRIPT_NAME" -i "$FILE_PATH" -t 8000 --action="edit=Annotate" "Screenshot Captured" "Saved as ${PREFIX}-${NEXT_NUM}.png" 2>/dev/null || true)
            
            if [[ "$ACTION" == "edit" ]]; then
                if run_satty; then
                    (( COPY_CLIP )) && wl-copy --type image/png < "$FILE_PATH" || true
                else
                    notify-send -a "$SCRIPT_NAME" -i "$FILE_PATH" -u critical "Annotation Failed" "Satty encountered an error." || true
                fi
            fi
        ) >/dev/null 2>&1 & disown
    fi
fi
