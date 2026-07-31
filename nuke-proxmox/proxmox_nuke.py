#!/usr/bin/env python3
"""
proxmox-nuke — Delete all Proxmox resources belonging to a GlueKube cluster.

Backstop cleanup for when `tofu destroy` fails partway and orphans Proxmox VMs
and cloud-init snippet files with no way to remove them from state. It talks to
the Proxmox VE API directly and deletes, for a single cluster:

  - every QEMU VM tagged with the cluster name (stopping it first if running);
    deleting a VM also removes any firewall rules attached to it, and
  - every cloud-init snippet file named "<cluster>-*" in the `local` datastore.

Resources are matched by the cluster name that the module stamps on them:
VMs carry it as their first tag (e.g. tags = [cluster, "bastion"]) and snippet
filenames are prefixed "<cluster>-". Nothing else is touched — an empty cluster
name is refused so the filter can never match everything.

Credentials are never deleted; only VMs and snippet files are removed.

Usage:
  # via environment variables
  export PROXMOX_ENDPOINT=https://pve-api.example.com:8006
  export PROXMOX_API_TOKEN='root@pam!tokenid=<secret>'
  export PROXMOX_CLUSTER_NAME=dev.example.rocks
  export PROXMOX_INSECURE=true          # optional, skip TLS verification
  python proxmox_nuke.py

  # via CLI flags
  python proxmox_nuke.py --endpoint https://... --api-token '...' \
      --cluster-name dev.example.rocks --insecure

  # dry-run (list only, don't delete)
  python proxmox_nuke.py --dry-run

  # in CI, pass the whole provider_credentials object (JSON or HCL) instead of the
  # individual endpoint/token/insecure vars:
  export PROXMOX_PROVIDER_CREDENTIALS="$PROVIDER_CREDENTIALS"
  export PROXMOX_CLUSTER_NAME=dev.example.rocks
  python proxmox_nuke.py
"""

from __future__ import annotations

import argparse
import json
import logging
import re
import sys
import time
import urllib.parse
from typing import Any

import requests

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

LOG_FORMAT = "%(asctime)s [%(levelname)s] %(message)s"
logging.basicConfig(
    level=logging.INFO,
    format=LOG_FORMAT,
    datefmt="%Y-%m-%d %H:%M:%S",
    handlers=[logging.StreamHandler(sys.stdout)],
)
log = logging.getLogger("proxmox-nuke")


# ---------------------------------------------------------------------------
# Proxmox VE API client  (list / stop / delete only)
# ---------------------------------------------------------------------------

class ProxmoxClient:
    """Thin wrapper around the Proxmox VE REST API — nuke operations only."""

    def __init__(self, endpoint: str, api_token: str, *, insecure: bool = False) -> None:
        base = endpoint.rstrip("/")
        # Accept either a bare host URL or one already ending in the API path.
        if not base.endswith("/api2/json"):
            base = f"{base}/api2/json"
        self.base_url = base

        self.session = requests.Session()
        # api_token is the full "user@realm!tokenid=secret" string from
        # provider_credentials.api_token; Proxmox expects it after "PVEAPIToken=".
        self.session.headers.update({
            "Authorization": f"PVEAPIToken={api_token}",
            "Content-Type": "application/json",
        })
        self.session.verify = not insecure
        if insecure:
            # The dev hypervisor uses a self-signed cert (insecure = true); silence
            # the per-request InsecureRequestWarning rather than spam the log.
            requests.packages.urllib3.disable_warnings()  # type: ignore[attr-defined]

    def _url(self, path: str) -> str:
        return f"{self.base_url}{path}"

    def _request(self, method: str, path: str, **kwargs: Any) -> requests.Response:
        url = self._url(path)
        log.debug("%s %s", method.upper(), url)
        resp = self.session.request(method, url, **kwargs)
        log.debug("Response %s: %s", resp.status_code, resp.text[:500])
        return resp

    def _get(self, path: str, **kwargs: Any) -> requests.Response:
        return self._request("GET", path, **kwargs)

    def _post(self, path: str, **kwargs: Any) -> requests.Response:
        return self._request("POST", path, **kwargs)

    def _delete(self, path: str, **kwargs: Any) -> requests.Response:
        return self._request("DELETE", path, **kwargs)

    # -- VMs --

    def list_vms(self) -> list[dict]:
        """Every QEMU VM across the cluster, with node/vmid/name/status/tags."""
        resp = self._get("/cluster/resources", params={"type": "vm"})
        resp.raise_for_status()
        return resp.json()["data"]

    def stop_vm(self, node: str, vmid: int) -> None:
        resp = self._post(f"/nodes/{node}/qemu/{vmid}/status/stop")
        resp.raise_for_status()

    def delete_vm(self, node: str, vmid: int) -> None:
        # purge: also remove from HA/backup/replication config.
        # destroy-unreferenced-disks: drop disks not referenced in the VM config.
        resp = self._delete(
            f"/nodes/{node}/qemu/{vmid}",
            params={"purge": 1, "destroy-unreferenced-disks": 1},
        )
        resp.raise_for_status()

    # -- nodes & snippet files --

    def list_nodes(self) -> list[dict]:
        resp = self._get("/nodes")
        resp.raise_for_status()
        return resp.json()["data"]

    def list_snippets(self, node: str) -> list[dict]:
        resp = self._get(
            f"/nodes/{node}/storage/local/content",
            params={"content": "snippets"},
        )
        resp.raise_for_status()
        return resp.json()["data"]

    def delete_content(self, node: str, volid: str) -> None:
        encoded = urllib.parse.quote(volid, safe="")
        resp = self._delete(f"/nodes/{node}/storage/local/content/{encoded}")
        resp.raise_for_status()


