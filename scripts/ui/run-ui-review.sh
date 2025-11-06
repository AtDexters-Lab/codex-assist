#!/usr/bin/env bash
set -euo pipefail

SCRIPT_SOURCE="${BASH_SOURCE[0]}"
while [[ -h "$SCRIPT_SOURCE" ]]; do
  SCRIPT_DIR="$(cd -P "$(dirname "$SCRIPT_SOURCE")" && pwd)"
  LINK_TARGET="$(readlink "$SCRIPT_SOURCE")"
  if [[ "$LINK_TARGET" != /* ]]; then
    SCRIPT_SOURCE="$SCRIPT_DIR/$LINK_TARGET"
  else
    SCRIPT_SOURCE="$LINK_TARGET"
  fi
done
SCRIPT_DIR="$(cd -P "$(dirname "$SCRIPT_SOURCE")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INVOCATION_PWD="$(pwd)"

PROMPT_FILE_DEFAULT="$REPO_ROOT/docs/prompts/ui_reviewer_prompt.md"
PROMPT_DIR="$REPO_ROOT/docs/prompts"
MODEL_DEFAULT="gpt-5"

usage() {
  cat <<'USAGE'
Usage: scripts/ui/run-ui-review.sh <image_path|screenshots_dir> [...] [--model <model>] [--prompt <file|->] [--output <file>]

Run a Codex-powered UI review over provided screenshots.

Options:
  --model <model>   Model to use (default: gpt-5)
  --prompt <file>   Override the system prompt file; use "-" to read from stdin (default: docs/prompts/ui_reviewer_prompt.md)
  --prompt-name <n> Select a prompt in docs/prompts by name (see --list-prompts)
  --list-prompts    Print available prompt names and exit
  --context <file>  Append additional Markdown context (repeatable; appended in order)
  --output <file>   Write only the model's final response to the given file
  -h, --help        Show this help and exit

Notes:
  - Positional arguments can be image files or directories containing images.
  - All *.png, *.jpg, *.jpeg, and *.webp files are attached via --image.
  - No JSON schema validation is performed; the model follows the system prompt guidance directly.
USAGE
}

declare -a TARGET_PATHS=()
MODEL="$MODEL_DEFAULT"
PROMPT_FILE="$PROMPT_FILE_DEFAULT"
PROMPT_NAME=""
OUTPUT_FILE=""
declare -a CONTEXT_FILES=()
LIST_PROMPTS="false"

list_prompts() {
  if [[ ! -d "$PROMPT_DIR" ]]; then
    echo "No prompt directory found at $PROMPT_DIR" >&2
    return 1
  fi
  local found=0
  while IFS= read -r -d '' file; do
    if [[ $found -eq 0 ]]; then
      echo "Available prompts:"
    fi
    found=1
    base="$(basename "$file")"
    name="${base%.md}"
    name="${name%_prompt}"
    printf '  - %s (%s)\n' "$name" "$base"
  done < <(find "$PROMPT_DIR" -maxdepth 1 -type f -name '*.md' -print0)
  if [[ $found -eq 0 ]]; then
    echo "No prompt files found under $PROMPT_DIR" >&2
    return 1
  fi
  return 0
}

resolve_prompt_by_name() {
  local name="$1"
  for candidate in "$PROMPT_DIR/$name" "$PROMPT_DIR/$name.md" "$PROMPT_DIR/${name}_prompt.md"; do
    if [[ -f "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --model)
      if [[ $# -lt 2 ]]; then
        echo "Error: --model requires an argument." >&2
        exit 2
      fi
      MODEL="$2"
      shift 2
      ;;
    --prompt)
      if [[ $# -lt 2 ]]; then
        echo "Error: --prompt requires a file argument." >&2
        exit 2
      fi
      PROMPT_FILE="$2"
      PROMPT_NAME=""
      shift 2
      ;;
    --prompt-name)
      if [[ $# -lt 2 ]]; then
        echo "Error: --prompt-name requires an argument." >&2
        exit 2
      fi
      PROMPT_NAME="$2"
      shift 2
      ;;
    --list-prompts)
      LIST_PROMPTS="true"
      shift
      ;;
    --context)
      if [[ $# -lt 2 ]]; then
        echo "Error: --context requires a file path argument." >&2
        exit 2
      fi
      CONTEXT_FILES+=("$2")
      shift 2
      ;;
    --output)
      if [[ $# -lt 2 ]]; then
        echo "Error: --output requires a file argument." >&2
        exit 2
      fi
      OUTPUT_FILE="$2"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage
      exit 2
      ;;
    *)
      TARGET_PATHS+=("$1")
      shift
      ;;
  esac
done

if [[ $# -gt 0 ]]; then
  TARGET_PATHS+=("$@")
fi

if [[ "$LIST_PROMPTS" == "true" ]]; then
  list_prompts || exit 1
  exit 0
fi

if [[ ${#TARGET_PATHS[@]} -eq 0 ]]; then
  echo "Error: provide at least one image file or directory." >&2
  usage
  exit 1
fi

if ! command -v codex >/dev/null 2>&1; then
  echo "Error: 'codex' CLI not found in PATH." >&2
  exit 127
fi

if [[ -n "$PROMPT_NAME" ]]; then
  resolved_prompt="$(resolve_prompt_by_name "$PROMPT_NAME")" || {
    echo "Error: prompt named '$PROMPT_NAME' not found under $PROMPT_DIR." >&2
    echo "Use --list-prompts to see available options." >&2
    exit 1
  }
  PROMPT_FILE="$resolved_prompt"
fi

if [[ ${#CONTEXT_FILES[@]} -gt 0 ]]; then
  for ctx in "${CONTEXT_FILES[@]}"; do
    if [[ -z "$ctx" ]]; then
      echo "Error: --context requires a file path." >&2
      exit 2
    fi
    if [[ ! -f "$ctx" ]]; then
      echo "Error: context file not found: $ctx" >&2
      exit 1
    fi
  done
fi

declare -a IMAGE_PATHS=()
declare -a IMAGE_LABELS=()
declare -a IMAGE_DIRS=()
declare -a SEEN_IMAGES=()

shopt -s nocasematch
image_ext_regex='.+\.(png|jpg|jpeg|webp)$'

image_already_seen() {
  local needle="$1"
  local existing
  for existing in "${SEEN_IMAGES[@]}"; do
    if [[ "$existing" == "$needle" ]]; then
      return 0
    fi
  done
  return 1
}

collect_image() {
  local img_path="$1"
  local label="$2"

  if [[ -z "$img_path" ]]; then
    return
  fi
  if [[ ! -f "$img_path" ]]; then
    echo "Error: image file not found: $img_path" >&2
    exit 1
  fi
  if [[ ! "$img_path" =~ $image_ext_regex ]]; then
    echo "Skipping non-image file: $img_path" >&2
    return
  fi
  local abs_path
  abs_path="$(cd "$(dirname "$img_path")" && pwd)/$(basename "$img_path")"
  if [[ ! -r "$abs_path" ]]; then
    echo "Error: unable to read image file: $abs_path" >&2
    exit 1
  fi
  if image_already_seen "$abs_path"; then
    return
  fi
  SEEN_IMAGES+=("$abs_path")
  IMAGE_PATHS+=("$abs_path")
  IMAGE_LABELS+=("$label")
  IMAGE_DIRS+=("$(dirname "$abs_path")")
}

for target in "${TARGET_PATHS[@]}"; do
  if [[ -z "$target" ]]; then
    continue
  fi
  if [[ ! -e "$target" ]]; then
    echo "Error: path not found: $target" >&2
    exit 1
  fi

  if [[ -d "$target" ]]; then
    abs_dir="$(cd "$target" && pwd)"
    while IFS= read -r -d '' img; do
      rel_path="${img#$abs_dir/}"
      if [[ "$rel_path" == "$img" ]]; then
        rel_path="$(basename "$img")"
      fi
      collect_image "$img" "$rel_path"
    done < <(find "$abs_dir" -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.webp' \) -print0)
  else
    abs_file="$(cd "$(dirname "$target")" && pwd)/$(basename "$target")"
    collect_image "$abs_file" "$(basename "$abs_file")"
  fi
done

if [[ ${#IMAGE_PATHS[@]} -eq 0 ]]; then
  echo "Error: no image files (*.png, *.jpg, *.jpeg, *.webp) found in provided paths." >&2
  exit 1
fi

WORKDIR="$INVOCATION_PWD"
if [[ ${#IMAGE_DIRS[@]} -gt 0 ]]; then
  candidate_dir="${IMAGE_DIRS[0]}"
  same_dir="true"
  for dir in "${IMAGE_DIRS[@]}"; do
    if [[ "$dir" != "$candidate_dir" ]]; then
      same_dir="false"
      break
    fi
  done
  if [[ "$same_dir" == "true" ]]; then
    WORKDIR="$candidate_dir"
  fi
fi

if [[ "$PROMPT_FILE" != "-" ]]; then
  if [[ ! -f "$PROMPT_FILE" ]]; then
    echo "Error: prompt file not found: $PROMPT_FILE" >&2
    exit 1
  fi
  PROMPT_TEXT="$(cat "$PROMPT_FILE")"
else
  if [[ -t 0 ]]; then
    echo "Error: --prompt - specified but no stdin data provided." >&2
    exit 1
  fi
  PROMPT_TEXT="$(cat)"
fi
shopt -u nocasematch

PROMPT_BODY="$PROMPT_TEXT"

if [[ ${#CONTEXT_FILES[@]} -gt 0 ]]; then
  PROMPT_BODY+=$'\n\nADDITIONAL CONTEXT'
  for ctx in "${CONTEXT_FILES[@]}"; do
    ctx_path="$(cd "$(dirname "$ctx")" && pwd)/$(basename "$ctx")"
    ctx_name="$(basename "$ctx_path")"
    ctx_content="$(cat "$ctx_path")"
    PROMPT_BODY+=$'\n\n### '"$ctx_name"$'\n\n'"$ctx_content"
  done
fi

ATTACHMENT_LIST=""
for idx in "${!IMAGE_PATHS[@]}"; do
  label="${IMAGE_LABELS[$idx]}"
  abs_path="${IMAGE_PATHS[$idx]}"
  rel_display="$label"
  if [[ "$abs_path" == "$WORKDIR"/* ]]; then
    rel_candidate="${abs_path#"$WORKDIR"/}"
    if [[ -n "$rel_candidate" ]]; then
      rel_display="$rel_candidate"
    fi
  elif [[ "$abs_path" == "$INVOCATION_PWD"/* ]]; then
    rel_candidate="${abs_path#"$INVOCATION_PWD"/}"
    if [[ -n "$rel_candidate" ]]; then
      rel_display="$rel_candidate"
    fi
  elif [[ "$abs_path" == "$REPO_ROOT"/* ]]; then
    rel_candidate="${abs_path#"$REPO_ROOT"/}"
    if [[ -n "$rel_candidate" ]]; then
      rel_display="$rel_candidate"
    fi
  fi
  if [[ "$rel_display" != "$label" ]]; then
    ATTACHMENT_LIST+=" - $label (relative: $rel_display)"$'\n'
  else
    ATTACHMENT_LIST+=" - $label"$'\n'
  fi
done

read -r -d '' CONTEXT_TEXT <<EOF || true
The following ${#IMAGE_PATHS[@]} screenshot(s) are already attached to this review session. Reference each image using the label shown below.

$ATTACHMENT_LIST
Reference files using the labels above.
EOF

FINAL_PROMPT="$PROMPT_BODY

$CONTEXT_TEXT"

OUTPUT_ARGS=()
if [[ -n "$OUTPUT_FILE" ]]; then
  mkdir -p "$(dirname "$OUTPUT_FILE")"
  OUTPUT_ARGS=("--output-last-message" "$OUTPUT_FILE")
fi

if [[ "$WORKDIR" != "$INVOCATION_PWD" ]]; then
  echo "UI review working directory set to: $WORKDIR" >&2
fi

IMAGE_ARGS=()
for img_path in "${IMAGE_PATHS[@]}"; do
  IMAGE_ARGS+=("--image" "$img_path")
done

set -x
codex exec \
  --model "$MODEL" \
  --skip-git-repo-check \
  --sandbox read-only \
  --cd "$WORKDIR" \
  "${IMAGE_ARGS[@]}" \
  "${OUTPUT_ARGS[@]}" \
  -- - <<PROMPT_EOF
$FINAL_PROMPT
PROMPT_EOF
set +x

if [[ -n "$OUTPUT_FILE" ]]; then
  echo "UI review saved to: $OUTPUT_FILE" >&2
fi
