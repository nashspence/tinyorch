#!/usr/bin/env sh
set -eu

[ "${DEBUG:-}" ] && set -x

PKGX="$HOME/.pkgx-local/pkgx"

if ! command -v "$PKGX" >/dev/null 2>&1; then
  mkdir -p "$HOME/.pkgx-local"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL https://pkgx.sh/$(uname)/$(uname -m) -o "$PKGX"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$PKGX" https://pkgx.sh/$(uname)/$(uname -m)
  else
    echo "need curl or wget to install pkgx" >&2
    exit 1
  fi
  chmod +x "$PKGX"
fi

# use pkgx directly, without PATH changes
"$PKGX" install podman.io docker.com python.org >/dev/null 2>&1 || true

podman() { "$PKGX" podman "$@"; }
docker() { "$PKGX" docker "$@"; }
python() { "$PKGX" python "$@"; }

int_or_default() {
  case "$1" in
    ''|*[!0-9]*) printf '%s\n' "$2" ;;
    *)           printf '%s\n' "$1" ;;
  esac
}

podman_cmd() {
  if [ -w /dev/tty ] 2>/dev/null; then
    printf '+ podman %s\n' "$*" >/dev/tty
    podman "$@" >/dev/tty 2>&1
  else
    printf '+ podman %s\n' "$*" >&2
    podman "$@" >&2
  fi
}

read_state_pids() {
  file=$1
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|*[!0-9]*) continue ;;
    esac
    if kill -0 "$line" 2>/dev/null; then
      printf '%s\n' "$line"
    fi
  done <"$file"
}

pw() {
    id=$1
    [ -n "$id" ] || { printf 'usage: pw <id>\n' >&2; return 1; }

    acct=${USER:-$(id -un 2>/dev/null)}
    os=$(uname -s 2>/dev/null || echo unknown)

    # linux/wsl helper
    _pw_ensure_secret_tool() {
        command -v secret-tool >/dev/null 2>&1 && return 0
        if command -v apt-get >/dev/null 2>&1; then
            printf "Installing libsecret-tools (sudo may be required)...\n" >&2
            sudo apt-get update && sudo apt-get install -y libsecret-tools >/dev/null 2>&1 || {
                printf 'Failed to install libsecret-tools; install secret-tool manually.\n' >&2
                return 1
            }
        else
            printf "'secret-tool' not found; install it manually.\n" >&2
            return 1
        fi
    }

    # try to read existing password
    pw=''
    case "$os" in
        Darwin)
            pw=$(security find-generic-password -a "$acct" -s "$id" -w 2>/dev/null)
            backend=mac
            ;;
        Linux)
            # treat WSL as Linux/secret-tool
            if ! _pw_ensure_secret_tool; then return 1; fi
            pw=$(secret-tool lookup service "$id" account "$acct" 2>/dev/null)
            backend=linux
            ;;
        *)
            printf 'Unsupported OS: %s\n' "$os" >&2
            return 1
            ;;
    esac

    # prompt if missing and store
    if [ -z "$pw" ]; then
        printf "Enter password for '%s': " "$id" >&2
        oldstty=$(stty -g 2>/dev/null || echo "")
        stty -echo 2>/dev/null
        IFS= read -r pw
        [ -n "$oldstty" ] && stty "$oldstty" 2>/dev/null
        printf '\n' >&2

        case "$backend" in
            mac)
                security add-generic-password -a "$acct" -s "$id" -w "$pw" -U >/dev/null 2>&1
                ;;
            linux)
                printf '%s' "$pw" | secret-tool store --label="$id" service "$id" account "$acct" >/dev/null 2>&1
                ;;
        esac
    fi

    printf '%s\n' "$pw"
    pw=
    unset pw
}

ensure_docker_host() {
  set -eu

  if [ "$#" -ne 1 ]; then
    echo "usage: ensure_docker_host <parent_pid>" >&2
    exit 2
  fi

  target_pid=$1
  case "$target_pid" in
    ''|*[!0-9]*) echo "invalid parent pid: $target_pid" >&2; exit 2 ;;
  esac

  os_name=$(uname -s 2>/dev/null || printf 'unknown')

  case "$os_name" in
    Darwin)
      machine_name="tinyorch"

      uid=$(id -u)
      base_dir="$HOME/Library/Application Support/tinyorch"
      launch_agents_dir="$HOME/Library/LaunchAgents"
      state_dir="$base_dir/state"
      cleanup_script="$base_dir/cleanup-agent.sh"
      agent_label="tinyorch.cleanup"
      plist_path="$launch_agents_dir/${agent_label}.plist"

      mkdir -p "$base_dir" "$state_dir" "$launch_agents_dir"
      need_reload=0

      tmp_cleanup=$(mktemp "${TMPDIR:-/tmp}/tinyorch-cleanup.XXXXXX")
      cat >"$tmp_cleanup" <<'CLEANUP'
