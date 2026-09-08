#!/usr/bin/env python3
"""Prove the cluster still *functions*, not just that its objects look healthy.

Runs ON THE MASTER, same transport as cluster_health.py: check_cluster_health.sh
pipes this file to `sudo python3 -` over ssh. Run after the health assertions
pass, and only when SMOKE_TEST is set.

Why this exists. cluster_health.py reads object status: nodes Ready, pods Ready,
kubelet on the expected version, nothing cordoned. All of that can hold on a
cluster whose service networking or DNS is broken -- a pod is "Ready" because its
own probes pass, not because anything can reach it. `kubeadm upgrade apply`
re-applies kube-proxy and CoreDNS on every upgrade, so those are exactly the two
components most likely to come back wrong, and exactly the two nothing else here
would notice.

  S1  the apiserver reports itself ready            (kubectl get --raw /readyz)
  S2  the kubernetes and kube-dns Services both have backing endpoints
  S3  a real DNS query to the kube-dns ClusterIP resolves a known Service name

S3 is the one that earns its keep. Sending a UDP query to a ClusterIP exercises
kube-proxy's service routing AND CoreDNS answering in a single assertion, and it
fails loudly on the two upgrade regressions that "all pods are Ready" cannot see.

DELIBERATELY NO POD IS CREATED AND NO IMAGE IS PULLED. These clusters install
from mirrors (repo.gpkg.io) and the pod sandbox image is not pinned to a mirror,
so a smoke test that scheduled a busybox would fail on an unmirrored pull and
report a network regression that is really a registry problem. A false red on the
upgrade test is worse than a slightly narrower test: it trains people to re-run
it. A pod-to-pod test can be added later behind an input naming an image known
to be mirrored.

Every check polls until it holds or SMOKE_TIMEOUT expires -- CoreDNS and
kube-proxy are still rolling when the health check goes green, so a single-shot
assertion here would be flaky by construction.

Environment:
  SMOKE_TIMEOUT        overall deadline, seconds     (default 300)
  SMOKE_POLL_INTERVAL  seconds between attempts      (default 10)
  KUBECONFIG           (default /etc/kubernetes/admin.conf)

Exit status:
  0  all checks passed
  1  deadline expired with at least one check still failing
"""

import json
import os
import random
import socket
import struct
import subprocess
import sys
import time

# The name every cluster has, in the form CoreDNS is authoritative for. Using the
# apiserver's own Service rather than an external name keeps this a test of THIS
# cluster's DNS, not of the runner's upstream resolver or egress.
DNS_QUERY_NAME = "kubernetes.default.svc.cluster.local"
DNS_PORT = 53
DNS_SOCKET_TIMEOUT = 5


def _int_env(name, default):
    raw = os.environ.get(name, "")
    if raw == "":
        return default
    try:
        return int(raw)
    except ValueError:
        print("ERROR: %s must be an integer, got: %r" % (name, raw), file=sys.stderr)
        sys.exit(2)


SMOKE_TIMEOUT = _int_env("SMOKE_TIMEOUT", 300)
SMOKE_POLL_INTERVAL = _int_env("SMOKE_POLL_INTERVAL", 10)

os.environ.setdefault("KUBECONFIG", "/etc/kubernetes/admin.conf")


