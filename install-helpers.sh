#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"
DEFAULT_PREFIX="${HOME}/.local/bin"

PREFIX="$DEFAULT_PREFIX"
FORCE="false"
DRY_RUN="false"

usage() {
  cat <<'USAGE'
Usage: ./install-helpers.sh [--prefix <dir>] [--force] [--dry-run] [-h|--help]

Install Codex helper scripts into your shell environment by creating symlinks.

Options:
  --prefix <dir>   Target directory for symlinks (default: ~/.local/bin)
  --force          Overwrite existing files at the target location
  --dry-run        Print the actions without creating or modifying files
  -h, --help       Show this help and exit

Each helper is exposed as codex-<helper-name>, derived from its path under scripts/.
Ensure <dir> is on your PATH to make the helpers globally available.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)
      PREFIX="${2:-}"
      if [[ -z "$PREFIX" ]]; then
        echo "Error: --prefix requires a directory argument." >&2
        exit 2
      fi
      shift 2
      ;;
    --force)
      FORCE="true"
      shift
      ;;
    --dry-run)
      DRY_RUN="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ ! -d "$REPO_ROOT/scripts" ]]; then
  echo "Error: scripts/ directory not found at repository root ($REPO_ROOT)." >&2
  exit 1
fi

HELPER_FILES=()
while IFS= read -r -d '' helper_path; do
  HELPER_FILES+=("$helper_path")
done < <(find "$REPO_ROOT/scripts" -type f \( -perm -u+x -o -name '*.sh' \) -print0)

if [[ ${#HELPER_FILES[@]} -eq 0 ]]; then
  echo "No helper scripts detected under scripts/." >&2
  exit 0
fi

if [[ "$DRY_RUN" != "true" ]]; then
  mkdir -p "$PREFIX"
fi

installed=()
skipped=()

for helper in "${HELPER_FILES[@]}"; do
  rel="${helper#$REPO_ROOT/scripts/}"
  if [[ "$rel" == "$helper" ]]; then
    rel="$(basename "$helper")"
  fi
  if [[ "$rel" == *.sh ]]; then
    rel="${rel%.sh}"
  fi
  link_name="codex-${rel//\//-}"
  target_path="$PREFIX/$link_name"

  # Ensure source is executable for convenience.
  if [[ ! -x "$helper" && "$DRY_RUN" != "true" ]]; then
    chmod +x "$helper"
  fi

  if [[ -e "$target_path" || -L "$target_path" ]]; then
    if [[ "$FORCE" != "true" ]]; then
      skipped+=("$target_path (exists)")
      echo "Skipping existing: $target_path"
      continue
    fi
    action="Replacing existing link: $target_path"
  else
    action="Installing $target_path"
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[dry-run] $action -> $helper"
    installed+=("$target_path")
    continue
  fi

  ln -sfn "$helper" "$target_path"
  installed+=("$target_path")
  echo "$action"
done

echo
if [[ "$DRY_RUN" == "true" ]]; then
  echo "Dry run complete. No files were created."
else
  echo "Helper installation complete."
fi

if [[ ${#installed[@]} -gt 0 ]]; then
  echo "Linked helpers:"
  for path in "${installed[@]}"; do
    echo "  - $path"
  done
fi

if [[ ${#skipped[@]} -gt 0 ]]; then
  echo "Skipped (already existed):"
  for path in "${skipped[@]}"; do
    echo "  - $path"
  done
fi

if [[ "$DRY_RUN" != "true" ]]; then
  echo
  echo "Ensure '$PREFIX' is on your PATH. Example:"
  echo "  export PATH=\"$PREFIX:\$PATH\""
fi
