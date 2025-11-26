#!/usr/bin/env sh

notify() {
    message=${1-}
    title_env=${2-JOB}
    urls_env=${3-NOTIFY}
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
    docker run --rm caronc/apprise:latest apprise -t "$title" -b "$message" "$@" || true
}

run() {
    stage=$1
    retries=$2
    success_msg=$3

    shift 3

    root=${RUN_DIR-.}
    mark="$root/.${stage}.done"

    [ -e "$mark" ] && return 0

    if [ "$#" -eq 0 ]; then
        set -- dc run --rm "$stage"
    fi

    if [ "x$retries" = "x-1" ]; then
        attempt=0
        last_status=0
        while :; do
            attempt=$((attempt + 1))
            if "$@"; then
                : >"$mark"
                [ -n "$success_msg" ] && notify "$success_msg"
                return 0
            fi
            last_status=$?
            notify "$stage failed (attempt $attempt): exited with status $last_status"

            if ! [ -t 0 ]; then
                break
            fi

            printf '[%s] failed (attempt %s). Retry stage "%s"? [y/N]: ' \
                "$stage" "$attempt" "$stage" >&2

            if ! IFS= read -r answer; then
                break
            fi

            case $answer in
                y|Y|yes|YES) ;;
                *) break ;;
            esac
        done
        return "$last_status"
    fi

    case $retries in
        ''|*[!0-9]*)
            printf 'run: retries must be -1 or a non-negative integer (got "%s")\n' \
                "$retries" >&2
            return 2
            ;;
    esac

    attempt=1
    last_status=0
    while [ "$attempt" -le "$retries" ]; do
        if "$@"; then
            : >"$mark"
            [ -n "$success_msg" ] && notify "$success_msg"
            return 0
        fi
        last_status=$?
        notify "$stage failed ($attempt/$retries): exited with status $last_status"
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

keep_awake() {
    if command -v caffeinate >/dev/null 2>&1; then
        caffeinate -i -w "$$" &
    elif command -v systemd-inhibit >/dev/null 2>&1; then
        systemd-inhibit --what=sleep --mode=block --pid "$$" sleep infinity &
    elif command -v powershell.exe >/dev/null 2>&1; then
        powershell.exe -WindowStyle Hidden -Command '
            param($p)
            Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class A {
    [DllImport("kernel32.dll")]
    public static extern uint SetThreadExecutionState(uint e);
}
"@
            $f=0x80000002
            while(Get-Process -Id $p -ErrorAction SilentlyContinue){
                [A]::SetThreadExecutionState($f)|Out-Null
                Start-Sleep 30
            }
        ' -- "$$" &
    fi
}

prompt_enter() {
    # $1 = message to show (optional)
    if [ -t 0 ]; then
        if [ -n "$1" ]; then
            printf "%s" "$1" >&2
        else
            printf "Press Enter to continue... " >&2
        fi

        IFS= read -r _ || true
    fi
}

burn_iso() {
    iso=$1

    [ -z "$iso" ] && { printf 'usage: burn_iso ISO_PATH\n' >&2; return 2; }
    [ ! -f "$iso" ] && { printf 'burn_iso: file not found: %s\n' "$iso" >&2; return 1; }

    os=$(uname 2>/dev/null || printf unknown)

    if [ "$os" = Darwin ] && command -v drutil >/dev/null 2>&1; then
        drutil burn -speed max "$iso" && return 0
    fi

    if [ "$os" = Linux ]; then
        kernel=$(uname -r 2>/dev/null || printf '')
        case $kernel in
            *Microsoft*|*microsoft*) : ;;
            *)
                dev=${BURN_DEV-}
                if [ -z "$dev" ]; then
                    for d in /dev/dvd /dev/sr0 /dev/cdrom; do
                        [ -e "$d" ] && { dev=$d; break; }
                    done
                fi

                if [ -n "$dev" ]; then
                    if command -v growisofs >/dev/null 2>&1; then
                        growisofs -speed=MAX -dvd-compat -Z "$dev"="$iso" && return 0
                    elif command -v wodim >/dev/null 2>&1; then
                        wodim dev="$dev" speed=max -v -data "$iso" && return 0
                    elif command -v cdrecord >/dev/null 2>&1; then
                        cdrecord dev="$dev" speed=max -v -data "$iso" && return 0
                    fi
                fi
                ;;
        esac
    fi

    printf 'burn_iso: automatic burning not available; burn this ISO manually: %s\n' "$iso" >&2
    return 0
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

    if [ "$#" -ne 1 ]; then
      echo "usage: ensure_docker_host <parent_pid>" >&2
      exit 2
    fi

    target_pid=$1
    case "$target_pid" in
      ''|*[!0-9]*) echo "invalid parent pid: $target_pid" >&2; exit 2 ;;
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

    macos_machine_defaults() {
      cpus=$(sysctl -n hw.ncpu 2>/dev/null || printf '1')
      case "$cpus" in
        ''|*[!0-9]*) cpus=1 ;;
      esac

      mem_bytes=$(sysctl -n hw.memsize 2>/dev/null || printf '0')
      case "$mem_bytes" in
        ''|*[!0-9]*) mem_bytes=0 ;;
      esac
      memory_mb=$((mem_bytes / 1024 / 1024 * 80 / 100))
      if [ "$memory_mb" -lt 512 ] 2>/dev/null; then
        memory_mb=512
      fi

      disk_total_kb=$(df -k / 2>/dev/null | awk 'NR==2 {print $2}' || printf '0')
      case "$disk_total_kb" in
        ''|*[!0-9]*) disk_total_kb=0 ;;
      esac
      disk_size_gb=$((disk_total_kb * 80 / 100 / 1024 / 1024))
      if [ "$disk_size_gb" -lt 10 ] 2>/dev/null; then
        disk_size_gb=10
      fi

      printf '%s\n' "$cpus" "$memory_mb" "$disk_size_gb"
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

        machine_name="tinyorch"

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
                fi
                rm -f "$state_file" 2>/dev/null || true
              fi
              ;;
          esac
        fi

        if ! podman machine inspect "$machine_name" >/dev/null 2>&1; then
          set -- $(macos_machine_defaults)
          machine_cpus=$1
          machine_memory_mb=$2
          machine_disk_gb=$3

          podman_cmd machine init "$machine_name" \
            --cpus "$machine_cpus" \
            --memory "$machine_memory_mb" \
            --disk-size "$machine_disk_gb" \
            --volume /Users:/Users \
            --volume /Volumes:/Volumes
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

                # VM-side Podman socket (inside the Linux VM)
        vm_socket=""

        # Try to get URI from machine inspect and strip scheme/host
        vm_uri=$(podman machine inspect "$machine_name" \
          --format '{{.ConnectionInfo.PodmanSocket.URI}}' 2>/dev/null || printf '')

        if [ -n "$vm_uri" ]; then
          vm_socket=$(printf '%s\n' "$vm_uri" | sed -E 's#^[^/]*//[^/]+(/.*)#\1#')
        fi

        # --- minimal fix: correct socket path for rootless machines ---
        rootful=$(podman machine inspect "$machine_name" \
          --format '{{.Rootful}}' 2>/dev/null || echo true)
        if [ "$rootful" = "false" ]; then
          # Rootless podman uses /run/user/<uid>/podman/podman.sock inside the VM
          vm_socket="/run/user/$(id -u)/podman/podman.sock"
        fi
        # --- end minimal fix ---

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

          podman_cmd machine ssh "$machine_name" -- podman system prune -a --volumes --force --filter "until=720h" || true
          podman_cmd machine stop "$machine_name" || true
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
