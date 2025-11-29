import getpass
import os
import platform
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import time
import threading
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from collections.abc import Callable
from typing import Dict, Iterable, Set

BASE_DIR = Path(os.environ.get("TINYORCH_HOME", Path.home() / ".tinyorch"))
STATE_DIR = BASE_DIR / "state"
RUN_DIR = BASE_DIR / "run"
TMP_DIR = Path(os.environ.get("TMPDIR", BASE_DIR / "tmp"))

STATE_DIR.mkdir(parents=True, exist_ok=True)
RUN_DIR.mkdir(parents=True, exist_ok=True)
TMP_DIR.mkdir(parents=True, exist_ok=True)


def print_cmd(*args):
    line = " ".join(shlex.quote(str(a)) for a in args)
    print()
    print("$ " + line)


def wait_for_files(paths, interval=5):
    ps = [p if isinstance(p, Path) else Path(p) for p in paths]
    while True:
        if all(p.exists() for p in ps):
            return
        time.sleep(interval)


def notify(
    message: str,
    title: str | None = None,
    url: str | None = None,
) -> None:
    if title is None:
        title = os.getenv("JOB", "job")
    urls_value = url if url is not None else os.getenv("NOTIFY", "")
    urls = [u.strip() for u in urls_value.split(",") if u.strip()]
    if not urls:
        return
    cmd = [
        docker,
        "run",
        "--rm",
        "caronc/apprise:latest",
        "apprise",
        "-t",
        title,
        "-b",
        message,
        *urls,
    ]
    try:
        print_cmd(*cmd)
        subprocess.run(cmd, check=True)
    except Exception as e:
        print(f"notify failed: {e!r}", file=sys.stderr)


