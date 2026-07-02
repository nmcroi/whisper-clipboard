#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

if [[ ! -d .venv ]]; then
  ./install.sh
fi

source .venv/bin/activate
exec whisper-clipboard
