#!/usr/bin/env bash
# reference: https://github.com/GlueOps/scripts-teardown-aws-amazon-web-services
set -euo pipefail

AWS_NUKE_VERSION="${AWS_NUKE_VERSION:-v3.61.0}"
MAX_WAIT_RETRIES="${MAX_WAIT_RETRIES:-200}"
DRY_RUN="${DRY_RUN:-false}"
NO_ALIAS_CHECK="${NO_ALIAS_CHECK:-true}"
LOG_LEVEL="${LOG_LEVEL:-}"
# Absolute: this runs from ${{ github.workspace }}, not the action directory, so
# a relative "nuke.yaml" would silently miss the allowlist that keeps the blast
# radius to the resource types this module provisions.
NUKE_CONFIG="${NUKE_CONFIG:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/nuke.yaml}"

if [ ! -f "$NUKE_CONFIG" ]; then
  echo "::error::aws-nuke config not found: $NUKE_CONFIG" >&2
  exit 1
fi

# Only export when non-empty: an empty AWS_ACCESS_KEY_ID is not "unset" to the
# AWS SDK, it is a bad credential, and it would shadow a job that authenticated
# via OIDC or aws-actions/configure-aws-credentials.
if [ -n "${INPUT_AWS_ACCESS_KEY_ID:-}" ]; then
  export AWS_ACCESS_KEY_ID="$INPUT_AWS_ACCESS_KEY_ID"
  export AWS_SECRET_ACCESS_KEY="${INPUT_AWS_SECRET_ACCESS_KEY:?aws-secret-access-key is required when aws-access-key-id is set}"
fi
if [ -n "${INPUT_AWS_REGION:-}" ]; then
  export AWS_REGION="$INPUT_AWS_REGION"
  export AWS_DEFAULT_REGION="$INPUT_AWS_REGION"
fi

case "$(uname -m)" in
  x86_64) arch=amd64 ;;
  aarch64 | arm64) arch=arm64 ;;
  *) echo "::error::unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

# Download into a scratch dir so the binary never lands in the caller's checkout.
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

tarball="aws-nuke-${AWS_NUKE_VERSION}-linux-${arch}.tar.gz"
release_url="https://github.com/ekristen/aws-nuke/releases/download/${AWS_NUKE_VERSION}"

echo "Downloading aws-nuke ${AWS_NUKE_VERSION} (linux/${arch})"
# -f so a 404 on a bad version tag fails here instead of untarring an error page.
curl -fsSL --retry 3 --retry-delay 5 -o "$workdir/$tarball" "${release_url}/${tarball}"

# Verify before extracting. This binary is executed with account-wide delete
# credentials, so running it unverified means whatever the network hands back gets
# those credentials.
#
# Two layers, because they defend against different things:
#   1. The release's own checksums.txt catches corruption and a tampered *download*.
#      It does NOT help if the release itself were replaced -- same origin, same trust.
#   2. EXPECTED_SHA256 below is committed to this repo, so a replaced release is
#      caught too. It only covers the pinned default version.
# Both run when they can, and a mismatch in either is fatal.
case "${AWS_NUKE_VERSION}-${arch}" in
  # Pinned digests for the default version. Update these together with the
  # AWS_NUKE_VERSION default above; `curl -fsSL <release_url>/checksums.txt` prints them.
  v3.61.0-amd64) EXPECTED_SHA256="27d06905cc2168f203d956e33cbcc901dc6fce4ab49fd6c1365d30e5b297ddfc" ;;
  v3.61.0-arm64) EXPECTED_SHA256="0e82a582cbd43d26d80a83bb28d472df2c99a6c8a2b3640ee81cd2a29c4418f7" ;;
  *) EXPECTED_SHA256="${AWS_NUKE_SHA256:-}" ;;
esac

echo "Verifying ${tarball} against the release checksums..."
curl -fsSL --retry 3 --retry-delay 5 -o "$workdir/checksums.txt" "${release_url}/checksums.txt"
# --ignore-missing: checksums.txt lists every platform's artifact, and we only
# downloaded one. Without it sha256sum fails on the absent files.
( cd "$workdir" && sha256sum --ignore-missing -c checksums.txt ) || {
  echo "::error::aws-nuke ${AWS_NUKE_VERSION} failed checksum verification against the release checksums.txt" >&2
  exit 1
}

if [ -n "$EXPECTED_SHA256" ]; then
  actual="$(sha256sum "$workdir/$tarball" | cut -d' ' -f1)"
  if [ "$actual" != "$EXPECTED_SHA256" ]; then
    echo "::error::aws-nuke ${AWS_NUKE_VERSION} (linux/${arch}) does not match the digest pinned in this repo." >&2
    echo "  expected: ${EXPECTED_SHA256}" >&2
    echo "  actual:   ${actual}" >&2
    echo "The published release changed under a fixed version tag. Do NOT bypass this:" >&2
    echo "verify the release is legitimate before updating the pin." >&2
    exit 1
  fi
  echo "Digest matches the pin committed to this repo."
else
  # Not fatal -- checksums.txt verification above still ran -- but say so plainly.
  echo "::warning::No repo-pinned digest for aws-nuke ${AWS_NUKE_VERSION} (linux/${arch});" \
       "verified against the release's own checksums.txt only. Set AWS_NUKE_SHA256 to pin it."
fi

tar -xzf "$workdir/$tarball" -C "$workdir" aws-nuke
chmod +x "$workdir/aws-nuke"

args=(
  nuke
  -c "$NUKE_CONFIG"
  --max-wait-retries "$MAX_WAIT_RETRIES"
  --log-full-timestamp true
)
# --no-alias-check skips the "account has no alias" safety guard; the account
# must also be listed under bypass-alias-check-accounts in nuke.yaml.
if [ "$NO_ALIAS_CHECK" = "true" ]; then
  args+=(--no-alias-check)
fi
if [ -n "$LOG_LEVEL" ]; then
  args+=(--log-level "$LOG_LEVEL")
fi
# `if` blocks rather than `[ x ] && args+=(...)`: a trailing false test would
# exit 1 under `set -e`.
if [ "$DRY_RUN" = "true" ]; then
  echo "DRY RUN: aws-nuke will list matching resources without deleting them"
else
  echo "Performing an AWS cleanup with aws-nuke (config: $NUKE_CONFIG)"
  args+=(--no-dry-run --force)
fi

"$workdir/aws-nuke" "${args[@]}"
