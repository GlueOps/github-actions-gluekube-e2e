#!/usr/bin/env bash
#
# Check that the cluster created by `tofu apply` + the AutoGlue setup action is healthy.
#
# This script is only the *transport*. It resolves the org, picks a bastion and a
# master, reveals both servers' ssh private keys, then hops through the bastion and
# runs cluster_health.py on the master under the kubeadm admin kubeconfig. Every
# assertion lives in that Python file -- see its docstring for the health model.
#
# The script is piped to `sudo python3 -` rather than interpolated into a shell
# string. The previous version embedded the whole check inside `sudo bash -c '...'`,
# which meant the check could not contain a single quote anywhere and any escaping
# mistake became a confusing remote failure.
#
# Exits 0 if every assertion holds within the deadline, 1 otherwise.
# Requires `curl`, `jq` and `ssh` locally, and `python3` on the master.
#
# Required environment variables:
#   BASE_URL   AutoGlue API base url
#   API_KEY    AutoGlue API key   (sent as X-API-KEY header)
#   ORG_NAME   AutoGlue org name  (resolved to org id via the /orgs endpoint)
#
# Optional:
#   CLUSTER_NAME          restrict server lookup to this cluster (see "Isolation")
#   HEALTH_TIMEOUT        overall deadline in seconds        (default 900)
#   HEALTH_POLL_INTERVAL  seconds between polls              (default 15)
#   MIN_NODE_COUNT        floor on Ready nodes, optional     (unset = no floor)
#   MAX_RESTART_COUNT     per-container restart ceiling      (default 3)
#
# Isolation -- the worst bug this checker can have
#   The failure mode that matters is a false PASS, not a false failure. If teardown
#   failed on a previous run and its cluster is still up, an unfiltered server lookup
#   can SSH into that healthy old cluster, pass every assertion, and report green for
#   a cluster nobody tested. A test that can validate the wrong cluster is worse than
#   no test, because it is trusted.
#
#   Two defences, in order of importance:
#     1. Each test line has its own dedicated AutoGlue org, and the workflow runs the
#        org nuke as a PRE-FLIGHT as well as at teardown. That makes the clean slate
#        unconditional instead of depending on the previous run exiting cleanly.
#        This is the primary guarantee.
#     2. CLUSTER_NAME, below, filters the server lookup to this run's cluster as a
#        second line of defence if the pre-flight nuke ever fails.
set -euo pipefail

: "${BASE_URL:?BASE_URL is required}"
: "${API_KEY:?API_KEY is required}"
: "${ORG_NAME:?ORG_NAME is required}"

CLUSTER_NAME="${CLUSTER_NAME:-}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-900}"
HEALTH_POLL_INTERVAL="${HEALTH_POLL_INTERVAL:-15}"
MAX_RESTART_COUNT="${MAX_RESTART_COUNT:-3}"
MIN_NODE_COUNT="${MIN_NODE_COUNT:-}"

# These are passed to the remote interpreter's environment, so reject anything that
# is not a plain integer rather than shipping it to the master. MIN_NODE_COUNT is
# allowed to be empty, which means "no floor".
for var in HEALTH_TIMEOUT HEALTH_POLL_INTERVAL MAX_RESTART_COUNT; do
  case "${!var}" in
    "" | *[!0-9]*)
      echo "ERROR: ${var} must be a non-negative integer, got: ${!var}" >&2
      exit 1
      ;;
  esac
done
case "$MIN_NODE_COUNT" in
  "") ;;
  *[!0-9]*)
    echo "ERROR: MIN_NODE_COUNT must be a non-negative integer or empty, got: ${MIN_NODE_COUNT}" >&2
    exit 1
    ;;
esac

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REMOTE_SCRIPT="${SCRIPT_DIR}/cluster_health.py"
if [ ! -f "$REMOTE_SCRIPT" ]; then
  echo "ERROR: cluster_health.py not found next to this script (${REMOTE_SCRIPT})" >&2
  exit 1
fi

echo "==> Step 1: Getting org_id for org '${ORG_NAME}'..."
ORGS=$(curl -sfS --http1.1 -X GET "${BASE_URL}/orgs" \
  -H "accept: application/json" \
  -H "X-API-KEY: ${API_KEY}")

ORG_ID=$(echo "$ORGS" | jq -r --arg name "$ORG_NAME" \
  '.[] | select(.name == $name) | .id')

if [ -z "$ORG_ID" ] || [ "$ORG_ID" = "null" ]; then
  echo "ERROR: Org '${ORG_NAME}' not found"
  exit 1
