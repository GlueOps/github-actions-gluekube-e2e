#!/usr/bin/env python3
"""
waggle-nuke — Delete Waggle node pools whose name starts with a given prefix.

Lists node pools from the Waggle API, keeps only the ones whose `name` starts
with the prefix (default: "test-"), and deletes them with automatic retry
rounds. Anything outside the prefix is never touched.

Usage:
  # via environment variables
  export WAGGLE_BASE_URL=https://waggle.glueopshosted.rocks/api/v1
  export WAGGLE_TOKEN=...
  python waggle_nuke.py

  # via CLI flags
  python waggle_nuke.py --base-url https://... --token ... --name-prefix test-

  # dry-run (list only, don't delete)
  python waggle_nuke.py --dry-run
"""

from __future__ import annotations

import argparse
import logging
import os
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
log = logging.getLogger("waggle-nuke")

DEFAULT_BASE_URL = "https://waggle.glueopshosted.rocks/api/v1"
DEFAULT_NAME_PREFIX = "test-"


# ---------------------------------------------------------------------------
# Waggle API client  (list / delete only)
# ---------------------------------------------------------------------------

class WaggleClient:
    """Thin wrapper around the Waggle REST API — nuke operations only."""

    def __init__(self, base_url: str, token: str, *, timeout: int = 60) -> None:
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout
        self.session = requests.Session()
        self.session.headers.update({
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        })

    def _request(self, method: str, path: str, **kwargs: Any) -> requests.Response:
        url = f"{self.base_url}{path}"
        log.debug("%s %s", method.upper(), url)
        kwargs.setdefault("timeout", self.timeout)
        resp = self.session.request(method, url, **kwargs)
        log.debug("Response %s: %s", resp.status_code, resp.text[:500])
        return resp

    def list_pools(self) -> list[dict]:
        resp = self._request("GET", "/pools")
        resp.raise_for_status()
        return _as_pool_list(resp.json())

    def delete_pool(self, pool_id: str) -> None:
        resp = self._request("DELETE", f"/pools/{pool_id}")
        # A pool that vanished between list and delete is already the desired
        # end state, so it is not a failure worth retrying.
        if resp.status_code == 404:
            log.debug("  Pool %s already gone (404)", pool_id)
            return
        resp.raise_for_status()


def _as_pool_list(payload: Any) -> list[dict]:
    """Normalise the /pools payload to a list of dicts.

    The endpoint returns a bare JSON array, but tolerate the common
    envelope shapes ({"pools": [...]} / {"items": [...]} / {"data": [...]})
    so a server-side change doesn't silently nuke nothing.
    """
    if isinstance(payload, list):
        return [p for p in payload if isinstance(p, dict)]
    if isinstance(payload, dict):
        for key in ("pools", "items", "data", "results"):
            value = payload.get(key)
            if isinstance(value, list):
                return [p for p in value if isinstance(p, dict)]
    raise ValueError(f"Unexpected /pools payload type: {type(payload).__name__}")


# ---------------------------------------------------------------------------
# Nuke logic
# ---------------------------------------------------------------------------

def filter_pools(pools: list[dict], name_prefix: str) -> list[dict]:
    """Keep only pools whose name starts with `name_prefix`.

    Pools with no usable `name` are skipped: without a name there is no way to
    prove they are in scope, and deleting them could take out real clusters.
    """
    matched: list[dict] = []
    for pool in pools:
        pool_id = pool.get("id")
        name = pool.get("name")
        if not pool_id:
            log.warning("  Skipping pool with no id: %r", pool)
            continue
        if not isinstance(name, str) or not name:
            log.warning("  Skipping pool %s: no name to match against prefix", pool_id)
            continue
        if name.startswith(name_prefix):
            matched.append(pool)
    return matched


