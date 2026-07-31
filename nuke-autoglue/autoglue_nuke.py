#!/usr/bin/env python3
"""
autoglue-nuke — Delete all resources in an AutoGlue organization.

Iterates through every resource type (clusters, node pools, servers,
load balancers, domains, record sets, SSH keys, labels, annotations,
taints) and deletes them in FK-safe order with automatic retry rounds.

Credentials are never deleted.

Usage:
  # via environment variables
  export AUTOGLUE_BASE_URL=https://autoglue.glueopshosted.rocks/api/v1
  export AUTOGLUE_ORG_KEY=...
  export AUTOGLUE_ORG_SECRET=...
  python autoglue_nuke.py

  # via CLI flags
  python autoglue_nuke.py --base-url https://... --org-key ... --org-secret ...

  # dry-run (list only, don't delete)
  python autoglue_nuke.py --dry-run
"""

from __future__ import annotations

import argparse
import logging
import sys
import time
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
log = logging.getLogger("autoglue-nuke")


# ---------------------------------------------------------------------------
# AutoGlue API client  (list / delete / detach only)
# ---------------------------------------------------------------------------

class AutoGlueClient:
    """Thin wrapper around the AutoGlue REST API — nuke operations only."""

    def __init__(self, base_url: str, org_key: str, org_secret: str) -> None:
        self.base_url = base_url.rstrip("/")
        self.session = requests.Session()
        self.session.headers.update({
            "X-ORG-KEY": org_key,
            "X-ORG-SECRET": org_secret,
            "Content-Type": "application/json",
        })

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

    def _delete(self, path: str, **kwargs: Any) -> requests.Response:
        return self._request("DELETE", path, **kwargs)

    # -- top-level resources --

    def list_clusters(self) -> list[dict]:
        resp = self._get("/clusters")
        resp.raise_for_status()
        return resp.json()

    def delete_cluster(self, cluster_id: str) -> None:
        resp = self._delete(f"/clusters/{cluster_id}")
        resp.raise_for_status()

    def list_node_pools(self) -> list[dict]:
        resp = self._get("/node-pools")
        resp.raise_for_status()
        return resp.json()

    def delete_node_pool(self, np_id: str) -> None:
        resp = self._delete(f"/node-pools/{np_id}")
        resp.raise_for_status()

    def list_servers(self) -> list[dict]:
        resp = self._get("/servers")
        resp.raise_for_status()
        return resp.json()

    def delete_server(self, server_id: str) -> None:
        resp = self._delete(f"/servers/{server_id}")
        resp.raise_for_status()

    def list_load_balancers(self) -> list[dict]:
        resp = self._get("/load-balancers")
        resp.raise_for_status()
        return resp.json()

    def delete_load_balancer(self, lb_id: str) -> None:
        resp = self._delete(f"/load-balancers/{lb_id}")
        resp.raise_for_status()

    def list_domains(self) -> list[dict]:
        resp = self._get("/dns/domains")
        resp.raise_for_status()
        return resp.json()

    def delete_domain(self, domain_id: str) -> None:
        resp = self._delete(f"/dns/domains/{domain_id}")
        resp.raise_for_status()

    def list_record_sets(self, domain_id: str) -> list[dict]:
        resp = self._get(f"/dns/domains/{domain_id}/records")
        resp.raise_for_status()
        return resp.json()

    def delete_record_set(self, record_id: str) -> None:
        resp = self._delete(f"/dns/records/{record_id}")
        resp.raise_for_status()

    def list_ssh_keys(self) -> list[dict]:
        resp = self._get("/ssh")
        resp.raise_for_status()
        return resp.json()

    def delete_ssh_key(self, key_id: str) -> None:
        resp = self._delete(f"/ssh/{key_id}")
        resp.raise_for_status()

    def list_labels(self) -> list[dict]:
        resp = self._get("/labels")
        resp.raise_for_status()
        return resp.json()

    def delete_label(self, label_id: str) -> None:
        resp = self._delete(f"/labels/{label_id}")
        resp.raise_for_status()

    def list_annotations(self) -> list[dict]:
        resp = self._get("/annotations")
        resp.raise_for_status()
        return resp.json()

    def delete_annotation(self, ann_id: str) -> None:
        resp = self._delete(f"/annotations/{ann_id}")
        resp.raise_for_status()

    def list_taints(self) -> list[dict]:
        resp = self._get("/taints")
        resp.raise_for_status()
        return resp.json()

    def delete_taint(self, taint_id: str) -> None:
        resp = self._delete(f"/taints/{taint_id}")
        resp.raise_for_status()

    # -- node-pool sub-resource detach --

    def list_node_pool_labels(self, np_id: str) -> list[dict]:
        resp = self._get(f"/node-pools/{np_id}/labels")
        resp.raise_for_status()
        return resp.json()

    def detach_node_pool_label(self, np_id: str, label_id: str) -> None:
        resp = self._delete(f"/node-pools/{np_id}/labels/{label_id}")
        resp.raise_for_status()

    def list_node_pool_annotations(self, np_id: str) -> list[dict]:
        resp = self._get(f"/node-pools/{np_id}/annotations")
        resp.raise_for_status()
        return resp.json()

    def detach_node_pool_annotation(self, np_id: str, ann_id: str) -> None:
        resp = self._delete(f"/node-pools/{np_id}/annotations/{ann_id}")
        resp.raise_for_status()

    def list_node_pool_taints(self, np_id: str) -> list[dict]:
        resp = self._get(f"/node-pools/{np_id}/taints")
        resp.raise_for_status()
        return resp.json()

    def detach_node_pool_taint(self, np_id: str, taint_id: str) -> None:
        resp = self._delete(f"/node-pools/{np_id}/taints/{taint_id}")
        resp.raise_for_status()

    def list_node_pool_servers(self, np_id: str) -> list[dict]:
        resp = self._get(f"/node-pools/{np_id}/servers")
        resp.raise_for_status()
        return resp.json()

    def detach_node_pool_server(self, np_id: str, server_id: str) -> None:
        resp = self._delete(f"/node-pools/{np_id}/servers/{server_id}")
        resp.raise_for_status()


