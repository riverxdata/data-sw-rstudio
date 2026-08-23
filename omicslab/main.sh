#!/bin/bash
set -euo pipefail

R_VERSION="${r_version:-4.4.2}"
CONTAINER_IMAGE="docker.io/rocker/rstudio:${R_VERSION}"
CONTAINER_NAME="rstudio-server"
PORT=8787

TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Podman is provided by the pixi workspace (installed by the bootstrap).
PODMAN="pixi run podman"
echo "Using podman: $($PODMAN --version)"

# --- Detect environment: podman-in-Docker vs real VM ---
_is_overlayfs() {
    local fs
    fs=$(stat -f -c '%T' / 2>/dev/null || echo "unknown")
    [ "$fs" = "overlayfs" ]
}

# --- Podman configuration ---
_configure_podman() {
    local PIXI_PREFIX
    PIXI_PREFIX="$(dirname "$(dirname "$($PODMAN --which podman 2>/dev/null)")")"

    if [ ! -f /etc/containers/policy.json ]; then
        mkdir -p /etc/containers
        cat > /etc/containers/policy.json <<'POLICY'
{
  "default": [{"type": "insecureAcceptAnything"}]
}
POLICY
    fi

    if _is_overlayfs; then
        echo "Detected overlayfs root — configuring podman for Docker-in-Docker"
        if ! command -v fuse-overlayfs >/dev/null 2>&1 || ! command -v nft >/dev/null 2>&1; then
            apt-get update -qq >/dev/null 2>&1 || true
        fi
        if ! command -v fuse-overlayfs >/dev/null 2>&1; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq fuse-overlayfs 2>&1 | tail -1
        fi
        if ! command -v nft >/dev/null 2>&1; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nftables 2>&1 | tail -1
        fi

        mkdir -p /root/.config/containers
        cat > /root/.config/containers/storage.conf <<'STORAGE'
[storage]
driver = "overlay"

[storage.options.overlay]
mount_program = "/usr/bin/fuse-overlayfs"
STORAGE

        mkdir -p "$PIXI_PREFIX/etc/containers"
        cat > "$PIXI_PREFIX/etc/containers/containers.conf" <<'CONF'
[engine]
network_backend = "netavark"

[network]
network_backend = "netavark"
CONF
    else
        echo "Detected native filesystem — configuring podman for real VM"
        mkdir -p /root/.config/containers
        cat > /root/.config/containers/storage.conf <<'STORAGE'
[storage]
driver = "overlay"
STORAGE

        mkdir -p "$PIXI_PREFIX/etc/containers"
        cat > "$PIXI_PREFIX/etc/containers/containers.conf" <<'CONF'
[engine]
network_backend = "netavark"

[network]
network_backend = "netavark"
CONF
    fi

    nft delete table inet netavark 2>/dev/null || true
}

_configure_podman

# --- Image Loading ---
if [ -n "${image:-}" ] && [ -f "$image" ]; then
    if $PODMAN image inspect "$CONTAINER_IMAGE" >/dev/null 2>&1; then
        echo "Image already loaded: $CONTAINER_IMAGE"
    else
        echo "Loading pre-cached image from: $image"
        case "$image" in
            *.tar.zst|*.zst)
                TMP_TAR="$(mktemp --suffix=.tar)"
                zstd -d "$image" -o "$TMP_TAR" -f
                $PODMAN load -i "$TMP_TAR"
                rm -f "$TMP_TAR"
                ;;
            *)
                $PODMAN load -i "$image"
                ;;
        esac
        LOADED_IMAGE=$($PODMAN images --format '{{.Repository}}:{{.Tag}}' | grep -v "<none>" | head -1)
        echo "Loaded image: $LOADED_IMAGE"
        CONTAINER_IMAGE="$LOADED_IMAGE"
    fi
elif [ -n "${image:-}" ]; then
    echo "WARNING: image path set but file not found: $image"
    echo "Falling back to pull from Docker Hub..."
    $PODMAN pull "$CONTAINER_IMAGE"
else
    echo "No pre-cached image. Pulling from Docker Hub..."
    $PODMAN pull "$CONTAINER_IMAGE"
fi

echo "Starting rstudio on port $PORT ..."

# --- Snapshot on Stop ---
_snapshot_cleanup() {
    local exit_code=$?
    if [ "${snapshot:-false}" = "true" ] || [ "${snapshot:-false}" = "True" ]; then
        echo "Snapshot enabled. Saving container state as zstd..."
        SNAPSHOT_DIR="$HOME/rstudio-snapshots"
        mkdir -p "$SNAPSHOT_DIR"
        TIMESTAMP=$(date +%Y%m%d%H%M%S)
        SNAPSHOT_TAG="rstudio-snapshot:${TIMESTAMP}"
        SNAPSHOT_ZSTD="$SNAPSHOT_DIR/rstudio-${job_id:-unknown}-${TIMESTAMP}.tar.zst"

        $PODMAN commit "$CONTAINER_NAME" "$SNAPSHOT_TAG" 2>/dev/null || true
        echo "Saving snapshot to: $SNAPSHOT_ZSTD"
        $PODMAN save "$SNAPSHOT_TAG" 2>/dev/null | zstd -T0 -o "$SNAPSHOT_ZSTD" 2>/dev/null || true

        if [ -n "${outdir:-}" ]; then
            S3_UPLOAD_PATH="${outdir}/${job_id:-unknown}/"
            echo "Uploading snapshot to: $S3_UPLOAD_PATH"
            if command -v aws &>/dev/null; then
                aws s3 cp "$SNAPSHOT_ZSTD" "$S3_UPLOAD_PATH" \
                    --endpoint-url "${AWS_ENDPOINT_URL:-}" 2>/dev/null || true
            fi
        fi
        rm -f "$SNAPSHOT_ZSTD"
        echo "Snapshot complete."
    fi
    return $exit_code
}
trap _snapshot_cleanup EXIT

# --- Run RStudio Server ---

# Clean up stale containers and orphaned processes on port.
$PODMAN rm -f "$CONTAINER_NAME" 2>/dev/null || true
_stale_pids=$(lsof -t -i:"$PORT" 2>/dev/null || true)
if [ -n "$_stale_pids" ]; then
    echo "Killing stale processes on port $PORT: $_stale_pids"
    kill -9 $_stale_pids 2>/dev/null || true
    sleep 1
fi

# Run rserver directly with flags instead of relying on s6-overlay.
# --www-root-path=/ : tells RStudio it's served at the root (needed behind reverse proxy)
# --auth-none=1     : disables authentication
# --network host    : required for port forwarding inside Docker-in-Docker
# Foreground mode (--rm -i, no -d): script blocks so the platform knows the job is active.
$PODMAN run --rm -i \
    --name "$CONTAINER_NAME" \
    --network host \
    "$CONTAINER_IMAGE" \
    bash -c "exec rserver \
        --www-address=0.0.0.0 \
        --www-port=${PORT} \
        --www-root-path=/ \
        --auth-none=1 \
        --server-daemonize=0"
