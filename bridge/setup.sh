#!/usr/bin/env bash
# Installs libfreenect and builds the depth reader. Safe to re-run.
set -euo pipefail

cd "$(dirname "$0")/.."

info() { printf '\033[36m%s\033[0m\n' "$*"; }
fail() { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

case "$(uname -s)" in
  Darwin)
    command -v brew >/dev/null || fail "homebrew is required: https://brew.sh"
    if ! brew list libfreenect >/dev/null 2>&1; then
      info "installing libfreenect..."
      brew install libfreenect
    fi
    PREFIX="$(brew --prefix)"
    ;;
  Linux)
    if ! ldconfig -p | grep -q libfreenect; then
      info "installing libfreenect..."
      sudo apt-get update && sudo apt-get install -y libfreenect-dev build-essential
    fi
    PREFIX="/usr"
    ;;
  *)
    fail "unsupported platform: $(uname -s)"
    ;;
esac

[ -f "$PREFIX/include/libfreenect/libfreenect.h" ] || fail "libfreenect headers not found under $PREFIX"

info "building bridge/depth..."
cc bridge/depth.c -o bridge/depth -I"$PREFIX/include" -L"$PREFIX/lib" -lfreenect -lusb-1.0 -O2 -Wall

info "done. plug in the kinect (it needs its 12V adapter), then pick 'kinect' as the source."