def _delete_pools(client: WaggleClient, pools: list[dict], *, dry_run: bool) -> int:
    """Attempt to delete each pool, return count of failures."""
    failures = 0
    for pool in pools:
        pool_id = pool["id"]
        display = f"{pool_id} ({pool['name']})"
        if dry_run:
            log.info("  [dry-run] Would delete node pool %s", display)
            continue
        try:
            client.delete_pool(pool_id)
            log.info("  Deleted node pool %s", display)
        except Exception as exc:
            log.warning("  Failed to delete node pool %s: %s", display, exc)
            failures += 1
    return failures


def nuke(
    client: WaggleClient,
    *,
    name_prefix: str = DEFAULT_NAME_PREFIX,
    max_rounds: int = 5,
    round_delay: int = 5,
    dry_run: bool = False,
) -> bool:
    """Delete every node pool whose name starts with `name_prefix`.

    Returns True if no matching pools remain, False otherwise.
    """
    for round_num in range(1, max_rounds + 1):
        log.info("--- Nuke round %d / %d ---", round_num, max_rounds)

        pools = client.list_pools()
        matched = filter_pools(pools, name_prefix)
        log.info(
            "  Node pools: total=%d  matching prefix %r=%d",
            len(pools), name_prefix, len(matched),
        )

        if not matched:
            log.info("No node pools match prefix %r — nothing to nuke.", name_prefix)
            return True

        failures = _delete_pools(client, matched, dry_run=dry_run)

        if dry_run:
            log.info("Dry run complete — no resources were modified.")
            return True

        if failures == 0:
            log.info("All %d matching node pool(s) deleted in round %d.", len(matched), round_num)
            return True

        if round_num < max_rounds:
            log.info(
                "Round %d had %d failure(s) — retrying in %ds ...",
                round_num, failures, round_delay,
            )
            time.sleep(round_delay)

    log.error("Nuke incomplete after %d round(s). Some node pools could not be deleted.", max_rounds)
    return False


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        prog="waggle-nuke",
        description="Delete Waggle node pools whose name starts with a given prefix.",
    )
    p.add_argument("--base-url",    default=None, help=f"Waggle API base URL   [env: WAGGLE_BASE_URL] (default: {DEFAULT_BASE_URL})")
    p.add_argument("--token",       default=None, help="Waggle bearer token    [env: WAGGLE_TOKEN]")
    p.add_argument("--name-prefix", default=None, help=f"Only delete pools whose name starts with this  [env: WAGGLE_NAME_PREFIX] (default: {DEFAULT_NAME_PREFIX!r})")
    p.add_argument("--max-rounds",  type=int, default=5, help="Max retry rounds (default: 5)")
    p.add_argument("--round-delay", type=int, default=5, help="Seconds between rounds (default: 5)")
    p.add_argument("--dry-run",     action="store_true", help="List node pools without deleting")
    p.add_argument("--verbose", "-v", action="store_true", help="Enable debug logging")
    return p.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)

    if args.verbose:
        logging.getLogger().setLevel(logging.DEBUG)

    base_url    = args.base_url    or os.environ.get("WAGGLE_BASE_URL")    or DEFAULT_BASE_URL
    token       = args.token       or os.environ.get("WAGGLE_TOKEN", "")
    name_prefix = args.name_prefix or os.environ.get("WAGGLE_NAME_PREFIX") or DEFAULT_NAME_PREFIX

    if not token:
        log.error("Missing required config: --token / WAGGLE_TOKEN")
        return 1
    # An empty prefix would match every pool in the org, including real
    # clusters — refuse rather than nuke everything.
    if not name_prefix.strip():
        log.error("--name-prefix / WAGGLE_NAME_PREFIX must not be empty")
        return 1

    log.info("waggle-nuke starting")
    log.info("  API: %s", base_url)
    log.info("  Name prefix: %r", name_prefix)
    log.info("  Dry run: %s", args.dry_run)
    log.info("  Max rounds: %d  Round delay: %ds", args.max_rounds, args.round_delay)

    client = WaggleClient(base_url, token)
    ok = nuke(
        client,
        name_prefix=name_prefix,
        max_rounds=args.max_rounds,
        round_delay=args.round_delay,
        dry_run=args.dry_run,
    )
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