#!/bin/sh
set -eu
command -v podman >/dev/null 2>&1 || exit 0
base_dir="$HOME/Library/Application Support/tinyorch"
state_dir="$base_dir/state"
[ -d "$state_dir" ] || exit 0
for f in "$state_dir"/*; do
  [ -f "$f" ] || continue
  machine=$(basename "$f")
  alive=""
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|*[!0-9]*) continue ;;
    esac
    if kill -0 "$line" 2>/dev/null; then
      alive="${alive}${line}\n"
    fi
  done <"$f"

  if [ -n "$alive" ]; then
    printf '%s' "$alive" | sort -u >"$f"
    continue
  fi

  podman machine ssh "$machine" -- podman system prune -a --volumes --force --filter "until=720h" || true
  podman machine stop "$machine" || true
  rm -f "$f" 2>/dev/null || true
done
exit 0
CLEANUP

      if [ ! -f "$cleanup_script" ] || ! cmp -s "$tmp_cleanup" "$cleanup_script"; then
        mv "$tmp_cleanup" "$cleanup_script"
        chmod 0755 "$cleanup_script"
        need_reload=1
      else
        rm -f "$tmp_cleanup"
      fi

      tmp_plist=$(mktemp "${TMPDIR:-/tmp}/tinyorch-plist.XXXXXX")
      cat >"$tmp_plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${agent_label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${cleanup_script}</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>3600</integer>
  <key>KeepAlive</key><false/>
  <key>ProcessType</key><string>Background</string>
</dict>
</plist>
PLIST

      if [ ! -f "$plist_path" ] || ! cmp -s "$tmp_plist" "$plist_path"; then
        mv "$tmp_plist" "$plist_path"
        chmod 0644 "$plist_path"
        need_reload=1
      else
        rm -f "$tmp_plist"
      fi

      if [ "$need_reload" -eq 1 ]; then
        launchctl bootout "gui/${uid}/${agent_label}" >/dev/null 2>&1 || true
        launchctl bootstrap "gui/${uid}" "$plist_path" >/dev/null 2>&1 || true
      else
        if ! launchctl print "gui/${uid}/${agent_label}" >/dev/null 2>&1; then
          launchctl bootstrap "gui/${uid}" "$plist_path" >/dev/null 2>&1 || true
        fi
      fi

      state_file="$state_dir/$machine_name"

      alive_pids=$(read_state_pids "$state_file" || printf '')
      if [ -z "$alive_pids" ]; then
        rm -f "$state_file" 2>/dev/null || true
      fi

      machine_state=""
      if ! podman machine inspect "$machine_name" >/dev/null 2>&1; then
        cpus_raw=$(sysctl -n hw.ncpu 2>/dev/null || printf '1')
        mem_bytes_raw=$(sysctl -n hw.memsize 2>/dev/null || printf '0')
        disk_total_kb_raw=$(df -k / 2>/dev/null | awk 'NR==2 {print $2}' || printf '0')

        cpus=$(int_or_default "$cpus_raw" 1)
        mem_bytes=$(int_or_default "$mem_bytes_raw" 0)
        disk_total_kb=$(int_or_default "$disk_total_kb_raw" 0)

        memory_mb=$((mem_bytes / 1024 / 1024 * 80 / 100))
        [ "$memory_mb" -lt 512 ] 2>/dev/null && memory_mb=512

        disk_size_gb=$((disk_total_kb * 80 / 100 / 1024 / 1024))
        [ "$disk_size_gb" -lt 10 ] 2>/dev/null && disk_size_gb=10

        podman_cmd machine init "$machine_name" \
          --cpus "$cpus" \
          --memory "$memory_mb" \
          --disk-size "$disk_size_gb" \
          --volume /Users:/Users \
          --volume /Volumes:/Volumes

        machine_state="stopped"
      else
        machine_state=$(podman machine inspect "$machine_name" --format '{{.State}}' 2>/dev/null || printf '')
      fi

      if [ "$machine_state" != "running" ]; then
        podman_cmd machine start "$machine_name"
        machine_state="running"
      fi

      { printf '%s\n' "$target_pid"; [ -n "$alive_pids" ] && printf '%s\n' "$alive_pids"; } \
        | sort -u >"$state_file"

      host_socket=$(podman machine inspect "$machine_name" \
        --format '{{.ConnectionInfo.PodmanSocket.Path}}' 2>/dev/null || printf '')

      if [ -z "$host_socket" ]; then
        echo "failed to determine podman host-side Docker API socket path for '$machine_name'" >&2
        exit 1
      fi

      vm_socket=""

      vm_uri=$(podman machine inspect "$machine_name" \
        --format '{{.ConnectionInfo.PodmanSocket.URI}}' 2>/dev/null || printf '')

      if [ -n "$vm_uri" ]; then
        vm_socket=$(printf '%s\n' "$vm_uri" | sed -E 's#^[^/]*//[^/]+(/.*)#\1#')
      fi

      rootful=$(podman machine inspect "$machine_name" \
        --format '{{.Rootful}}' 2>/dev/null || echo true)
      if [ "$rootful" = "false" ]; then
        vm_socket="/run/user/$(id -u)/podman/podman.sock"
      fi

      if [ -z "$vm_socket" ]; then
        default_uri=$(podman system connection ls \
          --format '{{.Default}} {{.URI}}' 2>/dev/null | awk '$1=="true"{print $2; exit}' || printf '')
        if [ -n "$default_uri" ]; then
          vm_socket=$(printf '%s\n' "$default_uri" | sed -E 's#^[^/]*//[^/]+(/.*)#\1#')
        fi
      fi

      if [ -z "$vm_socket" ]; then
        vm_socket="/run/user/$(id -u)/podman/podman.sock"
      fi

      (
        set -eu
        if [ -w /dev/tty ] 2>/dev/null; then
          exec >>/dev/tty 2>&1
        else
          exec >/dev/null 2>&1
        fi

        while kill -0 "$target_pid" 2>/dev/null; do
          sleep 2
        done

        remaining=$(read_state_pids "$state_file" | grep -v "^${target_pid}$" || true)
        if [ -n "$remaining" ]; then
          printf '%s\n' "$remaining" | sort -u >"$state_file"
          exit 0
        fi

        podman_cmd machine ssh "$machine_name" -- podman system prune -a --volumes --force --filter "until=720h" || true
        podman_cmd machine stop "$machine_name" || true
        rm -f "$state_file" 2>/dev/null || true
      ) &

      printf 'DOCKER_HOST=unix://%s\n' "$host_socket"
      printf 'DOCKER_SOCKET=%s\n' "$vm_socket"
      ;;

    Linux)
      runtime_dir=${XDG_RUNTIME_DIR:-/tmp}
      socket_path="$runtime_dir/podman-docker-${target_pid}.sock"

      rm -f "$socket_path" 2>/dev/null || true

      podman system service --time=0 "unix://$socket_path" >/dev/null 2>&1 &
      service_pid=$!

      i=0
      while [ "$i" -lt 50 ]; do
        [ -S "$socket_path" ] && break
        i=$((i + 1))
        sleep 0.1
      done

      if [ ! -S "$socket_path" ]; then
        echo "failed to start podman system service; socket '$socket_path' not created" >&2
        kill "$service_pid" 2>/dev/null || true
        exit 1
      fi

      (
        set -eu
        if [ -w /dev/tty ] 2>/dev/null; then
          exec >>/dev/tty 2>&1
        else
          exec >/dev/null 2>&1
        fi

        while kill -0 "$target_pid" 2>/dev/null; do
          sleep 2
        done

        kill "$service_pid" 2>/dev/null || true
        j=0
        while [ "$j" -lt 10 ]; do
          if ! kill -0 "$service_pid" 2>/dev/null; then
            break
          fi
          j=$((j + 1))
          sleep 1
        done
        kill -9 "$service_pid" 2>/dev/null || true
        rm -f "$socket_path" 2>/dev/null || true
      ) &

      printf 'DOCKER_HOST=unix://%s\n' "$socket_path"
      printf 'DOCKER_SOCKET=%s\n' "$socket_path"
      ;;

    *)
      echo "ensure_docker_host: unsupported OS '$os_name'" >&2
      exit 1
      ;;
  esac
}
