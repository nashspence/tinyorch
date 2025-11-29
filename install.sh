#!/usr/bin/env sh
set -eu

[ "${DEBUG:-}" ] && set -x

# XDG base dirs (with spec defaults)
: "${XDG_CONFIG_HOME:=$HOME/.config}"
: "${XDG_DATA_HOME:=$HOME/.local/share}"
: "${XDG_CACHE_HOME:=$HOME/.cache}"
export XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME

# TinyOrch dirs under XDG
TINYORCH_CONFIG_DIR="$XDG_CONFIG_HOME/tinyorch"
TINYORCH_DATA_DIR="$XDG_DATA_HOME/tinyorch"
TINYORCH_CACHE_DIR="$XDG_CACHE_HOME/tinyorch"

export TINYORCH_CONFIG_DIR TINYORCH_DATA_DIR TINYORCH_CACHE_DIR

mkdir -p "$TINYORCH_CONFIG_DIR" "$TINYORCH_DATA_DIR" "$TINYORCH_CACHE_DIR"

# Runtime tmp: prefer XDG_RUNTIME_DIR, fall back to cache
if [ -n "${XDG_RUNTIME_DIR:-}" ]; then
  TMPDIR="$XDG_RUNTIME_DIR/tinyorch"
else
  TMPDIR="$TINYORCH_CACHE_DIR/tmp"
fi
mkdir -p "$TMPDIR"
export TMPDIR

# Containers config/data (namespaced under tinyorch)
CONTAINERS_CONF_DIR="$TINYORCH_CONFIG_DIR/containers"
STORAGE_CONF="$CONTAINERS_CONF_DIR/storage.conf"
MACHINE_STORAGE="$TINYORCH_DATA_DIR/machine"

mkdir -p "$CONTAINERS_CONF_DIR" "$MACHINE_STORAGE"

if [ ! -f "$STORAGE_CONF" ]; then
  graphroot="$TINYORCH_DATA_DIR/containers/storage"
  mkdir -p "$graphroot"
  cat >"$STORAGE_CONF" <<EOF
[storage]
graphroot = "$graphroot"
EOF
fi

export CONTAINERS_STORAGE_CONF="$STORAGE_CONF"
export CONTAINERS_MACHINE_STORAGE_PATH="$MACHINE_STORAGE"

# pkgx: binary as tool data, store as cache
PKGX_BIN_DIR="$TINYORCH_DATA_DIR/bin"
PKGX="$PKGX_BIN_DIR/pkgx"
: "${PKGX_DIR:=$TINYORCH_CACHE_DIR/pkgx-store}"
export PKGX_DIR

mkdir -p "$PKGX_BIN_DIR"

if [ ! -x "$PKGX" ]; then
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "https://pkgx.sh/$(uname)/$(uname -m)" -o "$PKGX"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$PKGX" "https://pkgx.sh/$(uname)/$(uname -m)"
  else
    printf 'need curl or wget to install pkgx\n' >&2
    exit 1
  fi
  chmod +x "$PKGX"
fi

"$PKGX" install podman.io docker python.org >/dev/null 2>&1 || true
eval "$("$PKGX" +podman.io +docker +python.org)"

# Virtualenv lives in data dir
VENV_DIR="${TINYORCH_VENV_DIR:-$TINYORCH_DATA_DIR/venv}"
export TINYORCH_VENV="$VENV_DIR"

if [ ! -x "$VENV_DIR/bin/python" ]; then
  mkdir -p "$(dirname "$VENV_DIR")"
  "$PKGX" python -m venv "$VENV_DIR"
fi

PY="$VENV_DIR/bin/python"
export TINYORCH_PYTHON="$PY"

# pip cache under tinyorch cache dir
: "${PIP_CACHE_DIR:=$TINYORCH_CACHE_DIR/pip}"
mkdir -p "$PIP_CACHE_DIR"
export PIP_CACHE_DIR

# Install tinyorch: prefer local dir if provided
if [ -n "${TINYORCH_PKG:-}" ]; then
  TINYORCH_SRC="$TINYORCH_PKG"
else
  TINYORCH_SRC="git+https://github.com/nashspence/tinyorch.git"
fi

"$PY" -m pip install --no-cache-dir --upgrade "$TINYORCH_SRC"

PATH="$VENV_DIR/bin:$PATH"
export PATH
