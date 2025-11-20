# tinyorch

Tiny helpers for orchestrating container-based media pipelines.

Provides:

- `dr(*args)`: thin wrapper around `docker run --rm ...`
- `notify(...)`: Apprise container-based notifier using `NOTIFY_URLS`
- `run_stage(...)`: stage runner with mark files, retries, and notifications
- `run_parallel(...)`: run a list of callables in parallel
- `rclone_sync(...)`: sync a local directory using rclone with a destination from an env var
