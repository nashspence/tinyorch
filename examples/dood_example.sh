U=https://raw.githubusercontent.com/nashspence/tinyorch/main/tinyorch.sh
F=$HOME/.local/tinyorch-lib.sh
mkdir -p "$HOME/.local"
curl -fsSL -z "$F" "$U" -o "$F" 2>/dev/null || :
[ -r "$F" ] || { echo "missing lib" >&2; exit 1; }
. "$F"
eval "$(ensure_docker_host $$)"
export DOCKER_HOST DOCKER_SOCKET DOCKER

echo "DOCKER_HOST=$DOCKER_HOST"
echo "DOCKER_SOCKET=$DOCKER_SOCKET"

docker run --rm -it \
  --security-opt label=disable \
  --name podman-dood-test \
  --network=bridge \
  --hostname podman-dood \
  -e TZ="America/Los_Angeles" \
  -e DOCKER_HOST="unix:///var/run/docker.sock" \
  -v "$DOCKER_SOCKET:/var/run/docker.sock" \
  docker.io/library/ubuntu:22.04 \
  bash -euxo pipefail -c '
    echo "Inside outer container:"
    whoami
    uname -a
    echo "DOCKER_HOST=$DOCKER_HOST"
    echo

    # Install Docker CLI
    apt-get update
    apt-get install -y docker.io

    echo "=== docker version (talking to Podman via socket) ==="
    docker version || true
    echo

    echo "=== docker run nested alpine container ==="
    docker run --rm alpine:3.20 /bin/sh -c "
      echo \"Hello from nested container\";
      echo \"Nested uname: \";
      uname -a
    "
    echo

    echo "=== docker ps -a (from inside outer container) ==="
    docker ps -a
  '
