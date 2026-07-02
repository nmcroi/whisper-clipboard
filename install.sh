#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

pick_python() {
  if [[ -n "${PYTHON:-}" ]]; then
    printf '%s\n' "$PYTHON"
    return
  fi

  for candidate in python3.12 python3.11 python3.13 python3; do
    if command -v "$candidate" >/dev/null 2>&1; then
      "$candidate" - <<'PY' >/dev/null 2>&1 && {
import sys
raise SystemExit(0 if sys.version_info >= (3, 10) else 1)
PY
        printf '%s\n' "$candidate"
        return
      }
    fi
  done

  printf 'No suitable Python found. Install Python 3.10 or newer.\n' >&2
  exit 1
}

PYTHON_BIN="$(pick_python)"
echo "Using Python: $PYTHON_BIN"

"$PYTHON_BIN" -m venv .venv
source .venv/bin/activate

python -m pip install --upgrade pip setuptools wheel
python -m pip install -e .

echo
echo "Install complete."
echo "Start with: ./start.command"
