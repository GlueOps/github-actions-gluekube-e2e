#!/usr/bin/env python3
"""Assert the cluster reached its expected state, polling until it converges.

Runs ON THE MASTER under the kubeadm admin kubeconfig. check_cluster_health.sh
pipes this file to `sudo python3 -` over ssh, so it is never interpolated into a
shell string and nothing here has to survive nested quoting. That is deliberate:
the previous version lived inside `sudo bash -c '...'` and could not contain a
single quote anywhere.

Every assertion reads kubectl alone. No tofu state, no tofu outputs, no expected
counts plumbed in from the workflow -- the checker asks the cluster what it looks
like and decides whether that is healthy.

Assertions. All of them must hold *simultaneously* in one poll round, so a
cluster that fixes its nodes only after its pods have degraded still fails:

  N1  at least one node exists
  N2  every node reports condition Ready=True
  N3  at least one control-plane node exists, and every control-plane node is Ready
  N4  at least MIN_NODE_COUNT nodes are Ready          (only when MIN_NODE_COUNT is set)
  P1  every pod is healthy: phase Succeeded (completed Jobs are fine), or phase
      Running with every containerStatuses[].ready true
  P2  no container has restartCount above MAX_RESTART_COUNT
  P3  at least one pod exists

N1 and P3 are the guards that stop the checker asserting nothing: an empty
cluster has no NotReady nodes and no Pending pods, so without them it would pass
vacuously -- which is exactly how the old check reported green on a cluster that
had never come up.

Environment:
  HEALTH_TIMEOUT        overall deadline, seconds        (default 900)
  HEALTH_POLL_INTERVAL  seconds between polls            (default 15)
  MIN_NODE_COUNT        floor on Ready nodes, optional   (unset = no floor)
  MAX_RESTART_COUNT     per-container restart ceiling    (default 3)
  KUBECONFIG            (default /etc/kubernetes/admin.conf)

Exit status:
  0  all assertions passed
  1  deadline expired with at least one assertion still failing
"""

import json
import os
import subprocess
import sys
import time

CONTROL_PLANE_LABELS = (
    "node-role.kubernetes.io/control-plane",
    # kubeadm set this instead before 1.24. Accepted so the control-plane
    # assertion does not silently pass-by-absence on an older cluster.
    "node-role.kubernetes.io/master",
)

# How many offending items to name on a single progress line. A fully broken
# cluster would otherwise print hundreds of lines every poll and bury the tally.
MAX_LISTED = 5


def _int_env(name, default):
    raw = os.environ.get(name, "")
    if raw == "":
        return default
    try:
        return int(raw)
    except ValueError:
        print("ERROR: %s must be an integer, got: %r" % (name, raw), file=sys.stderr)
        sys.exit(2)


HEALTH_TIMEOUT = _int_env("HEALTH_TIMEOUT", 900)
HEALTH_POLL_INTERVAL = _int_env("HEALTH_POLL_INTERVAL", 15)
MAX_RESTART_COUNT = _int_env("MAX_RESTART_COUNT", 3)
MIN_NODE_COUNT = _int_env("MIN_NODE_COUNT", 0)  # 0 == unset == no floor

os.environ.setdefault("KUBECONFIG", "/etc/kubernetes/admin.conf")


