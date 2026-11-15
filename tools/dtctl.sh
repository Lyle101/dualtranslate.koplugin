#!/bin/sh
# Headless entry point for the DualTranslate MCP tools (design 10.5).
# Every environment variable must be exported: dtctl.lua resolves the
# KOReader root with os.getenv, and the loader needs the same cwd.
set -e
KO_ROOT="${KO_ROOT:-/mnt/us/koreader}"
export KO_ROOT
KO_HOME="${KO_HOME:-$KO_ROOT}"
export KO_HOME
export LD_LIBRARY_PATH="$KO_ROOT/libs:$KO_ROOT/common:${LD_LIBRARY_PATH:-}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"
cd "$KO_ROOT"
exec ./luajit "$PLUGIN_DIR/tools/dtctl.lua" "$@"
