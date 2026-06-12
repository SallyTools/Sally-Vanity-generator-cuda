#!/usr/bin/env bash
# Sally-Vanity-generator-cuda — Linux/macOS installer wrapper.
set -e
cd "$(dirname "$0")"
PY=python3; command -v python3 >/dev/null || PY=python
exec "$PY" install.py "$@"