# ---------------------------------------------------------------------------
# Matching helpers
# ---------------------------------------------------------------------------

def _vm_matches(vm: dict, cluster: str) -> bool:
    """True if the VM carries `cluster` as one of its tags.

    Exact membership on the ";"-separated tag string — never a substring match,
    so cluster "dev" does not match a VM tagged "dev2".
    """
    tags = (vm.get("tags") or "").split(";")
    return cluster in tags


def parse_provider_credentials(raw: str) -> dict[str, str]:
    """Extract the scalar fields we need from a provider_credentials blob.

    The blob is the whole `provider_credentials` object as stored in the
    PROVIDER_CREDENTIALS secret. It may be JSON (`"endpoint": "..."`) or the HCL
    object form used in .tfvars (`endpoint = "..."`) — both are valid values for
    TF_VAR_provider_credentials, so we accept either. Only endpoint / api_token /
    insecure are read; the multi-line private_key (unused for API access) is ignored.
    """
    try:
        data = json.loads(raw)
        if isinstance(data, dict):
            return {k: str(v) for k, v in data.items()}
    except (ValueError, TypeError):
        pass

    # HCL / tfvars fallback: match `key = "value"` or `key: value` on scalar lines.
    out: dict[str, str] = {}
    for field in ("endpoint", "api_token", "insecure"):
        m = re.search(rf'^\s*{field}\s*[:=]\s*"?([^"\n]+?)"?\s*$', raw, re.MULTILINE)
        if m:
            out[field] = m.group(1).strip()
    return out


def _snippet_matches(volid: str, cluster: str) -> bool:
    """True if the snippet's filename starts with "<cluster>-".

    volid looks like "local:snippets/<cluster>-bastion-cloud-init.yaml". The
    trailing hyphen keeps cluster "dev" from matching "dev2-..." filenames.
    """
    filename = volid.split("/", 1)[-1]
    return filename.startswith(f"{cluster}-")


# ---------------------------------------------------------------------------
# Nuke logic
# ---------------------------------------------------------------------------

def _delete_vms(client: ProxmoxClient, vms: list[dict], *, dry_run: bool) -> int:
    """Stop/delete matched VMs. Returns count of not-yet-deleted VMs.

    A running VM is stopped this round but not deleted (Proxmox rejects deleting a
    running VM); it counts as pending so a retry round follows once it has stopped.
    """
    pending = 0
    for vm in vms:
        vmid = vm["vmid"]
        node = vm["node"]
        name = vm.get("name", "")
        display = f"{vmid} ({name}) on {node}" if name else f"{vmid} on {node}"

        if dry_run:
            log.info("  [dry-run] Would delete VM %s", display)
            continue

        status = vm.get("status", "")
        try:
            if status == "running":
                client.stop_vm(node, vmid)
                log.info("  Stopping VM %s (will delete next round)", display)
                pending += 1
            else:
                client.delete_vm(node, vmid)
                log.info("  Deleted VM %s", display)
        except Exception as exc:
            log.warning("  Failed to remove VM %s: %s", display, exc)
            pending += 1
    return pending


def _delete_snippets(
    client: ProxmoxClient,
    snippets: list[tuple[str, str]],
    *,
    dry_run: bool,
) -> int:
    """Delete matched snippet files. `snippets` is a list of (node, volid)."""
    failures = 0
    for node, volid in snippets:
        display = f"{volid} on {node}"
        if dry_run:
            log.info("  [dry-run] Would delete snippet %s", display)
            continue
        try:
            client.delete_content(node, volid)
            log.info("  Deleted snippet %s", display)
        except Exception as exc:
            log.warning("  Failed to delete snippet %s: %s", display, exc)
            failures += 1
    return failures


