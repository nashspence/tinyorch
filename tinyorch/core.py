import os
import subprocess
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor


def dr(*a):
    subprocess.run(["docker", "run", "--rm", *a], check=True)


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


def run_stage(stage: str, fn, retries: int = 3, success_msg: str | None = None):
    root = Path(os.getenv("RUN_DIR", "."))
    mark = root / f".{stage}.done"
    if mark.exists():
        return
    err = None
    for i in range(1, retries + 1):
        try:
            fn()
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


def rclone_sync(local_dir: Path, dest_env: str = "RCLONE_DEST") -> None:
    dest = os.getenv(dest_env)
    if not dest:
        notify(f"{dest_env} not set; skipping sync")
        return
    dr(
        "-v", f"{local_dir}:/data",
        "rclone/rclone:latest",
        "copy", "/data", dest,
        "--exclude", "/.*",
        "--exclude", "**/.*",
    )


def rsync_import(source_dir: Path, stage_dir: Path) -> None:
    dr(
        "-v", f"{source_dir}:/in:ro",
        "-v", f"{stage_dir}:/out",
        "instrumentisto/rsync-ssh:latest", "sh", "-lc",
        "rsync -a --partial --info=progress2 "
        "--exclude '/.*' --exclude '**/.*' "
        "--remove-source-files /in/ /out/ && "
        "find /in -depth -type d -empty -delete"
    )
