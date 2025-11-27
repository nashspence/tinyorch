import os
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path


def _require_docker() -> str:
    docker_path = shutil.which("docker")
    if not docker_path:
        raise RuntimeError(
            "The Docker CLI is required but was not found in PATH. Install Docker "
            "or ensure the 'docker' executable is available before running tinyorch commands."
        )
    return docker_path


def dr(*a):
    docker = _require_docker()
    cmd = [docker, "run", "--rm", *a]
    print("\n$ " + " ".join(shlex.quote(str(x)) for x in cmd))
    subprocess.run(cmd, check=True)


def dc(*a):
    docker = _require_docker()
    cmd = [docker, "compose", *a]
    print("\n$ " + " ".join(shlex.quote(str(x)) for x in cmd))
    subprocess.run(cmd, check=True)


def notify(message: str, title_env: str = "JOB", urls_env: str = "NOTIFY") -> None:
    urls = [u.strip() for u in os.getenv(urls_env, "").split(",") if u.strip()]
    if not urls:
        return
    title = os.getenv(title_env, "job")
    try:
        dr(
            "caronc/apprise:latest",
            "apprise",
            "-t", title,
            "-b", message,
            *urls,
        )
    except Exception as e:
        print(f"notify: failed: {e!r}", file=sys.stderr)
        pass


def run(stage: str, retries: int = 0, success_msg: str | None = None):
    root = Path(os.getenv("RUN_DIR", "."))
    mark = root / f".{stage}.done"
    if mark.exists():
        return
    err: Exception | None = None
    if retries == -1:
        attempt = 0
        while True:
            attempt += 1
            try:
                dc("run", "--rm", stage)
                mark.touch()
                if success_msg:
                    notify(success_msg)
                return
            except Exception as e:
                err = e
                notify(f"{stage} failed (attempt {attempt}): {e}")
                if not sys.stdin.isatty():
                    break
                try:
                    answer = input(
                        f"[{stage}] failed (attempt {attempt}). Retry stage '{stage}'? [y/N]: "
                    ).strip().lower()
                except EOFError:
                    break
                if answer not in ("y", "yes"):
                    break
        raise err
    if retries < 0:
        raise ValueError("retries must be -1 (interactive) or >= 0")
    total_attempts = retries + 1
    for attempt in range(total_attempts):
        try:
            dc("run", "--rm", stage)
            mark.touch()
            if success_msg:
                notify(success_msg)
            return
        except Exception as e:
            err = e
            notify(f"{stage} failed ({attempt + 1}/{total_attempts}): {e}")
    if err:
        raise err
    raise RuntimeError(f"Stage '{stage}' failed without raising an exception")


def run_parallel(callables):
    cbs = [c for c in callables if c]
    if not cbs:
        return
    with ThreadPoolExecutor(max_workers=len(cbs)) as ex:
        for f in [ex.submit(c) for c in cbs]:
            f.result()
