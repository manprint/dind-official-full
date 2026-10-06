set positional-arguments := true
set dotenv-load := true
set shell := ["bash", "-c"]

# Image names as the release workflow builds them: ghcr.io/<github.repository,
# lowercased>, with -minimal appended for the minimal variant. The repository
# comes from the origin remote; IMAGE_REPO overrides it (e.g. for a fork).

registry := "ghcr.io"
repo := env("IMAGE_REPO", `git remote get-url origin 2>/dev/null | sed -E 's/\.git$//; s#.*[:/]([^/:]+/[^/]+)$#\1#' | tr '[:upper:]' '[:lower:]'`)
image_full := registry / repo
image_minimal := registry / repo + "-minimal"

# Same default as the Dockerfiles; CI pins the version it resolved once.

rclone := env("DIND_RCLONE_VERSION", "current")

# List all tasks
_default:
    @just --list

# Build both images
build tag="latest": (build-full tag) (build-minimal tag)

# Build the full image (Dockerfile): the CI build job, for this host's platform
build-full tag="latest": (_build "Dockerfile" image_full tag "")

# Build the minimal image (Dockerfile.minimal)
build-minimal tag="latest": (_build "Dockerfile.minimal" image_minimal tag "")

# Build both images from scratch, like a release does (no layer cache)
build-clean tag="latest": (build-full-clean tag) (build-minimal-clean tag)

# Same, full image only
build-full-clean tag="latest": (_build "Dockerfile" image_full tag "--no-cache")

# Same, minimal image only
build-minimal-clean tag="latest": (_build "Dockerfile.minimal" image_minimal tag "--no-cache")

# --pull as in CI: the pinned base image is refreshed, not taken from the cache
_build dockerfile image tag flags:
    docker build --pull {{ flags }} -f {{ dockerfile }} \
        --build-arg DIND_RCLONE_VERSION={{ rclone }} \
        -t {{ image }}:{{ tag }} .

# Smoke-test the full image (needs --privileged)
smoke-full tag="latest" cycles="3":
    tests/smoke.sh {{ image_full }}:{{ tag }} {{ cycles }}

# Smoke-test the minimal image (needs --privileged)
smoke-minimal tag="latest" cycles="3":
    tests/smoke.sh {{ image_minimal }}:{{ tag }} {{ cycles }}

# Print the image names the build recipes use
names:
    @echo "full:    {{ image_full }}"
    @echo "minimal: {{ image_minimal }}"
