#!/bin/bash
set -euo pipefail

R_VERSION="${r_version:-4.4.2}"
DOCKER_IMAGE="docker.io/rocker/rstudio:${R_VERSION}"
CONTAINER_NAME="rstudio-server"
PORT="${PORT:-6868}"

TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RSTUDIO_WORKSPACE="$HOME/rstudio-workspace"
mkdir -p "$RSTUDIO_WORKSPACE"

# --- Podman configuration ---
# Podman >=5 (installed via pixi) auto-detects the netavark network backend and
# the overlay storage driver, and needs no custom config. The default rootful
# graphroot (/var/lib/containers/storage) is exactly where the Docker simulation
# bind-mounts its host-backed storage, so this works unchanged on both the VM
# and the nested-container simulation.
#
# Netavark (podman >=5's network backend) requires a firewall backend (nftables
# or iptables) to program port-mapping rules. The base image does not ship one,
# so install it at runtime when missing. (Note: `passt` only helps *rootless*
# podman via the pasta driver, not this rootful setup, so it is not used here.)

if ! command -v nft >/dev/null 2>&1 && ! command -v iptables >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update >/dev/null 2>&1 || true
        apt-get install -y nftables iptables >/dev/null 2>&1 || true
    fi
fi

# Clean up stale CNI bridge left by older podman versions.  If this DOWN
# interface still has a route for 10.88.0.0/16, netavark packets silently
# go to the dead link instead of the live podman0 bridge.
ip link del cni-podman0 2>/dev/null || true

# Diagnostic: confirm podman auto-config (netavark + overlay).
echo "--- podman effective config ---"
podman info 2>&1 | grep -iE "networkBackend|graphDriverName" || true

# Ensure an insecureAcceptAnything policy so the pre-cached image can be loaded.
POLICY_FILE="${HOME}/.config/containers/policy.json"
if [ ! -f "$POLICY_FILE" ]; then
    mkdir -p "$(dirname "$POLICY_FILE")"
    echo '{"default":[{"type":"insecureAcceptAnything"}]}' > "$POLICY_FILE"
fi
mkdir -p "${HOME}/.local/share/containers"

echo "Using podman: $(which podman)"

# --- Image Loading ---
if [ -n "${image:-}" ] && [ -f "$image" ]; then
    # Skip loading if image is already in local storage
    if podman image exists "$DOCKER_IMAGE" 2>/dev/null; then
        echo "Image already loaded: $DOCKER_IMAGE"
    else
        echo "Loading pre-cached image from: $image"
        case "$image" in
            *.tar.zst|*.zst)
                zstd -d "$image" --stdout | podman load
                ;;
            *)
                podman load -i "$image"
                ;;
        esac
        LOADED_IMAGE=$(podman images --format '{{.Repository}}:{{.Tag}}' | grep -v "<none>" | head -1)
        echo "Loaded image: $LOADED_IMAGE"
        DOCKER_IMAGE="$LOADED_IMAGE"
    fi
elif [ -n "${image:-}" ]; then
    echo "WARNING: image path set but file not found: $image"
    echo "Falling back to Docker Hub pull..."
    podman pull "$DOCKER_IMAGE"
else
    echo "No pre-cached image. Pulling from Docker Hub..."
    podman pull "$DOCKER_IMAGE"
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

        # Commit the running container to a new image
        podman commit "$CONTAINER_NAME" "$SNAPSHOT_TAG" 2>/dev/null || true

        # Save the committed snapshot with zstd compression
        echo "Saving snapshot to: $SNAPSHOT_ZSTD"
        podman save "$SNAPSHOT_TAG" 2>/dev/null | zstd -T0 -o "$SNAPSHOT_ZSTD" 2>/dev/null || true

        # Upload to S3 if outdir is set
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
CONTAINER_R_LIBS="/home/rstudio/R/library"
CONTAINER_PY_SITE="/home/rstudio/.local/lib/python3.12/site-packages"

# Remove any existing container with the same name before starting.
podman rm -f "$CONTAINER_NAME" 2>/dev/null || true

# Clean up ALL stale podman containers left from previous jobs to free
# port mappings and avoid stale netavark DNAT rules.
podman rm -f -a 2>/dev/null || true

# Mount only the workspace (rw) and the job data directory (ro, contains
# mount-s3 data).  Do NOT mount $HOME or /tmp which may contain IAM
# credentials or other sensitive files.
JOB_DIR="$HOME/sdk/jobs/${job_id:-.}"

podman run --rm -i \
    --name "$CONTAINER_NAME" \
    -p "$PORT:8787" \
    -v "$RSTUDIO_WORKSPACE:/home/rstudio/rstudio-workspace" \
    -v "$JOB_DIR:/home/rstudio/job:ro" \
    -e DISABLE_AUTH=true \
    $DOCKER_IMAGE