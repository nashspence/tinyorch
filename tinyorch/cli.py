# tinyorch/cli.py
from __future__ import annotations

import argparse
import os
import shlex
import sys
from pathlib import Path

from .core import (
    notify as _notify,
    get_password as _get_password,
    run as _run_stage,
    run_parallel as _run_parallel,
    keep_awake as _keep_awake,
    prompt_enter as _prompt_enter,
    burn_iso as _burn_iso,
    ensure_docker_host as _ensure_docker_host,
    watch_darwin as _watch_darwin,
    watch_linux as _watch_linux, 
)


def main_notify(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(
        prog="notify",
        description="Send a notification via Apprise using tinyorch.core.notify",
    )
    parser.add_argument("message", help="Notification message body")
    parser.add_argument(
        "--title",
        help="Notification title (defaults to $JOB or 'job' if unset)",
    )
    parser.add_argument(
        "--url",
        help=(
            "Notification URL (defaults to $NOTIFY). "
            "May be a single URL or a comma-separated list."
        ),
    )
    ns = parser.parse_args(argv)
    _notify(ns.message, title=ns.title, url=ns.url)


def main_get_password(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(
        prog="get-password",
        description="Retrieve a password using get_password, prompting and storing it if needed.",
    )
    parser.add_argument(
        "identifier",
        help="Password identifier / service name (used as the keyring 'service')",
    )
    parser.add_argument(
        "--account",
        help="Account / username (defaults to $USER or current login user)",
    )
    ns = parser.parse_args(argv)
    password = get_password(ns.identifier, account=ns.account)
    print(password)


def main_run(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(
        prog="run",
        description="Run a named stage with retries using tinyorch.core.run",
    )
    parser.add_argument("stage", help="Stage name (used for .<stage>.done marker)")
    parser.add_argument(
        "--retries",
        type=int,
        default=0,
        help=(
            "Number of retries (0 = no retries, N > 0 = max retries). "
            "Use --interactive for infinite interactive retries."
        ),
    )
    parser.add_argument(
        "--interactive",
        action="store_true",
        help="Enable infinite interactive retries (maps to retries=None)",
    )
    parser.add_argument(
        "--delay",
        type=float,
        default=0.0,
        help="Delay in seconds between retries",
    )
    parser.add_argument(
        "--success-msg",
        help="Optional notification message on success",
    )
    parser.add_argument(
        "cmd",
        nargs=argparse.REMAINDER,
        help="Command to run (passed as a shell string)",
    )
    ns = parser.parse_args(argv)

    if not ns.cmd:
        parser.error("you must provide a command to run")

    # Convert list of tokens back to a shell string
    cmd_str = " ".join(shlex.quote(c) for c in ns.cmd if c != "--")

    # Map CLI flags to core.run() semantics
    if ns.interactive:
        retries: int | None = None  # infinite / interactive
    else:
        if ns.retries < 0:
            parser.error("--retries must be >= 0 (or use --interactive)")
        retries = ns.retries

    _run_stage(
        ns.stage,
        cmd_str,
        retries=retries,
        delay=ns.delay,
        success_msg=ns.success_msg,
    )



def main_run_parallel(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(
        prog="run-parallel",
        description="Run multiple commands in parallel using tinyorch.core.run_parallel",
    )
    parser.add_argument(
        "-c",
        "--cmd",
        action="append",
        dest="cmds",
        metavar="COMMAND",
        help="Command to run (can be specified multiple times)",
    )
    parser.add_argument(
        "rest",
        nargs=argparse.REMAINDER,
        help="Extra commands (each treated as a separate command token)",
    )
    ns = parser.parse_args(argv)

    cmds: list[str] = []
    if ns.cmds:
        cmds.extend(ns.cmds)
    if ns.rest:
        # allow simple usage: run-parallel 'echo 1' 'echo 2'
        cmds.extend(ns.rest)

    if not cmds:
        parser.error("no commands provided (use -c/--cmd or positional commands)")

    _run_parallel(cmds)


def main_keep_awake(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(
        prog="keep-awake",
        description="Prevent the system from sleeping while the given process is running",
    )
    parser.add_argument(
        "pid",
        type=int,
        help="Process ID to keep awake",
    )
    ns = parser.parse_args(argv)

    _keep_awake(ns.pid)


def main_prompt_enter(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(
        prog="prompt-enter",
        description="Prompt the user to press Enter using tinyorch.core.prompt_enter",
    )
    parser.add_argument(
        "message",
        nargs="?",
        default=None,
        help="Optional custom prompt message",
    )
    ns = parser.parse_args(argv)
    _prompt_enter(ns.message)


def main_burn_iso(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(
        prog="burn-iso",
        description="Burn an ISO image to disc using tinyorch.core.burn_iso",
    )
    parser.add_argument("iso", help="Path to ISO file")
    parser.add_argument(
        "--device",
        help="Device path to burn to (overrides BURN_DEV / autodetect)",
    )
    ns = parser.parse_args(argv)
    _burn_iso(ns.iso, device=ns.device)


def main_ensure_docker_host(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(
        prog="ensure-docker-host",
        description="Ensure a Docker-compatible Podman socket for the given PID and print env exports",
    )
    parser.add_argument(
        "pid",
        type=int,
        help="PID of the process whose environment should be used",
    )
    parser.add_argument(
        "--format",
        choices=["export", "env", "json"],
        default="export",
        help="Output format: shell exports, KEY=VALUE, or JSON",
    )
    ns = parser.parse_args(argv)

    env = _ensure_docker_host(ns.pid)

    if ns.format == "json":
        json.dump(env, sys.stdout)
        sys.stdout.write("\n")
        return

    if ns.format == "env":
        for k, v in env.items():
            sys.stdout.write(f"{k}={v}\n")
        return

    for k, v in env.items():
        sys.stdout.write(f"export {k}={shlex.quote(v)}\n")


def main_watch_darwin(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(
        prog="watch_darwin",
        description="Watch a tinyorch Podman machine and clean it up when parent exits",
    )
    parser.add_argument("machine_name", help="Podman machine name (e.g. 'tinyorch')")
    parser.add_argument("parent_pid", type=int, help="PID of the parent process to watch")
    parser.add_argument("state_file", help="Path to the state file tracking PIDs")
    ns = parser.parse_args(argv)

    _watch_darwin(ns.machine_name, ns.parent_pid, Path(ns.state_file))


def main_watch_linux(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(
        prog="watch_linux",
        description="Watch a Podman system service and clean it up when parent exits",
    )
    parser.add_argument("parent_pid", type=int, help="PID of the parent process to watch")
    parser.add_argument("service_pid", type=int, help="PID of the 'podman system service' process")
    parser.add_argument("socket_path", help="Path to the Podman service socket")
    ns = parser.parse_args(argv)

    _watch_linux(ns.parent_pid, ns.service_pid, Path(ns.socket_path))

