"""Unit tests for reconcile helpers.

Pure functions only — no network, no iptables. Run under the image
(`docker run --rm -v <repo>/fw-sidecar:/src -w /src fw-sidecar-test
python3 -m pytest tests/`) or any host with python3 + pyyaml.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import reconcile  # noqa: E402

FIXTURES = Path(__file__).parent / "fixtures"
SAMPLE = FIXTURES / "sample-allowlist.yaml"


@pytest.fixture
def sample():
    return reconcile.parse_allowlist(SAMPLE)


# --- parse_allowlist ---------------------------------------------------

def test_parse_splits_wildcard_from_exact(sample):
    assert "example.com" in sample.exact_domains
    assert "api.example.com" in sample.exact_domains
    assert "*.wildcard.example.com" not in sample.exact_domains
    assert "wildcard.example.com" in sample.wildcard_suffixes


def test_parse_extracts_cidrs(sample):
    assert "192.0.2.0/24" in sample.cidrs_v4
    assert "2001:db8::/32" in sample.cidrs_v6


def test_parse_port_overrides(sample):
    assert sample.default_ports == [443]
    assert sample.port_overrides["example.com"] == [22, 443]


def test_parse_union_of_all_ports(sample):
    # Firewall chain needs the union of every port that could be used.
    assert sorted(sample.all_ports()) == [22, 443]


# --- build_ipset_members ----------------------------------------------

def test_build_ipset_members_wildcards_have_no_ips():
    """CRITICAL: wildcards must not contribute IPs to the ipset."""
    s = reconcile.parse_allowlist(SAMPLE)
    # Use a stub resolver: only resolve exact domains.
    def resolve(name, rtype):
        return {"example.com": ["93.184.216.34"],
                "api.example.com": ["93.184.216.35"]}.get(name, []) if rtype == "A" else []
    members = reconcile.build_ipset_members(s, resolve)
    assert "93.184.216.34" in members["v4"]
    assert "93.184.216.35" in members["v4"]
    # CIDRs from cidrs: section
    assert "192.0.2.0/24" in members["v4"]
    assert "2001:db8::/32" in members["v6"]
    # Wildcard base MUST NOT appear
    assert "wildcard.example.com" not in members["v4"]
    # Stub returned nothing for wildcard suffix — verify resolver was
    # never asked about it
    assert not any("wildcard" in m for m in members["v4"])


# --- build_unbound_conf ------------------------------------------------

def test_unbound_conf_is_default_refuse(sample):
    conf = reconcile.build_unbound_conf(sample, upstream="1.1.1.1",
                                        upstream_tls=False)
    assert 'local-zone: "." refuse' in conf


def test_unbound_conf_has_forward_zones_for_exact_and_wildcard(sample):
    conf = reconcile.build_unbound_conf(sample, upstream="1.1.1.1",
                                        upstream_tls=False)
    # Exact domains get forward-zones so unbound will actually answer
    # for them (the default-refuse would otherwise drop them).
    assert 'name: "example.com."' in conf
    # Wildcard: the BASE SUFFIX is the zone; subdomains inherit.
    assert 'name: "wildcard.example.com."' in conf


def test_unbound_conf_transparent_local_zones_override_root_refuse(sample):
    """Without `local-zone: <name> transparent`, unbound's root-refuse
    would shadow our forward-zones and every query returns REFUSED.
    Regression test for that exact bug."""
    conf = reconcile.build_unbound_conf(sample, upstream="1.1.1.1",
                                        upstream_tls=False)
    assert 'local-zone: "example.com." transparent' in conf
    assert 'local-zone: "wildcard.example.com." transparent' in conf


def test_unbound_conf_dot_switches_port_and_tls(sample):
    conf = reconcile.build_unbound_conf(sample, upstream="1.1.1.1",
                                        upstream_tls=True)
    assert "forward-tls-upstream: yes" in conf
    assert "1.1.1.1@853" in conf


def test_unbound_conf_no_dot_uses_port_53(sample):
    conf = reconcile.build_unbound_conf(sample, upstream="1.1.1.1",
                                        upstream_tls=False)
    assert "forward-tls-upstream: yes" not in conf
    assert "forward-addr: 1.1.1.1@53" in conf


# --- dry run JSON ------------------------------------------------------

def test_dry_run_emits_parseable_json(tmp_path):
    out = subprocess.run(
        [sys.executable, str(Path(__file__).parent.parent / "reconcile.py"),
         "--dry-run", "--config", str(SAMPLE),
         "--upstream", "1.1.1.1"],
        check=True, capture_output=True, text=True,
        env={**os.environ, "RECONCILE_STUB_RESOLVER": "1"},
    )
    data = json.loads(out.stdout)
    for key in ("unbound_conf", "ipset_v4", "ipset_v6", "ports"):
        assert key in data, f"missing key: {key}"
    assert 443 in data["ports"]["default"]
    assert data["ports"]["overrides"]["example.com"] == [22, 443]


# --- retry semantics ---------------------------------------------------

def test_retry_partial_success_exit_code_2():
    """Partial success: exit code 2 (not 0 — distinguishable from all-ok)."""
    def flaky(name, rtype):
        if name == "example.com":
            return ["1.2.3.4"] if rtype == "A" else []
        raise reconcile.ResolveError(f"upstream refused {name}")

    s = reconcile.parse_allowlist(SAMPLE)
    res = reconcile.resolve_all(s, flaky, max_attempts=3, backoff_base=0)
    assert "example.com" in res.succeeded
    assert "api.example.com" in res.failed
    assert res.exit_code() == 2


def test_retry_all_success_exit_code_0():
    def all_ok(name, rtype):
        return ["1.2.3.4"] if rtype == "A" else ["::1"]

    s = reconcile.parse_allowlist(SAMPLE)
    res = reconcile.resolve_all(s, all_ok, max_attempts=1, backoff_base=0)
    assert not res.failed
    assert res.exit_code() == 0


def test_retry_total_failure_exit_code_1():
    def never(name, rtype):
        raise reconcile.ResolveError("nope")

    s = reconcile.parse_allowlist(SAMPLE)
    res = reconcile.resolve_all(s, never, max_attempts=2, backoff_base=0)
    assert not res.succeeded
    assert res.exit_code() == 1


def test_retry_records_per_rtype_failure_when_other_rtype_succeeds(caplog):
    """Regression: A record fails but AAAA succeeds — the domain must
    still be marked succeeded, but the missing rtype must be logged.
    Earlier implementation cleared `last_err` on AAAA success, hiding
    the A-record failure entirely."""
    def rtype_selective(name, rtype):
        if rtype == "A":
            raise reconcile.ResolveError("A always fails")
        return ["2001:db8::1"]

    s = reconcile.parse_allowlist(SAMPLE)
    import logging
    caplog.set_level(logging.WARNING, logger="reconcile")
    res = reconcile.resolve_all(s, rtype_selective,
                                max_attempts=2, backoff_base=0)
    # Both domains should be in succeeded (AAAA worked)
    assert "example.com" in res.succeeded
    assert "api.example.com" in res.succeeded
    assert not res.failed
    # But A-record failures must be surfaced in logs
    msgs = [r.getMessage() for r in caplog.records]
    assert any("example.com A exhausted retries" in m for m in msgs)


def test_retry_honors_max_attempts():
    """Retries exactly N times per domain.

    Sample fixture: 2 exact domains (example.com, api.example.com) +
    1 wildcard (*.wildcard.example.com). Wildcards are never resolved,
    so the count is 2 exact × 2 rtypes (A + AAAA) × 3 attempts = 12.
    """
    attempts = []

    def counting(name, rtype):
        attempts.append((name, rtype))
        raise reconcile.ResolveError("fail")

    s = reconcile.parse_allowlist(SAMPLE)
    reconcile.resolve_all(s, counting, max_attempts=3, backoff_base=0)
    assert len(attempts) == 12


# --- dig output parsing -----------------------------------------------

def test_parse_dig_output_filters_comments():
    """Operator-precedence-safe: comment lines containing ':' must not
    leak through the filter (AAAA `dig` output can include them)."""
    sample = """\
