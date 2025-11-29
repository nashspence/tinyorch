#!/usr/bin/env sh
set -eu

[ "${DEBUG:-}" ] && set -x

: "${TINYORCH_HOME:=$HOME/.tinyorch}"
BASE=$TINYORCH_HOME

mkdir -p "$BASE" "$BASE/tmp"

TMPDIR="$BASE/tmp"
export TMPDIR

: "${XDG_CACHE_HOME:=$BASE/cache}"
: "${XDG_DATA_HOME:=$BASE/data}"
: "${XDG_CONFIG_HOME:=$BASE/config}"
export XDG_CACHE_HOME XDG_DATA_HOME XDG_CONFIG_HOME

CONTAINERS_CONF_DIR="$XDG_CONFIG_HOME/containers"
STORAGE_CONF="$CONTAINERS_CONF_DIR/storage.conf"
MACHINE_STORAGE="$BASE/machine"

mkdir -p "$CONTAINERS_CONF_DIR" "$MACHINE_STORAGE"

if [ ! -f "$STORAGE_CONF" ]; then
  graphroot="$BASE/containers/storage"
  mkdir -p "$graphroot"
  cat >"$STORAGE_CONF" <<EOF
[storage]
graphroot = "$graphroot"
EOF
fi

export CONTAINERS_STORAGE_CONF="$STORAGE_CONF"
export CONTAINERS_MACHINE_STORAGE_PATH="$MACHINE_STORAGE"

PKGX="$BASE/pkgx/pkgx"
: "${PKGX_DIR:=$BASE/pkgx-store}"
export PKGX_DIR

mkdir -p "$(dirname "$PKGX")"

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

"$PKGX" install podman.io docker.com python.org >/dev/null 2>&1 || true
eval "$("$PKGX" +podman.io +docker.com +python.org)"

VENV_DIR="${TINYORCH_VENV_DIR:-$BASE/venv}"
export TINYORCH_VENV="$VENV_DIR"

if [ ! -x "$VENV_DIR/bin/python" ]; then
  mkdir -p "$(dirname "$VENV_DIR")"
  "$PKGX" python -m venv "$VENV_DIR"
fi

PY="$VENV_DIR/bin/python"
export TINYORCH_PYTHON="$PY"

: "${PIP_CACHE_DIR:=$BASE/pip-cache}"
export PIP_CACHE_DIR

"$PY" -m pip install --no-cache-dir --upgrade \
  git+https://github.com/nashspence/tinyorch.git

PATH="$VENV_DIR/bin:$PATH"
export PATH
