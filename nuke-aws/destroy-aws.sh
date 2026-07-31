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
echo "Downloading aws-nuke ${AWS_NUKE_VERSION} (linux/${arch})"
# -f so a 404 on a bad version tag fails here instead of untarring an error page.
curl -fsSL --retry 3 --retry-delay 5 -o "$workdir/$tarball" \
  "https://github.com/ekristen/aws-nuke/releases/download/${AWS_NUKE_VERSION}/${tarball}"
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