; <<>> DiG 9.18.44 <<>> @1.1.1.1 github.com AAAA
;; global options: +cmd
2606:50c0:8000::154
2606:50c0:8001::154
"""
    assert reconcile.parse_dig_output(sample) == [
        "2606:50c0:8000::154", "2606:50c0:8001::154",
    ]


def test_parse_dig_output_strips_cname_hostnames():
    """CNAME chains appear as bare hostnames with trailing dots. Drop
    them — including ones with digits in labels (e.g. CloudFront)."""
    sample = (
        "example.cdn.net.\n"
        "dks7yomi95k2d.cloudfront.net.\n"   # digits in hostname
        "93.184.216.34\n"
    )
    assert reconcile.parse_dig_output(sample) == ["93.184.216.34"]


def test_valid_member_rejects_hostnames_and_cross_family():
    assert reconcile._valid_member("1.2.3.4", v6=False)
    assert reconcile._valid_member("192.0.2.0/24", v6=False)
    assert not reconcile._valid_member("2001:db8::1", v6=False)  # v6 in v4 set
    assert reconcile._valid_member("2001:db8::1", v6=True)
    assert not reconcile._valid_member("example.com", v6=False)
    assert not reconcile._valid_member("foo.bar.", v6=False)


def test_parse_dig_output_empty():
    assert reconcile.parse_dig_output("") == []
    assert reconcile.parse_dig_output("\n\n") == []


# --- write_unbound_conf idempotency -----------------------------------

def test_write_unbound_conf_idempotent(tmp_path):
    target = tmp_path / "allowlist.conf"
    assert reconcile.write_unbound_conf("hello\n", target) is True
    assert target.read_text() == "hello\n"
    # Same content → False
    assert reconcile.write_unbound_conf("hello\n", target) is False
    # Different content → True
    assert reconcile.write_unbound_conf("world\n", target) is True
    assert target.read_text() == "world\n"


def test_write_unbound_conf_uses_tmp_rename(tmp_path):
    target = tmp_path / "allowlist.conf"
    reconcile.write_unbound_conf("body\n", target)
    # No *.tmp left behind after a clean write.
    assert not list(tmp_path.glob("*.tmp"))