# ---------------------------------------------------------------------------
# Nuke logic
# ---------------------------------------------------------------------------

def _safe_action(label: str, items: list[dict], action_fn, *, dry_run: bool) -> int:
    """Attempt an action on each item, return count of failures."""
    failures = 0
    for item in items:
        rid = item["id"]
        name = item.get("name", item.get("key", ""))
        display = f"{rid} ({name})" if name else rid
        if dry_run:
            log.info("  [dry-run] Would delete %s %s", label, display)
            continue
        try:
            action_fn(rid)
            log.info("  Deleted %s %s", label, display)
        except Exception as exc:
            log.warning("  Failed to delete %s %s: %s", label, display, exc)
            failures += 1
    return failures


def _detach_node_pool_sub_resources(
    client: AutoGlueClient,
    node_pools: list[dict],
    *,
    dry_run: bool,
) -> int:
    """Detach labels, annotations, taints, and servers from all node pools."""
    failures = 0
    sub_types = [
        ("label",      client.list_node_pool_labels,      client.detach_node_pool_label),
        ("annotation", client.list_node_pool_annotations,  client.detach_node_pool_annotation),
        ("taint",      client.list_node_pool_taints,       client.detach_node_pool_taint),
        ("server",     client.list_node_pool_servers,      client.detach_node_pool_server),
    ]
    for np in node_pools:
        np_id = np["id"]
        for type_name, list_fn, detach_fn in sub_types:
            try:
                items = list_fn(np_id)
            except Exception as exc:
                log.warning("  Failed to list %ss for node_pool %s: %s", type_name, np_id, exc)
                continue
            for item in items:
                item_id = item["id"]
                if dry_run:
                    log.info("  [dry-run] Would detach %s %s from node_pool %s", type_name, item_id, np_id)
                    continue
                try:
                    detach_fn(np_id, item_id)
                    log.info("  Detached %s %s from node_pool %s", type_name, item_id, np_id)
                except Exception as exc:
                    log.warning("  Failed to detach %s %s from node_pool %s: %s", type_name, item_id, np_id, exc)
                    failures += 1
    return failures


