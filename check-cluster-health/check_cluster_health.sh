#!/usr/bin/env bash
#
# Check that the cluster created by `tofu apply` + the AutoGlue setup action is healthy.
#
# The masters sit in private subnets, so this hops through the bastion: it resolves the
# org id by name, picks a bastion and a master, reveals both servers' ssh private keys,
# then ssh's to the master's private ip *through* the bastion and evaluates pod health
# against the kubeadm admin kubeconfig.
#
# Health model (see REMOTE_CHECK below):
#   - Succeeded pods (completed Jobs) are healthy and ignored.
#   - Any other non-Running phase (Pending/Failed/Unknown) is unhealthy.
#   - A Running pod is unhealthy if a container is waiting (CrashLoopBackOff,
#     ImagePullBackOff, ...) or is not ready.
#   - Unhealthy pods are re-polled until POLL_TIMEOUT_SECONDS, so a pod that is
#     briefly not ready and recovers still passes; only a pod that is STUCK fails.
#
# Exits 0 if every pod is healthy within the deadline, 1 otherwise.
# Requires `curl`, `jq` and `ssh` on PATH.
#
# Required environment variables:
#   BASE_URL   AutoGlue API base url
#   API_KEY    AutoGlue API key   (sent as X-API-KEY header)
#   ORG_NAME   AutoGlue org name  (resolved to org id via the /orgs endpoint)
#
# Optional:
#   POLL_TIMEOUT_SECONDS   how long a pod may stay unhealthy before failing (default 300)
#   POLL_INTERVAL_SECONDS  delay between polls (default 15)
set -euo pipefail

: "${BASE_URL:?BASE_URL is required}"
: "${API_KEY:?API_KEY is required}"
: "${ORG_NAME:?ORG_NAME is required}"

POLL_TIMEOUT_SECONDS="${POLL_TIMEOUT_SECONDS:-300}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-15}"
# These are interpolated into the remote script, so reject anything that is not a
# plain integer rather than shipping it to the master.
for var in POLL_TIMEOUT_SECONDS POLL_INTERVAL_SECONDS; do
  case "${!var}" in
    "" | *[!0-9]*)
      echo "ERROR: ${var} must be a non-negative integer, got: ${!var}" >&2
      exit 1
      ;;
  esac
done

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

echo "==> Step 4: Checking pod health on ${MASTER_HOST} via the bastion (deadline ${POLL_TIMEOUT_SECONDS}s)..."
SSH_OPTS=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=30
  # The remote side polls for up to POLL_TIMEOUT_SECONDS with no output between
  # rounds; keepalives stop a NAT/firewall from dropping an idle session.
  -o ServerAliveInterval=30
  -o ServerAliveCountMax=10
)

# Remote check: classify every pod, then keep re-polling until they are all healthy
# or the deadline passes. Runs on the master under the kubeadm admin kubeconfig.
#
# NOTE: this whole string is interpolated into `sudo bash -c '...'` below, so it must not
# contain a single quote anywhere — use double quotes only. CI enforces this.
#
# One line per pod is emitted by a jsonpath template, pipe-separated so that fields which
# hold several space-joined values (container names, ready flags, waiting reasons) stay in
# their own column. Missing keys render empty — kubectl defaults to
# --allow-missing-template-keys=true — so pods with no containerStatuses are handled too.
#
# On failure it dumps cluster state before exiting: nodes, all pods, a describe plus the
# previous container logs for each pod flagged unhealthy, and the tail of the event log.
# Every diagnostic is `|| true` so a broken apiserver still lets the rest of the dump
# through. The ERR trap covers the kubectl calls failing outright; the deadline branch
# calls the dump directly, since an explicit `exit` does not fire an ERR trap.
REMOTE_CHECK='
set -euo pipefail
export KUBECONFIG=/etc/kubernetes/admin.conf

POD_TEMPLATE="{range .items[*]}{.metadata.namespace}/{.metadata.name}{\"|\"}{.status.phase}{\"|\"}{.status.reason}{\"|\"}{.status.containerStatuses[*].name}{\"|\"}{.status.containerStatuses[*].ready}{\"|\"}{.status.containerStatuses[*].state.waiting.reason}{\"|\"}{.status.initContainerStatuses[*].state.waiting.reason}{\"|\"}{.status.containerStatuses[*].restartCount}{\"\n\"}{end}"

bad=""

