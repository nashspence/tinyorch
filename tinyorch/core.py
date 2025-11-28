import getpass
import os
import platform
import shlex
import shutil
import subprocess
import sys
import time
import threading
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from collections.abc import Callable


def print_cmd(*args):
    line = " ".join(shlex.quote(str(a)) for a in args)
    print()
    print("$ " + line)


def _require_docker():
    docker_path = shutil.which("docker")
    if not docker_path:
        raise RuntimeError("docker executable not found in PATH")
    return docker_path


def ensure_docker_host():
    pid = os.getpid()
    cmd = ["ensure_docker_host", "{pid}"]
    print_cmd(cmd)
    subprocess.run(cmd, check=True)


def dr(*args):
    docker = _require_docker()
    cmd = [docker, "run", "--rm", *args]
    print_cmd(*cmd)
    subprocess.run(cmd, check=True)


def docker(image, *cmd, env=None, volumes=None, interactive=True):
    args = []
    if interactive:
        args.append("-it")
    if env:
        for k, v in env.items():
            args += ["-e", f"{k}={v}"]
    if volumes:
        for host, container in volumes:
            args += ["-v", f"{str(host)}:{container}"]
    args.append(image)
    args.extend(cmd)
    return dr(*args)


def ensure_dir(root, *parts):
    base = root if isinstance(root, Path) else Path(root)
    d = base.joinpath(*parts)
    d.mkdir(parents=True, exist_ok=True)
    return d


def wait_for_files(paths, interval=5):
    ps = [p if isinstance(p, Path) else Path(p) for p in paths]
    while True:
        if all(p.exists() for p in ps):
            return
        time.sleep(interval)


def spawn(fn, daemon=True, name=None):
    t = threading.Thread(target=fn, daemon=daemon, name=name)
    t.start()
    return t


def notify(message, title_env="JOB", urls_env="NOTIFY"):
    urls_value = os.getenv(urls_env, "")
    urls = [u.strip() for u in urls_value.split(",") if u.strip()]
    if not urls:
        return
    title = os.getenv(title_env, "job")
    try:
        dr("caronc/apprise:latest", "apprise", "-t", title, "-b", message, *urls)
    except Exception as e:
        print(f"notify failed: {e!r}", file=sys.stderr)


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


def keep_awake():
    global _keep_awake_proc
    if _keep_awake_proc is not None and _keep_awake_proc.poll() is None:
        return
    pid = str(os.getpid())
    if shutil.which("caffeinate"):
        cmd = ["caffeinate", "-i", "-w", pid]
    elif shutil.which("systemd-inhibit") and platform.system() == "Linux":
        cmd = [
            "systemd-inhibit",
            "--what=sleep",
            "--mode=block",
            "--pid",
            pid,
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
        cmd = ["powershell.exe", "-WindowStyle", "Hidden", "-Command", ps_script, "--", pid]
    else:
        return
    print_cmd(*cmd)
    try:
        _keep_awake_proc = subprocess.Popen(cmd)
    except Exception as e:
        print(f"keep_awake failed: {e!r}", file=sys.stderr)
        _keep_awake_proc = None


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
