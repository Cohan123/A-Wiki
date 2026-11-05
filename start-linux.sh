#!/bin/bash
# Firmen-Wiki fuer Orange Pi PC (Armbian) starten
set -e
ROOT="$(cd "$(dirname "$0")" && pwd)"
PORT="${PORT:-8765}"
BIND="${BIND:-0.0.0.0}"
exec python3 "$ROOT/server/wiki_server.py" --port "$PORT" --bind "$BIND" --root "$ROOT"