dump_diagnostics() {
  echo ""
  echo "================== FAILURE DIAGNOSTICS =================="

  echo "--- kubectl get nodes -o wide ---"
  kubectl get nodes -o wide 2>&1 || true

  echo "--- kubectl get pods -A -o wide ---"
  kubectl get pods -A -o wide 2>&1 || true

  if [ -n "${bad:-}" ]; then
    echo "--- unhealthy pod detail ---"
    printf "%s" "$bad" | while read -r ref problems; do
      [ -n "$ref" ] || continue
      ns=${ref%%/*}
      name=${ref#*/}
      echo "--- kubectl describe pod -n $ns $name ($problems) ---"
      kubectl describe pod -n "$ns" "$name" 2>&1 || true
      echo "--- previous container logs for $ns/$name (last 50 lines) ---"
      kubectl logs -n "$ns" "$name" --all-containers --previous --tail=50 2>&1 || true
    done
  fi

  echo "--- kubectl get events -A --sort-by=.lastTimestamp (last 50) ---"
  kubectl get events -A --sort-by=.lastTimestamp 2>&1 | tail -n 50 || true

  echo "========================================================"
}
trap dump_diagnostics ERR

add_problem() {
  if [ -z "$problems" ]; then problems="$1"; else problems="$problems $1"; fi
}

deadline=$(( $(date +%s) + POLL_TIMEOUT_SECONDS ))
attempt=0

while true; do
  attempt=$(( attempt + 1 ))
  pods=$(kubectl get pods -A -o jsonpath="$POD_TEMPLATE")
  bad=""

  # IFS is set only for read, so the body still word-splits the space-joined
  # columns on whitespace as usual.
  while IFS="|" read -r ref phase pod_reason names readys waitings init_waitings restarts; do
    [ -n "$ref" ] || continue
    problems=""

    # A completed Job pod is healthy, not a failure.
    if [ "$phase" = "Succeeded" ]; then
      continue
    fi

    if [ "$phase" != "Running" ]; then
      add_problem "phase=$phase"
      if [ -n "$pod_reason" ]; then
        add_problem "reason=$pod_reason"
      fi
    fi

    # Catches CrashLoopBackOff, ImagePullBackOff, ErrImagePull, CreateContainerConfigError.
    for reason in $waitings; do
      add_problem "waiting=$reason"
    done
    for reason in $init_waitings; do
      add_problem "init-waiting=$reason"
    done

    # Ready flags and restart counts line up with container names index-for-index:
    # all three come from containerStatuses, and both fields are always present.
    read -ra name_list <<< "$names"
    read -ra ready_list <<< "$readys"
    read -ra restart_list <<< "$restarts"

    if [ "$phase" = "Running" ]; then
      i=0
      while [ "$i" -lt "${#ready_list[@]}" ]; do
        if [ "${ready_list[$i]}" != "true" ]; then
          add_problem "not-ready=${name_list[$i]:-container-$i}"
        fi
        i=$(( i + 1 ))
      done
    fi

    if [ -n "$problems" ]; then
      # Restart counts are context, never a failure on their own: a pod that
      # restarted and is now ready has recovered. Named per container, because a
      # bare space-joined list is unreadable on a multi-container pod.
      restart_detail=""
      i=0
      while [ "$i" -lt "${#restart_list[@]}" ]; do
        restart_detail="${restart_detail},${name_list[$i]:-container-$i}:${restart_list[$i]}"
        i=$(( i + 1 ))
      done
      if [ -n "$restart_detail" ]; then
        add_problem "restarts=${restart_detail#,}"
      fi
      bad="$bad$ref $problems
"
    fi
  done <<< "$pods"

  if [ -z "$bad" ]; then
    kubectl get pods -A
    echo "All pods are healthy on attempt $attempt (Succeeded pods ignored)."
    exit 0
  fi

  now=$(date +%s)
  echo "Attempt $attempt: $(printf "%s" "$bad" | wc -l) unhealthy pod(s):"
  printf "%s" "$bad"

  if [ "$now" -ge "$deadline" ]; then
    echo ""
    echo "ERROR: pods still unhealthy after ${POLL_TIMEOUT_SECONDS}s:"
    printf "%s" "$bad"
    dump_diagnostics
    exit 1
  fi

  echo "Not fatal yet - re-checking in ${POLL_INTERVAL_SECONDS}s ($(( deadline - now ))s left before the deadline)."
  sleep "$POLL_INTERVAL_SECONDS"
done
'

# The poll knobs are prepended rather than baked into REMOTE_CHECK so the block above
# stays a literal (CI greps it for single quotes). Both values are integer-validated.
REMOTE_SCRIPT="POLL_TIMEOUT_SECONDS=${POLL_TIMEOUT_SECONDS}
POLL_INTERVAL_SECONDS=${POLL_INTERVAL_SECONDS}
${REMOTE_CHECK}"

# ProxyCommand tunnels through the bastion with the bastion's own key, so the master
# key never has to be copied onto the bastion.
ssh -i "$MASTER_KEY_FILE" \
  "${SSH_OPTS[@]}" \
  -o ProxyCommand="ssh -i ${BASTION_KEY_FILE} ${SSH_OPTS[*]} -W %h:%p ${BASTION_USER}@${BASTION_IP}" \
  "${MASTER_USER}@${MASTER_IP}" \
  "sudo bash -c '${REMOTE_SCRIPT}'"

echo "Cluster is reachable and every pod is healthy."
