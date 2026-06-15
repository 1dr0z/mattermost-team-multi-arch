set shell := ["bash", "-euo", "pipefail", "-c"]

registry := env("REGISTRY", "localhost:5000")
server_image := env("SERVER_IMAGE", "mattermost-team")
mmctl_image := env("MMCTL_IMAGE", "mattermost-mmctl")
server_repo := registry + "/" + lowercase(server_image)
mmctl_repo := registry + "/" + lowercase(mmctl_image)

# Local registries speak plain HTTP, so flip TLS verification off automatically.
is_local_registry := if registry =~ '^(localhost|127\.0\.0\.1)' { "true" } else { "false" }
registry_tls := if is_local_registry == "true" { "--tls-verify=false" } else { "" }

# local host architecture
local_arch := if arch() == "aarch64" { "arm64" } else if arch() == "x86_64" { "amd64" } else { arch() }

semver_re := '^[0-9]+\.[0-9]+\.[0-9]+$'

_default:
    @just --list

# Authenticate to the registry.
login:
    #!/usr/bin/env bash
    set -euo pipefail

    if [[ "{{ is_local_registry }}" == "true" ]]; then
        echo "Local registry does not support login" >&2
        exit 0
    fi

    : "${REGISTRY_USER:?set REGISTRY_USER}"
    : "${REGISTRY_TOKEN:?set REGISTRY_TOKEN}"
    echo "$REGISTRY_TOKEN" | podman login "{{ registry }}" -u "$REGISTRY_USER" --password-stdin

# Run a local container registry
local-registry-up:
    podman run -d --replace --name mattermost-registry -p 5000:5000 docker.io/library/registry:2

local-registry-down:
    -podman rm -f mm-registry

# Fetch and patch the upstream Dockerfile
patch version:
    #!/usr/bin/env bash
    set -euo pipefail

    url="https://raw.githubusercontent.com/mattermost/mattermost/refs/tags/v{{ version }}/server/build/Dockerfile"
    curl -fsSL "$url" -o mattermost/Containerfile.upstream
    patch --fuzz 0 -o mattermost/Containerfile.patched \
        mattermost/Containerfile.upstream < mattermost/multi-arch.patch

_server_tag version arch=local_arch:
    @echo "{{ server_repo }}:{{ version }}-{{ arch }}"

_mmctl_tag version arch=local_arch:
    @echo "{{ mmctl_repo }}:{{ version }}-{{ arch }}"

_build-server version target_arch=local_arch:
    #!/usr/bin/env bash
    set -euo pipefail

    pkg="https://releases.mattermost.com/{{ version }}/mattermost-team-{{ version }}-linux-{{ target_arch }}.tar.gz"
    tag=`just _server_tag {{ version }} {{ target_arch }}`
    podman build \
        --platform "linux/{{ target_arch }}" \
        --format docker \
        --build-arg MM_PACKAGE="$pkg" \
        --tag "$tag" \
        --file mattermost/Containerfile.patched \
        mattermost

_build-mmctl version target_arch=local_arch: (_build-server version target_arch)
    #!/usr/bin/env bash
    set -euo pipefail

    server_tag=`just _server_tag {{ version }} {{ target_arch }}`
    mmctl_tag=`just _mmctl_tag {{ version }} {{ target_arch }}`
    podman build \
        --platform "linux/{{ target_arch }}" \
        --format docker \
        --build-arg SERVER_IMAGE="$server_tag" \
        --tag "$mmctl_tag" \
        --file mmctl/Containerfile \
        mmctl

# build mattermost and mmctl images
build version target_arch=local_arch: (_build-server version target_arch) (_build-mmctl version target_arch)

# Export server + mmctl images
export-images version arch dir="dist/images":
    #!/usr/bin/env bash
    set -euo pipefail

    server_tag=`just _server_tag {{ version }} {{ arch }}`
    mmctl_tag=`just _mmctl_tag {{ version }} {{ arch }}`

    mkdir -p "{{ dir }}"
    podman save -o "{{ dir }}/server-{{ version }}-{{ arch }}.tar" "$server_tag"
    podman save -o "{{ dir }}/mmctl-{{ version }}-{{ arch }}.tar" "$mmctl_tag"