def kubectl(args, timeout=30):
    """Run kubectl and return (ok, stdout). Never raises."""
    try:
        proc = subprocess.run(
            ["kubectl"] + args, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return False, str(exc)
    if proc.returncode != 0:
        return False, (proc.stderr or proc.stdout).strip()
    return True, proc.stdout


def kubectl_json(args):
    ok, out = kubectl(args + ["-o", "json"])
    if not ok:
        return False, out
    try:
        return True, json.loads(out)
    except ValueError as exc:
        return False, "could not parse kubectl JSON: %s" % exc


# --------------------------------------------------------------------------
# S1: apiserver readiness
# --------------------------------------------------------------------------

def check_apiserver_ready():
    """Returns (ok, detail). /readyz aggregates every apiserver readiness gate."""
    ok, out = kubectl(["get", "--raw=/readyz"])
    if not ok:
        return False, "S1: /readyz not reachable: %s" % out
    body = out.strip()
    if body != "ok":
        return False, "S1: /readyz returned %r, expected 'ok'" % body[:200]
    return True, "S1: apiserver /readyz ok"


# --------------------------------------------------------------------------
# S2: services have endpoints
# --------------------------------------------------------------------------

def _endpoint_addresses(namespace, service):
    """Ready addresses backing a Service, via EndpointSlice.

    EndpointSlice rather than the older Endpoints API: Endpoints is deprecated
    and a slice carries per-address `conditions.ready`, so this counts addresses
    that are actually serving instead of merely listed.
    """
    ok, obj = kubectl_json([
        "get", "endpointslices", "-n", namespace,
        "-l", "kubernetes.io/service-name=%s" % service])
    if not ok:
        return None, obj

    addresses = []
    for slice_ in obj.get("items") or []:
        for endpoint in slice_.get("endpoints") or []:
            conditions = endpoint.get("conditions") or {}
            # `ready` absent means ready, per the EndpointSlice API.
            if conditions.get("ready", True):
                addresses.extend(endpoint.get("addresses") or [])
    return addresses, None


def check_service_endpoints():
    """Returns (ok, detail). An endpointless Service is a silently black-holed one."""
    failures, seen = [], []
    for namespace, service in (("default", "kubernetes"), ("kube-system", "kube-dns")):
        addresses, err = _endpoint_addresses(namespace, service)
        if addresses is None:
            failures.append("%s/%s: lookup failed: %s" % (namespace, service, err))
        elif not addresses:
            failures.append("%s/%s: no ready endpoints" % (namespace, service))
        else:
            seen.append("%s/%s=%d" % (namespace, service, len(addresses)))

    if failures:
        return False, "S2: %s" % "; ".join(failures)
    return True, "S2: service endpoints present (%s)" % ", ".join(seen)


# --------------------------------------------------------------------------
# S3: DNS actually resolves through the ClusterIP
# --------------------------------------------------------------------------

def _build_dns_query(query_id, name):
    """Minimal DNS A query. Hand-rolled to keep this dependency-free -- the
    master has a stock python3 and no guarantee of dnspython."""
    header = struct.pack(
        ">HHHHHH",
        query_id,
        0x0100,   # standard query, recursion desired
        1,        # QDCOUNT
        0, 0, 0,  # ANCOUNT, NSCOUNT, ARCOUNT
    )
    qname = b"".join(
        struct.pack("B", len(label)) + label.encode("ascii")
        for label in name.split(".") if label
    ) + b"\x00"
    return header + qname + struct.pack(">HH", 1, 1)  # QTYPE=A, QCLASS=IN


def _parse_dns_answer_count(payload, query_id):
    """Returns (answer_count, error). Only the header is parsed: the assertion is
    'CoreDNS answered authoritatively with at least one record', and decoding the
    RDATA would add failure modes without adding signal."""
    if len(payload) < 12:
        return None, "response too short (%d bytes)" % len(payload)
    resp_id, flags, _qd, ancount, _ns, _ar = struct.unpack(">HHHHHH", payload[:12])
    if resp_id != query_id:
        return None, "response id %d did not match query id %d" % (resp_id, query_id)
    if not flags & 0x8000:
        return None, "response was not marked as a response"
    rcode = flags & 0x000F
    if rcode != 0:
        return None, "DNS rcode %d (%s)" % (
            rcode, {1: "FORMERR", 2: "SERVFAIL", 3: "NXDOMAIN",
                    4: "NOTIMP", 5: "REFUSED"}.get(rcode, "unknown"))
    return ancount, None


def _kube_dns_cluster_ip():
    ok, obj = kubectl_json(["get", "svc", "-n", "kube-system", "kube-dns"])
    if not ok:
        return None, obj
    cluster_ip = (obj.get("spec") or {}).get("clusterIP")
    if not cluster_ip or cluster_ip == "None":
        return None, "kube-dns has no ClusterIP (got %r)" % cluster_ip
    return cluster_ip, None


def check_dns_resolves():
    """Returns (ok, detail).

    Queries the kube-dns ClusterIP from the master. The master is a cluster node,
    so kube-proxy's rules apply to it: reaching a ClusterIP at all proves service
    routing survived the upgrade, and getting an answer proves CoreDNS did too.
    """
    cluster_ip, err = _kube_dns_cluster_ip()
    if cluster_ip is None:
        return False, "S3: could not determine kube-dns ClusterIP: %s" % err

    query_id = random.randint(0, 0xFFFF)
    query = _build_dns_query(query_id, DNS_QUERY_NAME)

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(DNS_SOCKET_TIMEOUT)
    try:
        sock.sendto(query, (cluster_ip, DNS_PORT))
        payload, _ = sock.recvfrom(4096)
    except socket.timeout:
        return False, ("S3: no DNS response from %s:%d within %ds for %s "
                       "(kube-proxy service routing or CoreDNS)"
                       % (cluster_ip, DNS_PORT, DNS_SOCKET_TIMEOUT, DNS_QUERY_NAME))
    except OSError as exc:
        return False, "S3: DNS query to %s:%d failed: %s" % (cluster_ip, DNS_PORT, exc)
    finally:
        sock.close()

    ancount, err = _parse_dns_answer_count(payload, query_id)
    if ancount is None:
        return False, "S3: bad DNS response from %s for %s: %s" % (
            cluster_ip, DNS_QUERY_NAME, err)
    if ancount < 1:
        return False, "S3: %s resolved to 0 records via %s" % (DNS_QUERY_NAME, cluster_ip)
    return True, "S3: %s resolved via %s (%d record(s))" % (
        DNS_QUERY_NAME, cluster_ip, ancount)


# --------------------------------------------------------------------------

CHECKS = (
    ("S1", check_apiserver_ready),
    ("S2", check_service_endpoints),
    ("S3", check_dns_resolves),
)


def dump_diagnostics():
    """Best-effort. Must never change the exit code -- same contract as the
    health checker's dump: the cluster is destroyed minutes after this runs."""
    print("")
    print("================== SMOKE DIAGNOSTICS ====================")

    def show(title, args, timeout=60):
        print("--- %s ---" % title)
        try:
            ok, out = kubectl(args, timeout=timeout)
            print(out.rstrip() if ok else "(diagnostic failed: %s)" % out)
        except Exception as exc:  # noqa: BLE001 - diagnostics never propagate
            print("(diagnostic raised: %s)" % exc)

    show("kube-dns service", ["get", "svc", "-n", "kube-system", "kube-dns", "-o", "wide"])
    show("endpointslices (kube-system)", ["get", "endpointslices", "-n", "kube-system"])
    show("endpointslices (default)", ["get", "endpointslices", "-n", "default"])
    show("coredns pods", ["get", "pods", "-n", "kube-system", "-l", "k8s-app=kube-dns", "-o", "wide"])
    show("kube-proxy pods", ["get", "pods", "-n", "kube-system", "-l", "k8s-app=kube-proxy", "-o", "wide"])
    show("coredns logs (last 50)",
         ["logs", "-n", "kube-system", "-l", "k8s-app=kube-dns", "--tail=50"])
    show("kube-proxy logs (last 50)",
         ["logs", "-n", "kube-system", "-l", "k8s-app=kube-proxy", "--tail=50"])
    print("=========================================================")


def main():
    print("Smoke test starting: deadline %ds, retry every %ds"
          % (SMOKE_TIMEOUT, SMOKE_POLL_INTERVAL))

    started = time.time()
    deadline = started + SMOKE_TIMEOUT
    attempts = 0
    details = {}

    while True:
        attempts += 1
        elapsed = int(time.time() - started)

        failures = []
        for name, check in CHECKS:
            try:
                ok, detail = check()
            except Exception as exc:  # noqa: BLE001 - a raising check is a failing check
                ok, detail = False, "%s: raised %s: %s" % (name, type(exc).__name__, exc)
            details[name] = detail
            print("  %s  (elapsed %ds / %ds)" % (detail, elapsed, SMOKE_TIMEOUT))
            if not ok:
                failures.append(detail)

        if not failures:
            print("")
            print("======================= SMOKE ===========================")
            print("Result:   PASS")
            print("Duration: %ds over %d attempt(s)" % (int(time.time() - started), attempts))
            for name, _ in CHECKS:
                print("          %s" % details[name])
            print("=========================================================")
            return 0

        if time.time() >= deadline:
            print("")
            print("ERROR: smoke checks still failing after %ds." % SMOKE_TIMEOUT)
            dump_diagnostics()
            print("")
            print("======================= SMOKE ===========================")
            print("Result:   FAIL")
            print("Duration: %ds over %d attempt(s)" % (int(time.time() - started), attempts))
            print("Failing checks:")
            for failure in failures:
                print("  - %s" % failure)
            print("=========================================================")
            return 1

        remaining = int(deadline - time.time())
        print("  not fatal yet - retrying in %ds (%ds left before the deadline)"
              % (SMOKE_POLL_INTERVAL, remaining))
        time.sleep(min(SMOKE_POLL_INTERVAL, max(remaining, 1)))


if __name__ == "__main__":
    sys.exit(main())
