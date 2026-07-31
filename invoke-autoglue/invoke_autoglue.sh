#!/usr/bin/env bash
#
# Invoke an AutoGlue action against the cluster created by `tofu apply`.
#
# Resolves the org id by name, the cluster id by name, finds the action id by its
# make target, makes sure the bastion is ready (nudging it back to pending if not),
# triggers an action run (the "kubernetes setup" invocation), then polls the run
# status until it succeeds (exit 0) or fails (exit 1). Called by the test-apply
# workflow after apply. Requires `curl` and `jq` on PATH.
#
# Required environment variables:
#   BASE_URL            AutoGlue API base url
#   API_KEY             AutoGlue API key            (sent as X-API-KEY header)
#   ORG_NAME            AutoGlue org name (resolved to org id via the /orgs endpoint)
#   CLUSTER_NAME        Name of the cluster to look up
#   ACTION_MAKE_TARGET  make_target of the action to run (the k8s setup target)
# Optional:
#   POLL_INTERVAL_SECONDS  seconds between status checks (default 30)
#   POLL_TIMEOUT_SECONDS   give up on the run after this long (default 2700 = 45m)
#   INITIAL_DELAY_SECONDS  settle time before touching the API at all (default 300)
#   BASTION_SETTLE_SECONDS settle time after the bastion check, before triggering (default 300)
set -euo pipefail

POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-30}"
# Kept under the workflow job's timeout-minutes so the script fails with a useful message
# naming the last status, rather than the job being killed mid-poll with no explanation.
POLL_TIMEOUT_SECONDS="${POLL_TIMEOUT_SECONDS:-2700}"
# Its own knob rather than reusing POLL_INTERVAL_SECONDS: this is a settle window, not a
# poll cadence, so dropping the poll interval must not silently shorten it.
INITIAL_DELAY_SECONDS="${INITIAL_DELAY_SECONDS:-300}"
BASTION_SETTLE_SECONDS="${BASTION_SETTLE_SECONDS:-300}"

# Validate before the settle sleep, so a missing variable fails immediately.
: "${BASE_URL:?BASE_URL is required}"
: "${API_KEY:?API_KEY is required}"
: "${ORG_NAME:?ORG_NAME is required}"
: "${CLUSTER_NAME:?CLUSTER_NAME is required}"
: "${ACTION_MAKE_TARGET:?ACTION_MAKE_TARGET is required}"

sleep "${INITIAL_DELAY_SECONDS}"

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

echo "==> Step 2: Getting cluster_id for cluster '${CLUSTER_NAME}'..."
CLUSTERS=$(curl -sfS --http1.1 -G "${BASE_URL}/clusters" \
  --data-urlencode "q=${CLUSTER_NAME}" \
  -H "accept: application/json" \
  -H "X-API-KEY: ${API_KEY}" \
  -H "x-org-id: ${ORG_ID}")

CLUSTER_ID=$(echo "$CLUSTERS" | jq -r '.[0].id')

if [ -z "$CLUSTER_ID" ] || [ "$CLUSTER_ID" = "null" ]; then
  echo "ERROR: Cluster '${CLUSTER_NAME}' not found"
  exit 1
fi
echo "Found cluster_id: ${CLUSTER_ID}"

echo "==> Step 3: Getting action_id for action '${ACTION_MAKE_TARGET}'..."
ACTIONS=$(curl -sfS --http1.1 -X GET "${BASE_URL}/admin/actions" \
  -H "accept: application/json" \
  -H "X-API-KEY: ${API_KEY}" \
  -H "x-org-id: ${ORG_ID}")

ACTION_ID=$(echo "$ACTIONS" | jq -r --arg mt "$ACTION_MAKE_TARGET" \
  '.[] | select(.make_target == $mt) | .id')

if [ -z "$ACTION_ID" ] || [ "$ACTION_ID" = "null" ]; then
  echo "ERROR: Action '${ACTION_MAKE_TARGET}' not found"
  exit 1
fi
echo "Found action_id: ${ACTION_ID}"