# Load image archives found under <dir> into local storage
import-images dir="dist/images":
    #!/usr/bin/env bash
    set -euo pipefail
    shopt -s nullglob

    for f in "{{ dir }}"/*.tar; do
        podman load -i "$f"
    done

# Push the images for version + arch to registry.
push version arch:
    #!/usr/bin/env bash
    set -euo pipefail
    podman push {{ registry_tls }} `just _server_tag {{ version }} {{ arch }}`
    podman push {{ registry_tls }} `just _mmctl_tag {{ version }} {{ arch }}`

[no-exit-message]
mattermost-versions:
    @git ls-remote --tags --refs https://github.com/mattermost/mattermost.git \
          | awk '{print $2}' \
          | sed 's|refs/tags/v||' \
          | grep -E "{{ semver_re }}" \
          | sort -V

# List versions that have already been built and published
[no-exit-message]
published-versions registry=server_repo:
    @skopeo list-tags {{ registry_tls }} "docker://{{ registry }}" 2>/dev/null \
      | jq -r '.Tags[]' \
      | grep -E "{{ semver_re }}" \
      | sort -V

# Decide which versions to build based on upstream tags and published image versions
missing-versions:
    #!/usr/bin/env bash
    set -euo pipefail

    # return versions >= floor (input assumed semver-clean)
    ge_floor() {
        local re; re=$(sed 's/[.]/\\./g' <<<"$1")
        { cat; echo "$1"; } | sort -V -u | sed -n "/^${re}\$/,\$p"
    }

    # return all versions contained in both sets
    set_intersection() { comm -12 <(sort <<<"$1") <(sort <<<"$2"); }

    # return versions in the first set that are not in the second set
    set_difference()  { comm -23 <(sort <<<"$1") <(sort <<<"$2"); }

    upstream_tags=$(just mattermost-versions)
    server_tags=$(just published-versions "{{ server_repo }}" || true)
    mmctl_tags=$(just published-versions "{{ mmctl_repo }}" || true)

    # floor = lowest published version.
    floor=$(head -n1 <<<"$server_tags")
    if [[ -z "$floor" ]]; then
        echo "No published versions" >&2
        exit 0
    fi

    at_or_above=$(ge_floor "$floor" <<<"$upstream_tags")
    published_versions=$(set_intersection "$server_tags" "$mmctl_tags")
    missing_versions=$(set_difference "$at_or_above" "$published_versions")

    if [[ -n "$missing_versions" ]]; then
        printf '%s\n' "$missing_versions" | sort -V
        exit 0
    fi

# Assemble one repo's amd64 + arm64 tags into a multi-arch manifest and push it.
assemble-manifest repo version:
    #!/usr/bin/env bash
    set -euo pipefail
    list="{{ repo }}:{{ version }}"
    podman manifest rm "$list" 2>/dev/null || true
    podman manifest create "$list"
    podman manifest add "$list" "containers-storage:{{ repo }}:{{ version }}-amd64"
    podman manifest add "$list" "containers-storage:{{ repo }}:{{ version }}-arm64"

# Assemble the multi-arch manifests for version
assemble version: (assemble-manifest server_repo version) (assemble-manifest mmctl_repo version)

# Push merged manifest to the registry
push-manifest repo version:
    #!/usr/bin/env bash
    set -euo pipefail

    image="{{ repo }}:{{ version }}"
    podman manifest push --all {{ registry_tls }} "$image" "docker://$image"

# Publish the merged images
publish-manifests version:
    #!/usr/bin/env bash
    set -euo pipefail

    just push-manifest {{ server_repo }} {{ version }}
    just push-manifest {{ mmctl_repo }} {{ version }}

# Ensure a release version is valid
verify-manifests version:
    #!/usr/bin/env bash
    set -euo pipefail

    check() {
        local repo=$1 raw arches
        raw=$(podman manifest inspect "${repo}:{{ version }}") \
            || { echo "no manifest for ${repo}:{{ version }}" >&2; return 1; }

        arches=$(jq -r '.manifests[].platform.architecture' <<<"$raw" | sort -u | paste -sd, -)
        [[ "$arches" == "amd64,arm64" ]] \
            || { echo "${repo}:{{ version }} arches = ${arches:-none}" >&2; return 1; }
    }

    check "{{ server_repo }}"
    check "{{ mmctl_repo }}"

# Tag and push a release candidate
release-rc version:
    git tag "v{{ version }}-rc"
    git push --force origin "v{{ version }}-rc"

# Tag and push a release version
release version: (verify-manifests version)
    #!/usr/bin/env bash
    set -euo pipefail

    tag="v{{ version }}"
    rc_tag="v{{ version }}-rc"

    # create release tag
    git tag -a "$tag" -m "mattermost {{ version }}" "$rc_tag"
    git push origin "$tag"

    # delete release candidate tag
    git tag -d "$rc_tag"
    git push origin ":${rc_tag}"

actions *ARGS:
    act schedule \
      --container-architecture linux/amd64 \
      --container-daemon-socket - \
      -P ubuntu-24.04=catthehacker/ubuntu:act-24.04 \
      -P ubuntu-24.04-arm=catthehacker/ubuntu:act-24.04 \
      {{ ARGS }}