def get_password(identifier: str, account: str | None = None) -> str:
    if not identifier:
        raise ValueError("identifier must be non-empty")

    system = platform.system()
    if account is None:
        account = os.environ.get("USER")
        if not account:
            import pwd

            account = pwd.getpwuid(os.getuid()).pw_name

    if system == "Darwin":
        proc = _run(
            ["security", "find-generic-password", "-a", account, "-s", identifier, "-w"],
            check=False,
            capture_output=True,
        )
        if proc.returncode == 0 and proc.stdout:
            return proc.stdout.strip()
    elif system == "Linux":
        if shutil.which("secret-tool") is None:
            raise RuntimeError(
                "secret-tool not found; install libsecret-tools or provide password another way"
            )
        proc = _run(
            ["secret-tool", "lookup", "service", identifier, "account", account],
            check=False,
            capture_output=True,
        )
        if proc.returncode == 0 and proc.stdout:
            return proc.stdout.strip()
    else:
        raise RuntimeError(f"Unsupported OS for password storage: {system}")

    prompt = f"Enter password for '{identifier}': "
    password = getpass.getpass(prompt)
    if not password:
        raise RuntimeError("Empty password not allowed")

    if system == "Darwin":
        _run(
            [
                "security",
                "add-generic-password",
                "-a",
                account,
                "-s",
                identifier,
                "-w",
                password,
                "-U",
            ],
            check=False,
        )
    elif system == "Linux":
        proc = subprocess.Popen(
            [
                "secret-tool",
                "store",
                f"--label={identifier}",
                "service",
                identifier,
                "account",
                account,
            ],
            stdin=subprocess.PIPE,
            text=True,
        )
        try:
            proc.communicate(password, timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.communicate()

    return password


def _run_once(cmd: str | list[str] | Callable[[], None]) -> None:
    if callable(cmd):
        cmd()
    elif isinstance(cmd, str):
        subprocess.run(cmd, shell=True, check=True)
    else:
        subprocess.run(cmd, check=True)


def run(
    stage: str,
    cmd: str | list[str] | Callable[[], None],
    retries: int | None = 0,          # None => infinite / interactive retry
    delay: float = 0.0,
    success_msg: str | None = None,
) -> None:
    mark = Path(os.getenv("RUN_DIR", ".")) / f".{stage}.done"
    if mark.exists():
        return

    infinite = retries is None
    if not infinite and retries < 0:
        raise ValueError("retries must be None or >= 0")

    attempt = 0
    last_error: Exception | None = None
    max_attempts = None if infinite else retries + 1

    while infinite or attempt < max_attempts:
        attempt += 1
        try:
            _run_once(cmd)
        except Exception as e:
            last_error = e
            if infinite:
                notify(f"{stage} failed (attempt {attempt}): {e}")
                if not sys.stdin.isatty():
                    break
                try:
                    answer = input(
                        f"[{stage}] failed (attempt {attempt}). "
                        f"Retry stage '{stage}'? [y/N]: "
                    ).strip().lower()
                except EOFError:
                    break
                if answer not in {"y", "yes"}:
                    break
            else:
                notify(f"{stage} failed ({attempt}/{max_attempts}): {e}")

            if delay > 0:
                time.sleep(delay)
        else:
            mark.touch()
            if success_msg:
                notify(success_msg)
            return

    if last_error is not None:
        raise last_error
    raise RuntimeError(f"stage {stage!r} failed")


def run_parallel(commands):
    cmds = [c for c in commands if c]
    if not cmds:
        return
    with ThreadPoolExecutor(max_workers=len(cmds)) as pool:
        futures = [pool.submit(_run_once, cmd) for cmd in cmds]
        for f in futures:
            f.result()


_keep_awake_proc = None
_keep_awake_pid = None


def keep_awake(pid: int | str):
    global _keep_awake_proc, _keep_awake_pid

    if pid is None:
        raise ValueError("pid is required")

    target_pid = str(pid)

    if _keep_awake_proc is not None:
        if _keep_awake_proc.poll() is None and _keep_awake_pid == target_pid:
            return
        _keep_awake_proc.terminate()
        try:
            _keep_awake_proc.wait(timeout=1)
        except subprocess.TimeoutExpired:
            _keep_awake_proc.kill()
        _keep_awake_proc = None
        _keep_awake_pid = None

    if shutil.which("caffeinate"):
        cmd = ["caffeinate", "-i", "-w", target_pid]
    elif shutil.which("systemd-inhibit") and platform.system() == "Linux":
        cmd = [
            "systemd-inhibit",
            "--what=sleep",
            "--mode=block",
            "--pid",
            target_pid,
            "sleep",
            "infinity",
        ]
    elif shutil.which("powershell.exe"):
        ps_script = r"""
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
"""
        cmd = ["powershell.exe", "-WindowStyle", "Hidden", "-Command", ps_script, "--", target_pid]
    else:
        _keep_awake_pid = None
        return
    print_cmd(*cmd)
    try:
        _keep_awake_proc = subprocess.Popen(cmd)
        _keep_awake_pid = target_pid
    except Exception as e:
        print(f"keep_awake failed: {e!r}", file=sys.stderr)
        _keep_awake_proc = None
        _keep_awake_pid = None


def prompt_enter(message=None):
    if not sys.stdin.isatty():
        return
    if message is None:
        message = "Press Enter to continue... "
    print(message, end="", file=sys.stderr, flush=True)
    try:
        input()
    except EOFError:
        pass


def burn_iso(iso, device=None):
    iso_path = Path(iso)
    if not iso_path.is_file():
        raise FileNotFoundError(f"burn_iso: file not found: {iso_path}")
    os_name = platform.system()
    if os_name == "Darwin" and shutil.which("drutil"):
        cmd = ["drutil", "burn", "-speed", "max", str(iso_path)]
        print_cmd(*cmd)
        subprocess.run(cmd, check=True)
        return
    if os_name == "Linux":
        kernel = platform.release()
        if "Microsoft" not in kernel and "microsoft" not in kernel:
            dev = device or os.getenv("BURN_DEV", "")
            if not dev:
                for candidate in ("/dev/dvd", "/dev/sr0", "/dev/cdrom"):
                    if os.path.exists(candidate):
                        dev = candidate
                        break
            if dev:
                if shutil.which("growisofs"):
                    cmd = [
                        "growisofs",
                        "-speed=MAX",
                        "-dvd-compat",
                        "-Z",
                        f"{dev}={iso_path}",
                    ]
                    print_cmd(*cmd)
                    subprocess.run(cmd, check=True)
                    return
                if shutil.which("wodim"):
                    cmd = [
                        "wodim",
                        f"dev={dev}",
                        "speed=max",
                        "-v",
                        "-data",
                        str(iso_path),
                    ]
                    print_cmd(*cmd)
                    subprocess.run(cmd, check=True)
                    return
                if shutil.which("cdrecord"):
                    cmd = [
                        "cdrecord",
                        f"dev={dev}",
                        "speed=max",
                        "-v",
                        "-data",
                        str(iso_path),
                    ]
                    print_cmd(*cmd)
                    subprocess.run(cmd, check=True)
                    return
    print(
        f"burn_iso: automatic burning not available; burn this ISO manually: {iso_path}",
        file=sys.stderr,
    )

def _run(
    args: Iterable[str],
    *,
    check: bool = True,
    capture_output: bool = False,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        list(args),
        check=check,
        text=True,
        capture_output=capture_output,
    )


def _pid_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


def _read_state_pids(path: Path) -> Set[int]:
    if not path.exists():
        return set()
    pids: Set[int] = set()
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line.isdigit():
            continue
        pid = int(line)
        if _pid_alive(pid):
            pids.add(pid)
    return pids


def _write_state_pids(path: Path, pids: Iterable[int]) -> None:
    uniq = sorted({p for p in pids if p > 0})
    if not uniq:
        try:
            path.unlink()
        except FileNotFoundError:
            pass
        return
    path.write_text("".join(f"{p}\n" for p in uniq))


def _int_or_default(value: str, default: int) -> int:
    try:
        return int(value)
    except (ValueError, TypeError):
        return default


def _podman_cmd(*args: str) -> None:
    cmd = ["podman", *args]
    stream = sys.stderr
    if sys.stderr.isatty():
        stream.write("+ " + " ".join(cmd) + "\n")
    _run(cmd, check=False)


def _spawn(*args: str) -> None:
    """
    Spawn a detached helper process.

    The first argument should be the executable name (e.g. 'watch-darwin'
    or 'watch-linux'), followed by its arguments.
    """
    subprocess.Popen(
        list(args),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        stdin=subprocess.DEVNULL,
        start_new_session=True,
    )


def _is_socket(path: Path) -> bool:
    try:
        st = path.stat()
    except FileNotFoundError:
        return False
    return stat.S_ISSOCK(st.st_mode)


def _ensure_docker_host_darwin(parent_pid: int) -> Dict[str, str]:
    machine_name = "tinyorch"
    state_file = STATE_DIR / machine_name

    alive_pids = _read_state_pids(state_file)

    try:
        _run(["podman", "machine", "inspect", machine_name], check=True)
        proc = _run(
            [
                "podman",
                "machine",
                "inspect",
                machine_name,
                "--format",
                "{{.State}}",
            ],
            check=False,
            capture_output=True,
        )
        machine_state = proc.stdout.strip() if proc.stdout else ""
    except subprocess.CalledProcessError:
        cpus_raw = _run(["sysctl", "-n", "hw.ncpu"], check=False, capture_output=True).stdout.strip()
        mem_bytes_raw = _run(
            ["sysctl", "-n", "hw.memsize"], check=False, capture_output=True
        ).stdout.strip()
        df_proc = _run(["df", "-k", "/"], check=False, capture_output=True)
        fields = df_proc.stdout.splitlines()[1].split()
        disk_total_kb_raw = fields[1] if len(fields) > 1 else "0"

        cpus = _int_or_default(cpus_raw, 1)
        mem_bytes = _int_or_default(mem_bytes_raw, 0)
        disk_total_kb = _int_or_default(disk_total_kb_raw, 0)

        memory_mb = mem_bytes // 1024 // 1024 * 80 // 100
        if memory_mb < 512:
            memory_mb = 512

        disk_size_gb = disk_total_kb * 80 // 100 // 1024 // 1024
        if disk_size_gb < 10:
            disk_size_gb = 10

        _podman_cmd(
            "machine",
            "init",
            machine_name,
            "--cpus",
            str(cpus),
            "--memory",
            str(memory_mb),
            "--disk-size",
            str(disk_size_gb),
            "--volume",
            "/Users:/Users",
            "--volume",
            "/Volumes:/Volumes",
        )
        machine_state = "stopped"

    if machine_state != "running":
        _podman_cmd("machine", "start", machine_name)

    all_pids = {parent_pid, *alive_pids}
    _write_state_pids(state_file, all_pids)

    proc = _run(
        [
            "podman",
            "machine",
            "inspect",
            machine_name,
            "--format",
            "{{.ConnectionInfo.PodmanSocket.Path}}",
        ],
        check=False,
        capture_output=True,
    )
    host_socket = proc.stdout.strip()
    if not host_socket:
        raise RuntimeError(
            f"failed to determine podman host-side Docker API socket path for '{machine_name}'"
        )

    vm_socket = ""
    proc = _run(
        [
            "podman",
            "machine",
            "inspect",
            machine_name,
            "--format",
            "{{.ConnectionInfo.PodmanSocket.URI}}",
        ],
        check=False,
        capture_output=True,
    )
    uri = proc.stdout.strip()
    if uri:
        # strip scheme and host to leave path
        # e.g. unix:///run/user/1000/podman/podman.sock -> /run/user/1000/podman/podman.sock
        parts = uri.split("://", 1)
        if len(parts) == 2:
            after_scheme = parts[1]
            slash_index = after_scheme.find("/")
            if slash_index != -1:
                vm_socket = after_scheme[slash_index:]

    proc = _run(
        [
            "podman",
            "machine",
            "inspect",
            machine_name,
            "--format",
            "{{.Rootful}}",
        ],
        check=False,
        capture_output=True,
    )
    rootful_str = proc.stdout.strip() or "true"
    rootful = rootful_str.lower() != "false"
    if not rootful:
        vm_socket = f"/run/user/{os.getuid()}/podman/podman.sock"

    if not vm_socket:
        proc = _run(
            ["podman", "system", "connection", "ls", "--format", "{{.Default}} {{.URI}}"],
            check=False,
            capture_output=True,
        )
        for line in proc.stdout.splitlines():
            parts = line.split()
            if len(parts) == 2 and parts[0] == "true":
                uri = parts[1]
                u_parts = uri.split("://", 1)
                if len(u_parts) == 2:
                    after_scheme = u_parts[1]
                    slash_index = after_scheme.find("/")
                    if slash_index != -1:
                        vm_socket = after_scheme[slash_index:]
                        break

    if not vm_socket:
        vm_socket = f"/run/user/{os.getuid()}/podman/podman.sock"

    _spawn("watch-darwin", machine_name, str(parent_pid), str(state_file))

    return {
        "DOCKER_HOST": f"unix://{host_socket}",
        "DOCKER_SOCKET": vm_socket,
    }


def watch_darwin(machine_name: str, parent_pid: int, state_file: Path) -> None:
    while _pid_alive(parent_pid):
        time.sleep(2)

    remaining = _read_state_pids(state_file)
    if parent_pid in remaining:
        remaining.remove(parent_pid)

    if remaining:
        _write_state_pids(state_file, remaining)
        return

    _podman_cmd(
        "machine",
        "ssh",
        machine_name,
        "--",
        "podman",
        "system",
        "prune",
        "-a",
        "--volumes",
        "--force",
        "--filter",
        "until=720h",
    )
    _podman_cmd("machine", "stop", machine_name)
    try:
        state_file.unlink()
    except FileNotFoundError:
        pass


def _ensure_docker_host_linux(parent_pid: int) -> Dict[str, str]:
    socket_path = RUN_DIR / f"podman-docker-{parent_pid}.sock"
    try:
        socket_path.unlink()
    except FileNotFoundError:
        pass

    proc = subprocess.Popen(
        ["podman", "system", "service", "--time=0", f"unix://{socket_path}"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        stdin=subprocess.DEVNULL,
        start_new_session=True,
    )
    service_pid = proc.pid

    for _ in range(50):
        if _is_socket(socket_path):
            break
        time.sleep(0.1)
    else:
        try:
            os.kill(service_pid, signal.SIGTERM)
        except OSError:
            pass
        raise RuntimeError(
            f"failed to start podman system service; socket '{socket_path}' not created"
        )

    _spawn("watch-linux", str(parent_pid), str(service_pid), str(socket_path))

    return {
        "DOCKER_HOST": f"unix://{socket_path}",
        "DOCKER_SOCKET": str(socket_path),
    }


def watch_linux(parent_pid: int, service_pid: int, socket_path: Path) -> None:
    while _pid_alive(parent_pid):
        time.sleep(2)

    for sig in (signal.SIGTERM, signal.SIGINT):
        try:
            os.kill(service_pid, sig)
        except OSError:
            break
        time.sleep(1)
        if not _pid_alive(service_pid):
            break

    if _pid_alive(service_pid):
        try:
            os.kill(service_pid, signal.SIGKILL)
        except OSError:
            pass

    try:
        socket_path.unlink()
    except FileNotFoundError:
        pass


def ensure_docker_host(parent_pid: int) -> Dict[str, str]:
    if parent_pid <= 0:
        raise ValueError("parent_pid must be positive")

    system = platform.system()
    if system == "Darwin":
        return _ensure_docker_host_darwin(parent_pid)
    if system == "Linux":
        return _ensure_docker_host_linux(parent_pid)
    raise RuntimeError(f"ensure_docker_host: unsupported OS '{system}'")