fi
echo "Found org_id: ${ORG_ID}"

# Resolve this run's cluster id when CLUSTER_NAME is supplied, so the server lookup
# below can be filtered to it.
CLUSTER_ID=""
if [ -n "$CLUSTER_NAME" ]; then
  echo "==> Step 1b: Getting cluster_id for cluster '${CLUSTER_NAME}'..."
  CLUSTERS=$(curl -sfS --http1.1 -G "${BASE_URL}/clusters" \
    --data-urlencode "q=${CLUSTER_NAME}" \
    -H "accept: application/json" \
    -H "X-API-KEY: ${API_KEY}" \
    -H "x-org-id: ${ORG_ID}")

  CLUSTER_ID=$(echo "$CLUSTERS" | jq -r --arg n "$CLUSTER_NAME" \
    'map(select(.name == $n)) | .[0].id // empty')
  if [ -z "$CLUSTER_ID" ]; then
    echo "ERROR: cluster '${CLUSTER_NAME}' not found in org '${ORG_NAME}'." >&2
    echo "The apply step should have created it. Refusing to fall back to an" >&2
    echo "unfiltered server lookup, which could select a previous run's cluster." >&2
    exit 1
  fi
  echo "Found cluster_id: ${CLUSTER_ID}"
else
  echo "WARNING: CLUSTER_NAME is not set, so servers cannot be filtered to this run's"
  echo "WARNING: cluster. The pre-flight org nuke is then the ONLY thing standing"
  echo "WARNING: between this check and a leftover cluster from a previous run."
fi

# Fetch a server with the given role, restricted to this run's cluster when we know
# its id. Echoes the server object.
get_server() {
  local role="$1"
  local servers count filtered
  servers=$(curl -sfS --http1.1 -G "${BASE_URL}/servers" \
    --data-urlencode "role=${role}" \
    -H "accept: application/json" \
    -H "X-API-KEY: ${API_KEY}" \
    -H "x-org-id: ${ORG_ID}")

  count=$(echo "$servers" | jq -r 'length')
  filtered="$servers"

  if [ -n "$CLUSTER_ID" ]; then
    # Only filter when the records actually carry a cluster id. If the API does not
    # expose one on /servers, say so loudly rather than silently filtering to
    # nothing (which would look like "no servers" and mask the real situation).
    if [ "$(echo "$servers" | jq -r '[.[] | select(has("cluster_id"))] | length')" -gt 0 ]; then
      filtered=$(echo "$servers" | jq --arg cid "$CLUSTER_ID" 'map(select(.cluster_id == $cid))')
      local kept
      kept=$(echo "$filtered" | jq -r 'length')
      echo "  ${role}: ${count} in org, ${kept} in cluster ${CLUSTER_ID}" >&2
    else
      echo "  WARNING: /servers records carry no cluster_id, so the ${role} lookup" >&2
      echo "  WARNING: cannot be filtered to this run's cluster. Relying on the" >&2
      echo "  WARNING: pre-flight org nuke for isolation." >&2
    fi
  fi

  # More than one bastion in a dedicated, pre-nuked org means leftovers survived.
  # Warn rather than fail: several masters is normal, and the operator needs to see
  # the count either way.
  local n
  n=$(echo "$filtered" | jq -r 'length')
  if [ "$role" = "bastion" ] && [ "$n" -gt 1 ]; then
    echo "  WARNING: ${n} bastion servers matched. In a dedicated org that should be 1;" >&2
    echo "  WARNING: leftovers from a previous run may still exist." >&2
  fi

  local server
  server=$(echo "$filtered" | jq -r '.[0] // empty')
  if [ -z "$server" ]; then
    echo "ERROR: no ${role} servers returned by ${BASE_URL}/servers?role=${role}" >&2
    return 1
  fi
  echo "$server"
}

# Reveal a server's ssh private key and write it to $2. Args: ssh_key_id, out_file.
fetch_private_key() {
  local key_id="$1" out_file="$2"
  local key
  key=$(curl -sfS --http1.1 -G "${BASE_URL}/ssh/${key_id}" \
    --data-urlencode "reveal=true" \
    -H "accept: application/json" \
    -H "X-API-KEY: ${API_KEY}" \
    -H "x-org-id: ${ORG_ID}")

  chmod 600 "$out_file"
  echo "$key" | jq -r '.private_key // empty' > "$out_file"

  if [ ! -s "$out_file" ]; then
    echo "ERROR: ssh key ${key_id} returned an empty private_key" >&2
    return 1
  fi
  # Guard against a key stored without its trailing newline; ssh rejects those.
  [ -n "$(tail -c1 "$out_file")" ] && echo >> "$out_file"
  return 0
}

