#!/usr/bin/env sh

# POSIX shell utilities analogous to tinyorch.core

# Run a docker container with the provided arguments and automatically remove it when done.
dr() {
    docker run --rm "$@"
}

# Run docker compose with the provided arguments.
dc() {
    docker compose "$@"
}

# Send a notification using the caronc/apprise container.
# Usage: notify "message" [title_env] [urls_env]
#   title_env defaults to JOB_CONTEXT; urls_env defaults to NOTIFY_URLS.
notify() {
    message=${1-}
    title_env=${2-JOB_CONTEXT}
    urls_env=${3-NOTIFY_URLS}

    # Resolve the title from the provided environment variable name, falling back to "job".
    eval "title=\${${title_env}-job}"
    urls_value=$(printenv "$urls_env")

    # Exit early if there are no URLs to notify.
    [ -n "$urls_value" ] || return 0

    # Build the list of URLs by splitting on commas and trimming whitespace.
    set --
    IFS=','
    for raw_url in $urls_value; do
        url=$(printf '%s' "$raw_url" | sed 's/^ *//;s/ *$//')
        [ -n "$url" ] && set -- "$@" "$url"
    done
    IFS=' \t\n'

    [ $# -gt 0 ] || return 0

    # Ignore failures so notifications do not interrupt main workflows.
    dr caronc/apprise:latest -t "$title" -b "$message" "$@" || true
}

# Run a docker compose stage with retries and an optional success notification.
# Usage: run "stage" [retries] [success_message]
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

# Run multiple commands in parallel, waiting for all to finish.
# Each argument should be a command string.
run_parallel() {
    pids=""

    for cmd in "$@"; do
        [ -n "$cmd" ] || continue
        (
            # Evaluate the command in a subshell.
            sh -c "$cmd"
        ) &
        pids="$pids $!"
    done

    for pid in $pids; do
        wait "$pid"
    done
}
