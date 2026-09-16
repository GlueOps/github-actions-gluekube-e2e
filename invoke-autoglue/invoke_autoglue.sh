#!/usr/bin/env bash
#
# Invoke an AutoGlue action against the cluster created by `tofu apply`.
#
# Resolves the org id by name, the cluster id by name, finds the action id by its
# make target, waits for the bastion to be ready (re-pending it if provisioning fails),
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
#   BASTION_READY_TIMEOUT  how long to wait for the bastion to report ready (default 600)
#   BASTION_POLL_INTERVAL  seconds between bastion status checks (default 15)
#   BASTION_MAX_RETRIES    times a `failed` bastion is set back to pending (default 2,
#                          i.e. up to 3 provisioning attempts in total)
#   BASTION_RETRY_BACKOFF  seconds to wait after a failure before re-pending (default 60)
set -euo pipefail

POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-30}"
# Kept under the workflow job's timeout-minutes so the script fails with a useful message
# naming the last status, rather than the job being killed mid-poll with no explanation.
POLL_TIMEOUT_SECONDS="${POLL_TIMEOUT_SECONDS:-2700}"
# The bastion readiness wait is a bounded POLL, not a fixed sleep. It used to be two
# unconditional `sleep 300`s -- one before touching the API at all, one after nudging
# the bastion -- which cost every run ten minutes whether or not anything needed the
# time, and still gave no guarantee at the end of it. Polling both removes the dead
# time from a fast run and actually waits for the condition on a slow one.
BASTION_READY_TIMEOUT="${BASTION_READY_TIMEOUT:-600}"
BASTION_POLL_INTERVAL="${BASTION_POLL_INTERVAL:-15}"
# A bastion that fails provisioning stays `failed` until something sets it back to
# pending; AutoGlue often tries before the fresh VM has settled, so it gets a bounded
# number of re-pends. A bastion already `failed` at the first poll uses one of them.
BASTION_MAX_RETRIES="${BASTION_MAX_RETRIES:-2}"
BASTION_RETRY_BACKOFF="${BASTION_RETRY_BACKOFF:-60}"

: "${BASE_URL:?BASE_URL is required}"
: "${API_KEY:?API_KEY is required}"
: "${ORG_NAME:?ORG_NAME is required}"
: "${CLUSTER_NAME:?CLUSTER_NAME is required}"
: "${ACTION_MAKE_TARGET:?ACTION_MAKE_TARGET is required}"

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

echo "==> Step 4: Waiting for the bastion to report ready (deadline ${BASTION_READY_TIMEOUT}s, up to ${BASTION_MAX_RETRIES} re-pend(s) on failure)..."
# Fetch the bastion record. Echoes the server object, empty if there is none yet.
get_bastion() {
  curl -sfS --http1.1 -G "${BASE_URL}/servers" \
    --data-urlencode "role=bastion" \
    -H "accept: application/json" \
    -H "X-API-KEY: ${API_KEY}" \
    -H "x-org-id: ${ORG_ID}" 2>/dev/null | jq -r '.[0] // empty'
}

# PATCH the bastion back to pending so AutoGlue provisions it again. Never trips
# `set -e`: a rejected or failed PATCH is logged and reported via the return code so
# the caller can simply try again on the next poll.
patch_bastion_pending() {
  local out code
  if ! out=$(curl -sS --http1.1 -X PATCH "${BASE_URL}/servers/${BASTION_ID}" \
    -H "accept: application/json" \
    -H "content-type: application/json" \
    -H "X-API-KEY: ${API_KEY}" \
    -H "x-org-id: ${ORG_ID}" \
    --data-raw '{"status":"pending"}' \
    -w '\n%{http_code}' 2>&1); then
    echo "  WARN: re-pend PATCH failed: ${out}"
    return 1
  fi
  code="${out##*$'\n'}"
  if [[ "$code" != 2* ]]; then
    echo "  WARN: re-pend PATCH returned HTTP ${code}: ${out%$'\n'*}"
    return 1
  fi
}

# Re-pend the bastion and immediately re-read it, so the log shows whether AutoGlue
# took the change. PATCHED_AT stays set only while the bastion still reads `failed`
# after our PATCH; a `failed` seen in that window is our own stale state, not a new
# provisioning failure, and must not use up a retry.
repend_bastion() {
  patch_bastion_pending || return 1
  PATCHED_AT=$SECONDS
  local after_status
  after_status=$(get_bastion | jq -r '.status // "unknown"' | tr '[:upper:]' '[:lower:]' || true)
  echo "  bastion status right after re-pend: ${after_status:-unknown}"
  if [ "$after_status" != "failed" ]; then
    PATCHED_AT=""
  fi
}