def kubectl(args, timeout=60):
    """Run kubectl and return (ok, stdout). Never raises."""
    try:
        proc = subprocess.run(
            ["kubectl"] + args,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return False, str(exc)
    if proc.returncode != 0:
        return False, (proc.stderr or proc.stdout).strip()
    return True, proc.stdout


def kubectl_json(args):
    """Run kubectl -o json and parse it. Returns (ok, obj_or_error_string)."""
    ok, out = kubectl(args + ["-o", "json"])
    if not ok:
        return False, out
    try:
        return True, json.loads(out)
    except ValueError as exc:
        return False, "could not parse kubectl JSON: %s" % exc


def truncate(items):
    """Render a list for a progress line, capped so one poll stays one line."""
    shown = ", ".join(items[:MAX_LISTED])
    if len(items) > MAX_LISTED:
        shown += ", +%d more" % (len(items) - MAX_LISTED)
    return shown


# --------------------------------------------------------------------------
# Node assertions
# --------------------------------------------------------------------------

def check_nodes(nodes):
    """Evaluate N1-N4. Returns (failures, progress_line)."""
    failures = []
    total = len(nodes)

    ready_names, not_ready_names = [], []
    cp_total, cp_not_ready = 0, []

    for node in nodes:
        name = node.get("metadata", {}).get("name", "<unnamed>")
        labels = node.get("metadata", {}).get("labels") or {}

        # The Ready *condition*, not the STATUS text column: a cordoned node
        # prints "Ready,SchedulingDisabled" but is still Ready=True, and the
        # column is a rendering of the conditions anyway.
        ready = False
        for cond in node.get("status", {}).get("conditions") or []:
            if cond.get("type") == "Ready":
                ready = cond.get("status") == "True"
                break

        (ready_names if ready else not_ready_names).append(name)

        if any(label in labels for label in CONTROL_PLANE_LABELS):
            cp_total += 1
            if not ready:
                cp_not_ready.append(name)

    # N1
    if total == 0:
        failures.append("N1: no nodes exist (an empty cluster is not a healthy one)")
    # N2
    if not_ready_names:
        failures.append("N2: %d node(s) not Ready: %s"
                        % (len(not_ready_names), truncate(sorted(not_ready_names))))
    # N3
    if total and cp_total == 0:
        failures.append("N3: no control-plane node found (looked for labels: %s)"
                        % ", ".join(CONTROL_PLANE_LABELS))
    elif cp_not_ready:
        failures.append("N3: %d control-plane node(s) not Ready: %s"
                        % (len(cp_not_ready), truncate(sorted(cp_not_ready))))
    # N4
    if MIN_NODE_COUNT and len(ready_names) < MIN_NODE_COUNT:
        failures.append("N4: only %d node(s) Ready, MIN_NODE_COUNT=%d"
                        % (len(ready_names), MIN_NODE_COUNT))

    line = "Nodes: %d/%d Ready" % (len(ready_names), total)
    if cp_total:
        line += ", %d control-plane" % cp_total
    if not_ready_names:
        line += ", not ready: %s" % truncate(sorted(not_ready_names))
    return failures, line


# --------------------------------------------------------------------------
# Pod assertions
# --------------------------------------------------------------------------

def check_pods(pods):
    """Evaluate P1-P3. Returns (failures, progress_line, unhealthy_refs)."""
    failures = []
    total = len(pods)

    healthy = 0
    unhealthy = []      # (ref, short_detail) for the progress line
    unhealthy_refs = [] # (namespace, name) for the diagnostic dump
    over_restarts = []

    for pod in pods:
        meta = pod.get("metadata", {})
        ns = meta.get("namespace", "default")
        name = meta.get("name", "<unnamed>")
        ref = "%s/%s" % (ns, name)

        status = pod.get("status", {})
        phase = status.get("phase", "Unknown")
        container_statuses = status.get("containerStatuses") or []
        init_statuses = status.get("initContainerStatuses") or []

        # P2 is evaluated for every pod, including healthy ones: that is the
        # whole point -- it catches a crashloop that happens to be momentarily
        # Ready at the instant we polled.
        for cs in container_statuses + init_statuses:
            count = cs.get("restartCount", 0)
            if count > MAX_RESTART_COUNT:
                over_restarts.append("%s:%s=%d" % (ref, cs.get("name", "?"), count))

        # A completed Job pod is healthy, not a failure.
        if phase == "Succeeded":
            healthy += 1
            continue

        problems = []
        if phase != "Running":
            detail = "phase=%s" % phase
            reason = status.get("reason")
            if reason:
                detail += "/%s" % reason
            problems.append(detail)

        # Waiting reasons carry the actual cause: CrashLoopBackOff,
        # ImagePullBackOff, ErrImagePull, CreateContainerConfigError.
        for cs in container_statuses + init_statuses:
            waiting = (cs.get("state") or {}).get("waiting") or {}
            if waiting.get("reason"):
                problems.append("%s=%s" % (cs.get("name", "?"), waiting["reason"]))

        if phase == "Running":
            ready_n = sum(1 for cs in container_statuses if cs.get("ready"))
            if ready_n != len(container_statuses) or not container_statuses:
                # A CrashLoopBackOff pod has phase Running -- it is the
                # *container* that is not ready. This is the assertion the old
                # phase-only check was missing entirely.
                problems.append("Running(%d/%d ready)" % (ready_n, len(container_statuses)))

        if problems:
            unhealthy.append("%s=%s" % (ref, ",".join(problems)))
            unhealthy_refs.append((ns, name))
        else:
            healthy += 1

    # P3
    if total == 0:
        failures.append("P3: no pods exist at all (a working cluster always has kube-system pods)")
    # P1
    if unhealthy:
        failures.append("P1: %d unhealthy pod(s): %s" % (len(unhealthy), truncate(unhealthy)))
    # P2
    if over_restarts:
        failures.append("P2: %d container(s) above MAX_RESTART_COUNT=%d: %s"
                        % (len(over_restarts), MAX_RESTART_COUNT, truncate(over_restarts)))

    line = "Pods: %d/%d healthy" % (healthy, total)
    if unhealthy:
        line += ", unhealthy: %s" % truncate(unhealthy)
    return failures, line, unhealthy_refs


# --------------------------------------------------------------------------
# Diagnostics
# --------------------------------------------------------------------------

def dump_diagnostics(unhealthy_refs):
    """Best-effort cluster dump. Must never change the exit code.

    A failed nightly otherwise tells you almost nothing, and investigating means
    re-running a 30-minute apply against a cluster that no longer exists. Every
    command here is allowed to fail: a broken apiserver still lets the rest of
    the dump through, and a diagnostic failure must never mask the real error.
    """
    print("")
    print("================== FAILURE DIAGNOSTICS ==================")

    def show(title, args, timeout=60):
        print("--- %s ---" % title)
        try:
            ok, out = kubectl(args, timeout=timeout)
            print(out.rstrip() if ok else "(diagnostic failed: %s)" % out)
        except Exception as exc:  # noqa: BLE001 - diagnostics never propagate
            print("(diagnostic raised: %s)" % exc)

    show("kubectl get nodes -o wide", ["get", "nodes", "-o", "wide"])
    show("kubectl get pods -A -o wide", ["get", "pods", "-A", "-o", "wide"])

    for ns, name in unhealthy_refs[:20]:
        show("kubectl describe pod -n %s %s" % (ns, name),
             ["describe", "pod", "-n", ns, name], timeout=120)
        show("previous container logs for %s/%s (last 50)" % (ns, name),
             ["logs", "-n", ns, name, "--all-containers", "--previous", "--tail=50"])
    if len(unhealthy_refs) > 20:
        print("--- (%d further unhealthy pods not described) ---"
              % (len(unhealthy_refs) - 20))

    print("--- kubectl get events -A --sort-by=.lastTimestamp (last 50) ---")
    try:
        ok, out = kubectl(["get", "events", "-A", "--sort-by=.lastTimestamp"])
        print("\n".join(out.rstrip().splitlines()[-50:]) if ok
              else "(diagnostic failed: %s)" % out)
    except Exception as exc:  # noqa: BLE001
        print("(diagnostic raised: %s)" % exc)

    print("=========================================================")


def summarise(passed, failures, node_line, pod_line, elapsed, attempts):
    """Short verdict block, so a failed run is readable without scrolling."""
    print("")
    print("======================= SUMMARY =========================")
    print("Result:   %s" % ("PASS" if passed else "FAIL"))
    print("Duration: %ds over %d poll(s), deadline %ds" % (elapsed, attempts, HEALTH_TIMEOUT))
    print("Final:    %s" % node_line)
    print("          %s" % pod_line)
    if failures:
        print("Failing assertions:")
        for failure in failures:
            print("  - %s" % failure)
    else:
        print("All assertions passed (N1-N4, P1-P3).")
    print("=========================================================")


# --------------------------------------------------------------------------

def main():
    print("Health check starting: deadline %ds, poll every %ds, "
          "MAX_RESTART_COUNT=%d, MIN_NODE_COUNT=%s"
          % (HEALTH_TIMEOUT, HEALTH_POLL_INTERVAL, MAX_RESTART_COUNT,
             MIN_NODE_COUNT or "unset"))

    started = time.time()
    deadline = started + HEALTH_TIMEOUT
    attempts = 0
    failures = ["no successful poll completed"]
    node_line = pod_line = "(never polled successfully)"
    unhealthy_refs = []

    while True:
        attempts += 1
        elapsed = int(time.time() - started)

        node_ok, nodes = kubectl_json(["get", "nodes"])
        pod_ok, podlist = kubectl_json(["get", "pods", "-A"])

        if not node_ok or not pod_ok:
            # The master is briefly unreachable while the setup action is still
            # working on it. That is normal, so this is a warning until the
            # deadline -- only a *persistent* failure is fatal.
            failures = ["kubectl unavailable: %s" % (nodes if not node_ok else podlist)]
            print("WARN: %s  (elapsed %ds / %ds)" % (failures[0], elapsed, HEALTH_TIMEOUT))
        else:
            node_failures, node_line = check_nodes(nodes.get("items") or [])
            pod_failures, pod_line, unhealthy_refs = check_pods(podlist.get("items") or [])
            failures = node_failures + pod_failures

            print("%s  (elapsed %ds / %ds)" % (node_line, elapsed, HEALTH_TIMEOUT))
            print("%s  (elapsed %ds / %ds)" % (pod_line, elapsed, HEALTH_TIMEOUT))

            if not failures:
                summarise(True, [], node_line, pod_line,
                          int(time.time() - started), attempts)
                return 0

            for failure in failures:
                print("  FAIL %s" % failure)

        if time.time() >= deadline:
            print("")
            print("ERROR: assertions still failing after %ds." % HEALTH_TIMEOUT)
            dump_diagnostics(unhealthy_refs)
            summarise(False, failures, node_line, pod_line,
                      int(time.time() - started), attempts)
            return 1

        remaining = int(deadline - time.time())
        print("  not fatal yet - re-checking in %ds (%ds left before the deadline)"
              % (HEALTH_POLL_INTERVAL, remaining))
        time.sleep(min(HEALTH_POLL_INTERVAL, max(remaining, 1)))


if __name__ == "__main__":
    sys.exit(main())
