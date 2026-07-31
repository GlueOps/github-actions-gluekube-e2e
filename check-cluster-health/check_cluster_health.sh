#!/usr/bin/env bash
#
# Check that the cluster created by `tofu apply` + the AutoGlue setup action is healthy.
#
# The masters sit in private subnets, so this hops through the bastion: it resolves the
# org id by name, picks a bastion and a master, reveals both servers' ssh private keys,
# then ssh's to the master's private ip *through* the bastion and runs
# `kubectl get pods -A` against the kubeadm admin kubeconfig.
# Exits 0 if kubectl responds, 1 otherwise. Requires `curl`, `jq` and `ssh` on PATH.
#
# Required environment variables:
#   BASE_URL   AutoGlue API base url
#   API_KEY    AutoGlue API key   (sent as X-API-KEY header)
#   ORG_NAME   AutoGlue org name  (resolved to org id via the /orgs endpoint)
set -euo pipefail

: "${BASE_URL:?BASE_URL is required}"
: "${API_KEY:?API_KEY is required}"
: "${ORG_NAME:?ORG_NAME is required}"

# Fetch the first server with the given role. Echoes the server object.
get_server() {
  local role="$1"
  local servers
  servers=$(curl -sfS --http1.1 -G "${BASE_URL}/servers" \
    --data-urlencode "role=${role}" \
    -H "accept: application/json" \
    -H "X-API-KEY: ${API_KEY}" \
    -H "x-org-id: ${ORG_ID}")

  local server
  server=$(echo "$servers" | jq -r '.[0] // empty')
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

echo "==> Step 4: Running kubectl on ${MASTER_HOST} via the bastion..."
SSH_OPTS=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=30
)

# Remote check: print all pods, then fail if any pod is in a Pending or Failed phase.
# Runs on the master under the kubeadm admin kubeconfig.
#
# NOTE: this whole string is interpolated into `sudo bash -c '...'` below, so it must not
# contain a single quote anywhere — use double quotes only.
#
# On any failure it dumps cluster state before exiting: nodes, all pods, a describe for
# each pod flagged unhealthy, and the tail of the event log. Every diagnostic is `|| true`
# so a broken apiserver still lets the rest of the dump through. The ERR trap covers the
# kubectl calls failing outright; the Pending/Failed branch calls the dump directly, since
# an explicit `exit` does not fire an ERR trap.
REMOTE_CHECK='
set -euo pipefail
export KUBECONFIG=/etc/kubernetes/admin.conf

dump_diagnostics() {
  echo ""
  echo "================== FAILURE DIAGNOSTICS =================="

  echo "--- kubectl get nodes -o wide ---"
  kubectl get nodes -o wide 2>&1 || true

  echo "--- kubectl get pods -A -o wide ---"
  kubectl get pods -A -o wide 2>&1 || true

  if [ -n "${bad:-}" ]; then
    echo "--- describe unhealthy pods ---"
    printf "%s\n" "$bad" | while read -r ref phase; do
      [ -n "$ref" ] || continue
      ns=${ref%%/*}
      name=${ref#*/}
      echo "--- kubectl describe pod -n $ns $name ($phase) ---"
      kubectl describe pod -n "$ns" "$name" 2>&1 || true
    done
  fi

  echo "--- kubectl get events -A --sort-by=.lastTimestamp (last 50) ---"
  kubectl get events -A --sort-by=.lastTimestamp 2>&1 | tail -n 50 || true

  echo "========================================================"
}
trap dump_diagnostics ERR

kubectl get pods -A
bad=$(kubectl get pods -A \
  -o jsonpath="{range .items[?(@.status.phase==\"Pending\")]}{.metadata.namespace}/{.metadata.name} Pending{\"\n\"}{end}{range .items[?(@.status.phase==\"Failed\")]}{.metadata.namespace}/{.metadata.name} Failed{\"\n\"}{end}")
if [ -n "$bad" ]; then
  echo "ERROR: pods in Pending/Failed status:"
  echo "$bad"
  dump_diagnostics
  exit 1
fi
echo "All pods are healthy (none Pending or Failed)."
'

# ProxyCommand tunnels through the bastion with the bastion's own key, so the master
# key never has to be copied onto the bastion.
ssh -i "$MASTER_KEY_FILE" \
  "${SSH_OPTS[@]}" \
  -o ProxyCommand="ssh -i ${BASTION_KEY_FILE} ${SSH_OPTS[*]} -W %h:%p ${BASTION_USER}@${BASTION_IP}" \
  "${MASTER_USER}@${MASTER_IP}" \
  "sudo bash -c '${REMOTE_CHECK}'"

echo "Cluster is reachable and kubectl responded."