echo "==> Step 4: Checking bastion status..."
BASTIONS=$(curl -sfS --http1.1 -G "${BASE_URL}/servers" \
  --data-urlencode "role=bastion" \
  -H "accept: application/json" \
  -H "X-API-KEY: ${API_KEY}" \
  -H "x-org-id: ${ORG_ID}")

BASTION=$(echo "$BASTIONS" | jq -r '.[0] // empty')
if [ -z "$BASTION" ]; then
  echo "ERROR: no bastion server returned by ${BASE_URL}/servers?role=bastion"
  exit 1
fi

BASTION_ID=$(echo "$BASTION" | jq -r '.id')
BASTION_STATUS=$(echo "$BASTION" | jq -r '.status' | tr '[:upper:]' '[:lower:]')
echo "bastion ${BASTION_ID} status: ${BASTION_STATUS}"

if [ "$BASTION_STATUS" = "ready" ]; then
  echo "Bastion is ready."
else
  echo "Bastion is not ready, setting its status back to pending..."
  curl -sfS --http1.1 -X PATCH "${BASE_URL}/servers/${BASTION_ID}" \
    -H "accept: application/json" \
    -H "content-type: application/json" \
    -H "X-API-KEY: ${API_KEY}" \
    -H "x-org-id: ${ORG_ID}" \
    --data-raw '{"status":"pending"}' > /dev/null
fi

# Settle window between nudging the bastion and triggering the action. Same 300s
# as before; a knob only so the mock-API tests can drive it to 0.
sleep "${BASTION_SETTLE_SECONDS}"

echo "==> Step 5: Triggering action run..."
RESPONSE=$(curl -sfS --http1.1 -X POST "${BASE_URL}/clusters/${CLUSTER_ID}/actions/${ACTION_ID}/runs" \
  -H "accept: application/json" \
  -H "X-API-KEY: ${API_KEY}" \
  -H "x-org-id: ${ORG_ID}")

echo "Action triggered successfully:"
echo "$RESPONSE" | jq .

RUN_ID=$(echo "$RESPONSE" | jq -r '.id')
if [ -z "$RUN_ID" ] || [ "$RUN_ID" = "null" ]; then
  echo "ERROR: could not determine run id from the trigger response"
  exit 1
fi
echo "Started run_id: ${RUN_ID}"

echo "==> Step 6: Polling run status every ${POLL_INTERVAL_SECONDS}s (giving up after $(( POLL_TIMEOUT_SECONDS / 60 ))m)..."
# SECONDS is reset here so the deadline covers only the poll loop, not the settle sleep
# and setup calls above.
SECONDS=0
LAST_STATUS="unknown (no successful status check yet)"

while true; do
  if [ "$SECONDS" -ge "$POLL_TIMEOUT_SECONDS" ]; then
    echo "ERROR: giving up on run ${RUN_ID} after $(( SECONDS / 60 ))m — last status seen: ${LAST_STATUS}"
    echo "The run may still be in progress; check it at ${BASE_URL}/clusters/${CLUSTER_ID}/runs/${RUN_ID}"
    exit 1
  fi

  RUN=$(curl -sfS --http1.1 -X GET "${BASE_URL}/clusters/${CLUSTER_ID}/runs/${RUN_ID}" \
    -H "accept: application/json" \
    -H "X-API-KEY: ${API_KEY}" \
    -H "x-org-id: ${ORG_ID}") || {
    echo "WARN: status check failed (transient?), retrying in ${POLL_INTERVAL_SECONDS}s (last status: ${LAST_STATUS}, ${SECONDS}s elapsed)"
    sleep "${POLL_INTERVAL_SECONDS}"
    continue
  }

  STATUS=$(echo "$RUN" | jq -r '.status' | tr '[:upper:]' '[:lower:]')
  LAST_STATUS="$STATUS"
  echo "run ${RUN_ID} status: ${STATUS} (${SECONDS}s elapsed)"

  case "$STATUS" in
    succeeded)
      echo "Run succeeded after ${SECONDS}s."
      break
      ;;
    failed)
      echo "ERROR: run failed after ${SECONDS}s."
      echo "$RUN" | jq -r '.error // "no error message provided"'
      exit 1
      ;;
    *)
      sleep "${POLL_INTERVAL_SECONDS}"
      ;;
  esac
done