echo "==> Step 2: Getting the bastion and a master server..."
BASTION=$(get_server bastion)
MASTER=$(get_server master)

BASTION_IP=$(echo "$BASTION" | jq -r '.public_ip_address')
BASTION_USER=$(echo "$BASTION" | jq -r '.ssh_user')
BASTION_KEY_ID=$(echo "$BASTION" | jq -r '.ssh_key_id')

MASTER_IP=$(echo "$MASTER" | jq -r '.private_ip_address')
MASTER_USER=$(echo "$MASTER" | jq -r '.ssh_user')
MASTER_KEY_ID=$(echo "$MASTER" | jq -r '.ssh_key_id')
MASTER_HOST=$(echo "$MASTER" | jq -r '.hostname')

if [ -z "$BASTION_IP" ] || [ "$BASTION_IP" = "null" ]; then
  echo "ERROR: bastion has no public_ip_address"
  exit 1
fi
if [ -z "$MASTER_IP" ] || [ "$MASTER_IP" = "null" ]; then
  echo "ERROR: master '${MASTER_HOST}' has no private_ip_address"
  exit 1
fi
for id in "$BASTION_KEY_ID" "$MASTER_KEY_ID"; do
  if [ -z "$id" ] || [ "$id" = "null" ]; then
    echo "ERROR: bastion or master server record has no ssh_key_id"
    exit 1
  fi
done
echo "Bastion ${BASTION_USER}@${BASTION_IP} -> master ${MASTER_HOST} (${MASTER_USER}@${MASTER_IP})"

echo "==> Step 3: Revealing the bastion and master private keys..."
BASTION_KEY_FILE=$(mktemp)
MASTER_KEY_FILE=$(mktemp)
trap 'rm -f "$BASTION_KEY_FILE" "$MASTER_KEY_FILE"' EXIT
fetch_private_key "$BASTION_KEY_ID" "$BASTION_KEY_FILE"
fetch_private_key "$MASTER_KEY_ID" "$MASTER_KEY_FILE"

SSH_OPTS=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=30
  # The remote side polls for up to HEALTH_TIMEOUT with no output between rounds;
  # keepalives stop a NAT/firewall from dropping an idle session.
  -o ServerAliveInterval=30
  -o ServerAliveCountMax=10
)
# ProxyCommand tunnels through the bastion with the bastion's own key, so the master
# key never has to be copied onto the bastion.
SSH_TO_MASTER=(
  ssh -i "$MASTER_KEY_FILE"
  "${SSH_OPTS[@]}"
  -o ProxyCommand="ssh -i ${BASTION_KEY_FILE} ${SSH_OPTS[*]} -W %h:%p ${BASTION_USER}@${BASTION_IP}"
  "${MASTER_USER}@${MASTER_IP}"
)

echo "==> Step 4: Checking that python3 is available on ${MASTER_HOST}..."
# Checked up front so a missing interpreter is one clear line rather than a
# truncated traceback after the script has already been piped over.
if ! "${SSH_TO_MASTER[@]}" "command -v python3 >/dev/null 2>&1"; then
  echo "ERROR: python3 not found on master ${MASTER_HOST}." >&2
  echo "The health assertions run there as a Python script. Install python3 in the" >&2
  echo "node image, or adjust cluster_health.py's invocation below." >&2
  exit 1
fi

echo "==> Step 5: Running cluster health assertions on ${MASTER_HOST} (deadline ${HEALTH_TIMEOUT}s)..."
# The script arrives on stdin, so nothing is interpolated into a shell string. All
# knobs are integer-validated above, so `env VAR=value` is safe to build by hand.
"${SSH_TO_MASTER[@]}" \
  "sudo env KUBECONFIG=/etc/kubernetes/admin.conf \
     HEALTH_TIMEOUT=${HEALTH_TIMEOUT} \
     HEALTH_POLL_INTERVAL=${HEALTH_POLL_INTERVAL} \
     MAX_RESTART_COUNT=${MAX_RESTART_COUNT} \
     MIN_NODE_COUNT=${MIN_NODE_COUNT} \
     python3 -" < "$REMOTE_SCRIPT"

echo "Cluster is reachable and every assertion passed."
