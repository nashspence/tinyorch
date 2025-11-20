import os, subprocess
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor

def dr(*a):
    """Thin wrapper for `docker run --rm ...`."""
    subprocess.run(["docker", "run", "--rm", *a], check=True)

def notify(job_context: str, message: str, env_var: str = "NOTIFY_URLS") -> None:
    """Send a notification using Apprise URLs from an environment variable."""
    urls = [u.strip() for u in os.getenv(env_var, "").split(",") if u.strip()]
    if not urls:
        return
    dr(
        "caronc/apprise:latest",
        "-t",
        job_context,
        "-b",
        message,
        *urls,
    )

def run_stage(
    mark: Path,
    label: str,
    fn,
    notify,
    retries: int = 3,
    success_msg: str | None = None,
):
    """
    Run a stage with a .done mark file, retries, and notifications.
    - mark: Path to .done file
    - fn: callable performing the work
    - notify: callable(message: str)
    """
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
            notify(f"{label} failed ({i}/{retries}): {e}")
    raise err

def run_parallel(callables):
    """
    Run a list of callables in parallel; ignore any Nones in the list.
    Raises on first exception.
    """
    cbs = [c for c in callables if c]
    if not cbs:
        return
    with ThreadPoolExecutor(max_workers=len(cbs)) as ex:
        for f in [ex.submit(c) for c in cbs]:
            f.result()

def rclone_sync(
    local_dir: Path,
    dest_env: str = "RCLONE_DEST",
    notify=lambda m: None,
):
    """
    Use rclone/rclone container to sync local_dir to destination specified
    in an environment variable (e.g. RCLONE_DEST).
    """
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