def nuke(
    client: ProxmoxClient,
    cluster: str,
    *,
    max_rounds: int = 5,
    round_delay: int = 10,
    dry_run: bool = False,
) -> bool:
    """Delete every Proxmox resource belonging to `cluster`.

    Returns True if nothing remains, False if resources could not be removed.
    """
    for round_num in range(1, max_rounds + 1):
        log.info("--- Nuke round %d / %d ---", round_num, max_rounds)

        # 1. List and filter VMs by tag.
        vms = [vm for vm in client.list_vms() if _vm_matches(vm, cluster)]

        # 2. List and filter snippets by filename prefix, per node.
        snippets: list[tuple[str, str]] = []
        for node in client.list_nodes():
            node_name = node["node"]
            try:
                for item in client.list_snippets(node_name):
                    volid = item["volid"]
                    if _snippet_matches(volid, cluster):
                        snippets.append((node_name, volid))
            except Exception as exc:
                log.warning("  Failed to list snippets on node %s: %s", node_name, exc)

        total = len(vms) + len(snippets)
        log.info("  Resources: vms=%d  snippets=%d  (total=%d)", len(vms), len(snippets), total)

        if total == 0:
            log.info("Cluster %s is clean — nothing to nuke.", cluster)
            return True

        if dry_run:
            log.info("  [dry-run] Listing resources that would be deleted:")
            _delete_vms(client, vms, dry_run=True)
            _delete_snippets(client, snippets, dry_run=True)
            log.info("Dry run complete — no resources were modified.")
            return True

        # 3. Delete VMs (removes their firewall rules too), then snippets.
        failures = _delete_vms(client, vms, dry_run=False)
        failures += _delete_snippets(client, snippets, dry_run=False)

        if failures == 0:
            log.info("All resources deleted in round %d.", round_num)
            return True

        if round_num < max_rounds:
            log.info(
                "Round %d had %d resource(s) still pending — retrying in %ds ...",
                round_num, failures, round_delay,
            )
            time.sleep(round_delay)

    log.error("Nuke incomplete after %d round(s). Some resources could not be deleted.", max_rounds)
    return False


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        prog="proxmox-nuke",
        description="Delete all Proxmox resources belonging to a GlueKube cluster.",
    )
    p.add_argument("--endpoint",     default=None, help="Proxmox API endpoint    [env: PROXMOX_ENDPOINT]")
    p.add_argument("--api-token",    default=None, help="API token user@realm!id=secret [env: PROXMOX_API_TOKEN]")
    p.add_argument("--cluster-name", default=None, help="Cluster name to match   [env: PROXMOX_CLUSTER_NAME]")
    p.add_argument("--insecure",     action="store_true", help="Skip TLS verification [env: PROXMOX_INSECURE]")
    p.add_argument("--max-rounds",   type=int, default=5,  help="Max retry rounds (default: 5)")
    p.add_argument("--round-delay",  type=int, default=10, help="Seconds between rounds (default: 10)")
    p.add_argument("--dry-run",      action="store_true",  help="List resources without deleting")
    p.add_argument("--verbose", "-v", action="store_true", help="Enable debug logging")
    return p.parse_args(argv)


def _env_truthy(value: str) -> bool:
    return value.strip().lower() in ("1", "true", "yes", "on")


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)

    if args.verbose:
        logging.getLogger().setLevel(logging.DEBUG)

    import os
    endpoint  = args.endpoint     or os.environ.get("PROXMOX_ENDPOINT", "")
    api_token = args.api_token    or os.environ.get("PROXMOX_API_TOKEN", "")
    cluster   = args.cluster_name or os.environ.get("PROXMOX_CLUSTER_NAME", "")
    insecure  = args.insecure     or _env_truthy(os.environ.get("PROXMOX_INSECURE", ""))

    # Convenience for CI: rather than plumb three separate secrets, accept the whole
    # provider_credentials object (JSON or HCL) and fill in anything not set above.
    raw_creds = os.environ.get("PROXMOX_PROVIDER_CREDENTIALS", "")
    if raw_creds:
        creds = parse_provider_credentials(raw_creds)
        endpoint  = endpoint  or creds.get("endpoint", "")
        api_token = api_token or creds.get("api_token", "")
        insecure  = insecure  or _env_truthy(creds.get("insecure", ""))

    missing = []
    if not endpoint:
        missing.append("--endpoint / PROXMOX_ENDPOINT")
    if not api_token:
        missing.append("--api-token / PROXMOX_API_TOKEN")
    # cluster is required: an empty filter must never be allowed to match everything.
    if not cluster:
        missing.append("--cluster-name / PROXMOX_CLUSTER_NAME")
    if missing:
        log.error("Missing required config: %s", ", ".join(missing))
        return 1

    log.info("proxmox-nuke starting")
    log.info("  API: %s", endpoint)
    log.info("  Cluster: %s", cluster)
    log.info("  Insecure TLS: %s", insecure)
    log.info("  Dry run: %s", args.dry_run)
    log.info("  Max rounds: %d  Round delay: %ds", args.max_rounds, args.round_delay)

    client = ProxmoxClient(endpoint, api_token, insecure=insecure)
    ok = nuke(
        client,
        cluster,
        max_rounds=args.max_rounds,
        round_delay=args.round_delay,
        dry_run=args.dry_run,
    )
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
