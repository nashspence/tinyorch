#!/usr/bin/env sh

dr() {
    docker run --rm "$@"
}

dc() {
    docker compose "$@"
}

notify() {
    message=${1-}
    title_env=${2-JOB_CONTEXT}
    urls_env=${3-NOTIFY_URLS}
    eval "title=\${${title_env}-job}"
    urls_value=$(printenv "$urls_env")
    [ -n "$urls_value" ] || return 0
    set --
    IFS=','
    for raw_url in $urls_value; do
        url=$(printf '%s' "$raw_url" | sed 's/^ *//;s/ *$//')
        [ -n "$url" ] && set -- "$@" "$url"
    done
    IFS=' \t\n'
    [ $# -gt 0 ] || return 0
    dr caronc/apprise:latest -t "$title" -b "$message" "$@" || true
}

run() {
    stage=$1
    retries=${2-3}
    success_msg=${3-}

    root=${RUN_DIR-.}
    mark="$root/.${stage}.done"

    [ -e "$mark" ] && return 0

    attempt=1
    last_status=0

    while [ "$attempt" -le "$retries" ]; do
        if dc run --rm "$stage"; then
            : >"$mark"
            [ -n "$success_msg" ] && notify "$success_msg"
            return 0
        else
            last_status=$?
            notify "$stage failed ($attempt/$retries): exited with status $last_status"
        fi
        attempt=$((attempt + 1))
    done

    return "$last_status"
}

run_parallel() {
    pids=""

    for cmd in "$@"; do
        [ -n "$cmd" ] || continue
        (
            sh -c "$cmd"
        ) &
        pids="$pids $!"
    done

    for pid in $pids; do
        wait "$pid"
    done
}

ensure_docker_host() {
  (
    set -eu
    [ "${DEBUG:-}" ] && set -x

    # Emit DOCKER_HOST/DOCKER_SOCKET if something already exists.
    try_existing_docker_env() {
      if [ -n "${DOCKER_HOST:-}" ]; then
        host=$DOCKER_HOST
        socket=""
        case "$host" in
          unix://*)
            socket=${host#unix://}
            ;;
        esac
        printf 'DOCKER_HOST=%s\n' "$host"
        [ -n "$socket" ] && printf 'DOCKER_SOCKET=%s\n' "$socket"
        return 0
      fi

      if [ -S /var/run/docker.sock ]; then
        printf 'DOCKER_HOST=unix:///var/run/docker.sock\n'
        printf 'DOCKER_SOCKET=/var/run/docker.sock\n'
        return 0
      fi

      return 1
    }

    if try_existing_docker_env; then
      exit 0
    fi

    if [ "$#" -lt 1 ]; then
      echo "usage: ensure_docker_host pid [podman-machine-init-args...] machine-name" >&2
      exit 2
    fi

    target_pid=$1
    shift || true
    case "$target_pid" in
      ''|*[!0-9]*) echo "invalid pid: $target_pid" >&2; exit 2 ;;
    esac

    os_name=$(uname -s || echo unknown)

    determine_sudo() {
      if [ "$(id -u)" -eq 0 ]; then
        echo ""
      elif command -v sudo >/dev/null 2>&1; then
        echo "sudo"
      else
        echo ""
      fi
    }

    ensure_podman_linux() {
      if command -v podman >/dev/null 2>&1; then
        return 0
      fi

      sudo_cmd=$(determine_sudo)

      if command -v apt-get >/dev/null 2>&1; then
        $sudo_cmd apt-get update
        $sudo_cmd apt-get install -y podman
      elif command -v dnf >/dev/null 2>&1; then
        $sudo_cmd dnf install -y podman
      elif command -v zypper >/dev/null 2>&1; then
        $sudo_cmd zypper install -y podman
      else
        echo "podman not found and no supported package manager detected (apt, dnf, zypper)" >&2
        exit 127
      fi

      command -v podman >/dev/null 2>&1 || {
        echo "podman is still unavailable after installation" >&2
        exit 1
      }
    }

    ensure_podman_macos() {
      if command -v podman >/dev/null 2>&1; then
        return 0
      fi
      if ! command -v brew >/dev/null 2>&1; then
        echo "podman not found and homebrew is unavailable" >&2
        exit 127
      fi
      brew install podman || {
        echo "failed to install podman via homebrew" >&2
        exit 1
      }
      command -v podman >/dev/null 2>&1 || {
        echo "podman is still unavailable after installation" >&2
        exit 1
      }
    }

    ensure_docker_cli_and_compose_linux() {
      if command -v docker >/dev/null 2>&1; then
        if docker compose version >/dev/null 2>&1 || command -v docker-compose >/dev/null 2>&1; then
          return 0
        fi
      fi

      sudo_cmd=$(determine_sudo)

      if command -v apt-get >/dev/null 2>&1; then
        $sudo_cmd apt-get update
        $sudo_cmd apt-get install -y docker.io docker-compose-plugin || \
          $sudo_cmd apt-get install -y docker.io docker-compose
      elif command -v dnf >/dev/null 2>&1; then
        $sudo_cmd dnf install -y docker docker-compose-plugin || \
          $sudo_cmd dnf install -y docker docker-compose
      elif command -v zypper >/dev/null 2>&1; then
        $sudo_cmd zypper install -y docker docker-compose
      else
        echo "docker CLI not found and no supported package manager detected (apt, dnf, zypper)" >&2
        exit 127
      fi

      command -v docker >/dev/null 2>&1 || {
        echo "docker CLI is still unavailable after installation" >&2
        exit 1
      }
    }

    ensure_docker_cli_and_compose_macos() {
      if command -v docker >/dev/null 2>&1; then
        if docker compose version >/dev/null 2>&1 || command -v docker-compose >/dev/null 2>&1; then
          return 0
        fi
      fi

      if ! command -v brew >/dev/null 2>&1; then
        echo "docker CLI not found and homebrew is unavailable" >&2
        exit 127
      fi

      brew install docker docker-compose || {
        echo "failed to install docker CLI/compose via homebrew" >&2
        exit 1
      }

      command -v docker >/dev/null 2>&1 || {
        echo "docker CLI is still unavailable after installation" >&2
        exit 1
      }
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

    case "$os_name" in
      Darwin)
        # ---------- macOS: podman machine + launchd cleanup ----------
        ensure_podman_macos
        ensure_docker_cli_and_compose_macos

        if [ "$#" -lt 1 ]; then
          echo "machine name (last argument) is required" >&2
          exit 2
        fi

        last_arg=$1
        for a; do last_arg=$a; done

        case "$last_arg" in
          '' )
            echo "machine name (last argument) is required" >&2
            exit 2
            ;;
          -* )
            echo "machine name (last argument) must not start with '-'" >&2
            exit 2
            ;;
          * )
            machine_name=$last_arg
            ;;
        esac

        uid=$(id -u)
        base_dir="$HOME/Library/Application Support/temp-podman-machine"
        launch_agents_dir="$HOME/Library/LaunchAgents"
        state_dir="$base_dir/state"
        cleanup_script="$base_dir/cleanup-agent.sh"
        agent_label="temp-podman-machine.cleanup"
        plist_path="$launch_agents_dir/${agent_label}.plist"

        mkdir -p "$base_dir" "$state_dir" "$launch_agents_dir"

        need_reload=0

        tmp_cleanup=$(mktemp "${TMPDIR:-/tmp}/temp-podman-cleanup.XXXXXX")
        cat >"$tmp_cleanup" <<'CLEANUP'
