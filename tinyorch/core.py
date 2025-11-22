import os
import subprocess
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor


def dr(*a):
    subprocess.run(["docker", "run", "--rm", *a], check=True)


def dc(*a):
    subprocess.run(["docker", "compose", *a], check=True)


def notify(message: str, title_env: str = "JOB_CONTEXT", urls_env: str = "NOTIFY_URLS") -> None:
    urls = [u.strip() for u in os.getenv(urls_env, "").split(",") if u.strip()]
    if not urls:
        return
    title = os.getenv(title_env, "job")
    try:
        dr(
            "caronc/apprise:latest",
            "-t", title,
            "-b", message,
            *urls,
        )
    except Exception:
        pass


def run(stage: str, retries: int = 3, success_msg: str | None = None):
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
    for i in range(1, retries + 1):
        try:
            dc("run", "--rm", stage)
            mark.touch()
            if success_msg:
                notify(success_msg)
            return
        except Exception as e:
            err = e
            notify(f"{stage} failed ({i}/{retries}): {e}")
    raise err


def run_parallel(callables):
    cbs = [c for c in callables if c]
    if not cbs:
        return
    with ThreadPoolExecutor(max_workers=len(cbs)) as ex:
        for f in [ex.submit(c) for c in cbs]:
            f.result()