def nuke(
    client: AutoGlueClient,
    *,
    max_rounds: int = 5,
    round_delay: int = 5,
    dry_run: bool = False,
) -> bool:
    """Delete every resource in the org (except credentials).

    Returns True if the org is clean, False if resources remain.
    """
    for round_num in range(1, max_rounds + 1):
        log.info("--- Nuke round %d / %d ---", round_num, max_rounds)

        # 1. List everything
        clusters = client.list_clusters()
        node_pools = client.list_node_pools()
        domains = client.list_domains()
        servers = client.list_servers()
        load_balancers = client.list_load_balancers()
        ssh_keys = client.list_ssh_keys()
        labels = client.list_labels()
        annotations = client.list_annotations()
        taints = client.list_taints()

        record_sets: list[dict] = []
        for dom in domains:
            try:
                record_sets.extend(client.list_record_sets(dom["id"]))
            except Exception as exc:
                log.warning("  Failed to list record sets for domain %s: %s", dom["id"], exc)

        total = (
            len(clusters) + len(node_pools) + len(record_sets)
            + len(servers) + len(load_balancers) + len(domains)
            + len(ssh_keys) + len(labels) + len(annotations) + len(taints)
        )
        log.info(
            "  Resources: clusters=%d  node_pools=%d  record_sets=%d  "
            "servers=%d  load_balancers=%d  domains=%d  ssh_keys=%d  "
            "labels=%d  annotations=%d  taints=%d  (total=%d)",
            len(clusters), len(node_pools), len(record_sets),
            len(servers), len(load_balancers), len(domains), len(ssh_keys),
            len(labels), len(annotations), len(taints), total,
        )

        if total == 0:
            log.info("Org is clean — nothing to nuke.")
            return True

        if dry_run:
            log.info("  [dry-run] Listing resources that would be deleted:")

        # 2. Detach join-table relationships from node pools
        failures = _detach_node_pool_sub_resources(client, node_pools, dry_run=dry_run)

        # 3. Delete in FK-safe order
        failures += _safe_action("cluster",       clusters,       client.delete_cluster,       dry_run=dry_run)
        failures += _safe_action("node_pool",     node_pools,     client.delete_node_pool,     dry_run=dry_run)
        failures += _safe_action("record_set",    record_sets,    client.delete_record_set,    dry_run=dry_run)
        failures += _safe_action("server",        servers,        client.delete_server,        dry_run=dry_run)
        failures += _safe_action("load_balancer", load_balancers, client.delete_load_balancer, dry_run=dry_run)
        failures += _safe_action("domain",        domains,        client.delete_domain,        dry_run=dry_run)
        failures += _safe_action("ssh_key",       ssh_keys,       client.delete_ssh_key,       dry_run=dry_run)
        failures += _safe_action("label",         labels,         client.delete_label,         dry_run=dry_run)
        failures += _safe_action("annotation",    annotations,    client.delete_annotation,    dry_run=dry_run)
        failures += _safe_action("taint",         taints,         client.delete_taint,         dry_run=dry_run)

        if dry_run:
            log.info("Dry run complete — no resources were modified.")
            return True

        if failures == 0:
            log.info("All resources deleted in round %d.", round_num)
            return True

        if round_num < max_rounds:
            log.info(
                "Round %d had %d failure(s) — retrying in %ds ...",
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
        prog="autoglue-nuke",
        description="Delete all resources in an AutoGlue organization (except credentials).",
    )
    p.add_argument("--base-url",    default=None, help="AutoGlue API base URL  [env: AUTOGLUE_BASE_URL]")
    p.add_argument("--org-key",     default=None, help="Org API key            [env: AUTOGLUE_ORG_KEY]")
    p.add_argument("--org-secret",  default=None, help="Org API secret         [env: AUTOGLUE_ORG_SECRET]")
    p.add_argument("--max-rounds",  type=int, default=5,  help="Max retry rounds (default: 5)")
    p.add_argument("--round-delay", type=int, default=5,  help="Seconds between rounds (default: 5)")
    p.add_argument("--dry-run",     action="store_true",  help="List resources without deleting")
    p.add_argument("--verbose", "-v", action="store_true", help="Enable debug logging")
    return p.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)

    if args.verbose:
        logging.getLogger().setLevel(logging.DEBUG)

    import os
    base_url   = args.base_url   or os.environ.get("AUTOGLUE_BASE_URL", "")
    org_key    = args.org_key    or os.environ.get("AUTOGLUE_ORG_KEY", "")
    org_secret = args.org_secret or os.environ.get("AUTOGLUE_ORG_SECRET", "")

    missing = []
    if not base_url:
        missing.append("--base-url / AUTOGLUE_BASE_URL")
    if not org_key:
        missing.append("--org-key / AUTOGLUE_ORG_KEY")
    if not org_secret:
        missing.append("--org-secret / AUTOGLUE_ORG_SECRET")
    if missing:
        log.error("Missing required config: %s", ", ".join(missing))
        return 1

    log.info("autoglue-nuke starting")
    log.info("  API: %s", base_url)
    log.info("  Dry run: %s", args.dry_run)
    log.info("  Max rounds: %d  Round delay: %ds", args.max_rounds, args.round_delay)

    client = AutoGlueClient(base_url, org_key, org_secret)
    ok = nuke(
        client,
        max_rounds=args.max_rounds,
        round_delay=args.round_delay,
        dry_run=args.dry_run,
    )
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