# Best-effort diagnostics for a bastion that never came up. Servers carry no error
# field today, so the cluster's last_error is usually the useful one.
print_bastion_diagnostics() {
  local cluster_err server_err
  cluster_err=$(curl -sfS --http1.1 -G "${BASE_URL}/clusters" \
    --data-urlencode "q=${CLUSTER_NAME}" \
    -H "accept: application/json" \
    -H "X-API-KEY: ${API_KEY}" \
    -H "x-org-id: ${ORG_ID}" 2>/dev/null \
    | jq -r --arg id "$CLUSTER_ID" '.[] | select(.id == $id) | .last_error // empty' || true)
  server_err=$(echo "${BASTION:-}" | jq -r '.last_error // .error // empty' 2>/dev/null || true)
  [ -n "$cluster_err" ] && echo "  cluster last_error: ${cluster_err}"
  [ -n "$server_err" ] && echo "  bastion error: ${server_err}"
  return 0
}

# A new provisioning attempt needs at least this long to have a real chance of
# finishing before the deadline; retrying with less left would only waste the run.
MIN_ATTEMPT_SECONDS=120
# If the bastion still reads `failed` this long after a re-pend, the PATCH is
# assumed not to have taken and is sent again (not counted as a retry).
REPEND_CONFIRM_SECONDS=30
MAX_ATTEMPTS=$(( BASTION_MAX_RETRIES + 1 ))

SECONDS=0
RETRIES=0
FAILED_AT=""
PATCHED_AT=""
BASTION=""
BASTION_READY=false
BASTION_FAIL_REASON=""
LAST_BASTION_STATUS="unknown (no successful check yet)"

while [ "$SECONDS" -lt "$BASTION_READY_TIMEOUT" ]; do
  BASTION=$(get_bastion || true)
  if [ -z "$BASTION" ]; then
    # Right after apply the record may not be visible yet. Transient until the
    # deadline, rather than an immediate hard failure.
    echo "  no bastion server yet (${SECONDS}s elapsed) - retrying in ${BASTION_POLL_INTERVAL}s"
    sleep "$BASTION_POLL_INTERVAL"
    continue
  fi

  BASTION_ID=$(echo "$BASTION" | jq -r '.id')
  BASTION_STATUS=$(echo "$BASTION" | jq -r '.status' | tr '[:upper:]' '[:lower:]')
  LAST_BASTION_STATUS="$BASTION_STATUS"
  echo "  bastion ${BASTION_ID} status: ${BASTION_STATUS} (${SECONDS}s elapsed)"

  case "$BASTION_STATUS" in
    ready)
      BASTION_READY=true
      break
      ;;
    pending|provisioning)
      # A (re)provisioning attempt is in flight. Leave it alone: PATCHing now would
      # reset the progress it is making.
      PATCHED_AT=""
      FAILED_AT=""
      ;;
    failed)
      if [ -n "$PATCHED_AT" ]; then
        if [ $(( SECONDS - PATCHED_AT )) -ge "$REPEND_CONFIRM_SECONDS" ]; then
          echo "  bastion still failed $(( SECONDS - PATCHED_AT ))s after re-pend; sending it again (not counted as a retry)"
          repend_bastion || true
        fi
      else
        if [ -z "$FAILED_AT" ]; then
          FAILED_AT=$SECONDS
          echo "  bastion provisioning attempt $(( RETRIES + 1 ))/${MAX_ATTEMPTS} failed"
          if [ "$RETRIES" -ge "$BASTION_MAX_RETRIES" ]; then
            BASTION_FAIL_REASON="bastion failed on attempt $(( RETRIES + 1 ))/${MAX_ATTEMPTS}, no retries left"
            break
          fi
          if [ $(( BASTION_READY_TIMEOUT - SECONDS )) -lt $(( BASTION_RETRY_BACKOFF + MIN_ATTEMPT_SECONDS )) ]; then
            BASTION_FAIL_REASON="bastion failed with $(( BASTION_READY_TIMEOUT - SECONDS ))s left before the deadline, not enough for another attempt"
            break
          fi
          echo "  re-pending the bastion in ${BASTION_RETRY_BACKOFF}s"
        fi
        # The backoff gives the VM time to settle (cloud-init, reboots) before
        # AutoGlue tries again. Polling continues meanwhile, rather than one long
        # sleep, so the deadline is still honoured.
        if [ $(( SECONDS - FAILED_AT )) -ge "$BASTION_RETRY_BACKOFF" ] && repend_bastion; then
          RETRIES=$(( RETRIES + 1 ))
          FAILED_AT=""
          echo "  re-pended the bastion (retry ${RETRIES}/${BASTION_MAX_RETRIES})"
        fi
      fi
      ;;
    *)
      # Unknown status: wait rather than PATCH, which could reset progress on a
      # state this script does not know about.
      echo "  unrecognised bastion status '${BASTION_STATUS}', waiting"
      ;;
  esac

  sleep "$BASTION_POLL_INTERVAL"
done

if [ "$BASTION_READY" != true ]; then
  echo "ERROR: ${BASTION_FAIL_REASON:-bastion did not report ready within ${BASTION_READY_TIMEOUT}s} — last status: ${LAST_BASTION_STATUS}, re-pends used: ${RETRIES}/${BASTION_MAX_RETRIES}"
  print_bastion_diagnostics
  exit 1
fi
echo "Bastion is ready after ${SECONDS}s."

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