#!/bin/sh
set -eu
command -v podman >/dev/null 2>&1 || exit 0
base_dir="$HOME/Library/Application Support/temp-podman-machine"
state_dir="$base_dir/state"
[ -d "$state_dir" ] || exit 0
for f in "$state_dir"/*; do
  [ -f "$f" ] || continue
  machine=$(basename "$f")
  pid=$(sed -n '1p' "$f" 2>/dev/null || printf '')
  case "$pid" in
    ''|*[!0-9]*) rm -f "$f" 2>/dev/null || true; continue ;;
  esac
  if kill -0 "$pid" 2>/dev/null; then
    continue
  fi
  podman machine stop "$machine" || true
  podman machine rm -f "$machine" || true
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

        tmp_plist=$(mktemp "${TMPDIR:-/tmp}/temp-podman-plist.XXXXXX")
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
        if [ -f "$state_file" ]; then
          old_pid=$(sed -n '1p' "$state_file" 2>/dev/null || printf '')
          case "$old_pid" in
            ''|*[!0-9]*) rm -f "$state_file" 2>/dev/null || true ;;
            *)
              if kill -0 "$old_pid" 2>/dev/null; then
                echo "machine '$machine_name' already in use by pid $old_pid" >&2
                exit 1
              else
                if podman machine inspect "$machine_name" >/dev/null 2>&1; then
                  podman_cmd machine stop "$machine_name" || true
                  podman_cmd machine rm -f "$machine_name" || true
                fi
                rm -f "$state_file" 2>/dev/null || true
              fi
              ;;
          esac
        fi

        # Build init args without the machine name
        set -- "$@"
        init_args=
        for arg; do
          [ "$arg" = "$machine_name" ] && continue
          if [ -z "$init_args" ]; then
            init_args=$arg
          else
            init_args="$init_args $arg"
          fi
        done

        if podman machine inspect "$machine_name" >/dev/null 2>&1; then
          podman_cmd machine stop "$machine_name" || true
          podman_cmd machine rm -f "$machine_name" || true
        fi

        if [ -n "$init_args" ]; then
          # shellcheck disable=SC2086
          set -- $init_args
          podman_cmd machine init "$@" "$machine_name"
        else
          podman_cmd machine init "$machine_name"
        fi

        podman_cmd machine start "$machine_name"

        printf '%s\n' "$target_pid" >"$state_file"

        # Host-side helper socket (macOS filesystem)
        host_socket=$(podman machine inspect "$machine_name" \
          --format '{{.ConnectionInfo.PodmanSocket.Path}}' 2>/dev/null || printf '')

        if [ -z "$host_socket" ]; then
          echo "failed to determine podman host-side Docker API socket path for '$machine_name'" >&2
          exit 1
        fi

        # VM-side Podman socket (inside the Linux VM)
        vm_socket=""

        # Try to get URI from machine inspect and strip scheme/host
        vm_uri=$(podman machine inspect "$machine_name" \
          --format '{{.ConnectionInfo.PodmanSocket.URI}}' 2>/dev/null || printf '')

        if [ -n "$vm_uri" ]; then
          vm_socket=$(printf '%s\n' "$vm_uri" | sed -E 's#^[^/]*//[^/]+(/.*)#\1#')
        fi

        # Fallback: default connection URI
        if [ -z "$vm_socket" ]; then
          default_uri=$(podman system connection ls \
            --format '{{.Default}} {{.URI}}' 2>/dev/null | awk '$1=="true"{print $2; exit}' || printf '')
          if [ -n "$default_uri" ]; then
            vm_socket=$(printf '%s\n' "$default_uri" | sed -E 's#^[^/]*//[^/]+(/.*)#\1#')
          fi
        fi

        if [ -z "$vm_socket" ]; then
          # Reasonable Podman default inside the VM
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

          podman_cmd machine stop "$machine_name" || true
          podman_cmd machine rm -f "$machine_name" || true
          rm -f "$state_file" 2>/dev/null || true
        ) &

        printf 'DOCKER_HOST=unix://%s\n' "$host_socket"
        printf 'DOCKER_SOCKET=%s\n' "$vm_socket"
        ;;

      Linux)
        # ---------- Linux / WSL2: podman system service on a unix socket ----------
        ensure_podman_linux
        ensure_docker_cli_and_compose_linux

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
  )
}
