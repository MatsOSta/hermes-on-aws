#!/usr/bin/env python3
import importlib.util
import os
import stat
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HELPER = Path(__file__).resolve().parents[1] / "scripts/support/configure-cloudflare-tunnel.py"
ACCOUNT = "a" * 32
ZONE = "b" * 32
TUNNEL = "11111111-2222-4333-8444-555555555555"
DEPLOYMENT = "hms-abcdef123456"
HOST = "edge-0123456789ab.example.com"


class FakeAPI:
    def __init__(self, replies):
        self.replies = list(replies)
        self.calls = []

    def request(self, method, path, body=None, query=None):
        self.calls.append((method, path, body, query))
        if not self.replies:
            raise AssertionError(f"unexpected call: {method} {path}")
        return self.replies.pop(0)


class ConfigureTunnelTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("configure_tunnel", HELPER)
        if spec is None or spec.loader is None:
            raise RuntimeError("unable to load helper")
        cls.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.module)

    def test_permission_fixture_is_exact_and_least_privilege(self):
        self.assertEqual(self.module.REQUIRED_PERMISSIONS, (
            "Account / Cloudflare Tunnel / Edit",
            "Zone / DNS / Edit",
            "Zone / Zone / Read",
        ))

    def test_resource_fixture_has_one_service_and_fail_closed_catchall(self):
        self.assertEqual(self.module.desired_ingress(HOST), [
            {"hostname": HOST, "service": "http://hermes-gateway:8646"},
            {"service": "http_status:404"},
        ])
        self.assertEqual(self.module.desired_dns(TUNNEL, HOST), {
            "type": "CNAME", "name": HOST,
            "content": f"{TUNNEL}.cfargotunnel.com",
            "proxied": True, "ttl": 1,
        })
        self.assertFalse(self.module._config_matches({"config": {
            "ingress": self.module.desired_ingress(HOST),
            "warp-routing": {"enabled": True},
        }}, HOST))

    def test_default_catchall_config_is_empty(self):
        self.assertTrue(self.module._config_is_empty({}))
        self.assertTrue(self.module._config_is_empty({"config": {}}))
        self.assertTrue(self.module._config_is_empty({"config": {
            "ingress": [{"service": "http_status:404", "originRequest": {"connectTimeout": 30}}],
            "originRequest": {"keepAliveConnections": 100},
            "warp-routing": {"enabled": False},
        }}))
        self.assertTrue(self.module._config_matches({"config": {
            "ingress": [
                {"hostname": HOST, "service": "http://hermes-gateway:8646", "originRequest": {"connectTimeout": 30}},
                {"service": "http_status:404", "path": ""},
            ],
            "originRequest": {"keepAliveConnections": 100},
        }}, HOST))
        self.assertFalse(self.module._config_is_empty({"config": {
            "ingress": [{"hostname": HOST, "service": "http://wrong:80"}, {"service": "http_status:404"}],
        }}))
        self.assertFalse(self.module._config_is_empty({"config": {
            "ingress": [{"service": "http_status:404"}],
            "warp-routing": {"enabled": True},
        }}))

    def test_resolve_zone_requires_exactly_one_match(self):
        zone = {"id": ZONE, "name": "example.com", "account": {"id": ACCOUNT}}
        api = FakeAPI([[zone]])
        self.assertEqual(self.module.resolve_zone(api, "example.com"), (ACCOUNT, ZONE))
        self.assertEqual(api.calls, [("GET", "/zones", None, {"name": "example.com"})])
        with self.assertRaisesRegex(RuntimeError, "ambiguous"):
            self.module.resolve_zone(FakeAPI([[]]), "example.com")
        with self.assertRaisesRegex(RuntimeError, "ambiguous"):
            self.module.resolve_zone(FakeAPI([[zone, dict(zone)]]), "example.com")
        with self.assertRaisesRegex(RuntimeError, "malformed"):
            self.module.resolve_zone(
                FakeAPI([[{"id": ZONE, "name": "other.com", "account": {"id": ACCOUNT}}]]),
                "example.com",
            )

    def test_config_shape_redacts_values(self):
        shape = self.module._config_shape({"config": {
            "ingress": [{"hostname": "secret.example.com", "service": "http://127.0.0.1:9"}],
            "warp-routing": {"enabled": True, "secret": "should-not-leak"},
            "originRequest": {"httpHostHeader": "should-not-leak"},
        }})
        self.assertNotIn("should-not-leak", shape)
        self.assertNotIn("secret.example.com", shape)
        self.assertNotIn("127.0.0.1", shape)
        self.assertIn("'enabled': True", shape)

    def test_creation_mutates_only_exact_resources_and_reads_back(self):
        tunnel = {
            "id": TUNNEL, "name": f"hermes-{DEPLOYMENT}",
            "account_tag": ACCOUNT, "config_src": "cloudflare", "deleted_at": None,
        }
        ingress = self.module.desired_ingress(HOST)
        dns = self.module.desired_dns(TUNNEL, HOST)
        replies = [
            {"status": "active"},
            {"id": ZONE, "name": "example.com", "account": {"id": ACCOUNT}},
            [], [], tunnel, tunnel, "connector-token-value-123",
            {"config": {"ingress": [], "warp-routing": {"enabled": False}}}, [],
            {}, {"config": {"ingress": ingress}}, {}, [dict(dns, id="dns-id")],
        ]
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "state.json"
            api = FakeAPI(replies)
            result = self.module.provision(
                api, DEPLOYMENT, ACCOUNT, ZONE, "example.com", state,
                lambda: "0123456789ab",
            )
            self.assertEqual(self.module.load_state(state)["tunnel_id"], TUNNEL)
        self.assertEqual(result["hostname"], HOST)
        mutations = [call for call in api.calls if call[0] in {"POST", "PUT", "PATCH", "DELETE"}]
        self.assertEqual(mutations, [
            ("POST", f"/accounts/{ACCOUNT}/cfd_tunnel", {
                "name": f"hermes-{DEPLOYMENT}", "config_src": "cloudflare",
            }, None),
            ("PUT", f"/accounts/{ACCOUNT}/cfd_tunnel/{TUNNEL}/configurations", {
                "config": {"ingress": ingress},
            }, None),
            ("POST", f"/zones/{ZONE}/dns_records", dns, None),
        ])

    def test_conflicting_state_stops_before_api(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "state.json"
            self.module.write_state(state, {
                "version": 1, "deployment_id": DEPLOYMENT, "account_id": ACCOUNT,
                "zone_id": ZONE, "zone_name": "wrong.example.com",
                "tunnel_id": TUNNEL, "tunnel_name": f"hermes-{DEPLOYMENT}",
                "hostname": HOST,
            })
            api = FakeAPI([])
            with self.assertRaisesRegex(ValueError, "conflicts with requested zone"):
                self.module.provision(api, DEPLOYMENT, ACCOUNT, ZONE, "example.com", state, lambda: "0123456789ab")
            self.assertEqual(api.calls, [])

    def test_matching_rerun_is_read_only(self):
        state_data = {
            "version": 1, "deployment_id": DEPLOYMENT, "account_id": ACCOUNT,
            "zone_id": ZONE, "zone_name": "example.com", "tunnel_id": TUNNEL,
            "tunnel_name": f"hermes-{DEPLOYMENT}", "hostname": HOST,
        }
        replies = [
            {"status": "active"},
            {"id": ZONE, "name": "example.com", "account": {"id": ACCOUNT}},
            [{"id": TUNNEL, "name": f"hermes-{DEPLOYMENT}", "account_tag": ACCOUNT, "config_src": "cloudflare", "deleted_at": None}],
            {"id": TUNNEL, "name": f"hermes-{DEPLOYMENT}", "account_tag": ACCOUNT, "config_src": "cloudflare", "deleted_at": None},
            "connector-token-value-123",
            {"config": {"ingress": self.module.desired_ingress(HOST)}},
            [dict(self.module.desired_dns(TUNNEL, HOST), id="dns-id")],
        ]
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "state.json"
            self.module.write_state(state, state_data)
            api = FakeAPI(replies)
            result = self.module.provision(api, DEPLOYMENT, ACCOUNT, ZONE, "example.com", state, lambda: "ffffffffffff")
        self.assertEqual(result["hostname"], HOST)
        self.assertFalse(any(method in {"POST", "PUT", "PATCH", "DELETE"} for method, *_ in api.calls))

    def test_conflicting_existing_config_stops_without_mutation(self):
        state_data = {
            "version": 1, "deployment_id": DEPLOYMENT, "account_id": ACCOUNT,
            "zone_id": ZONE, "zone_name": "example.com", "tunnel_id": TUNNEL,
            "tunnel_name": f"hermes-{DEPLOYMENT}", "hostname": HOST,
        }
        replies = [
            {"status": "active"},
            {"id": ZONE, "name": "example.com", "account": {"id": ACCOUNT}},
            [{"id": TUNNEL, "name": f"hermes-{DEPLOYMENT}", "account_tag": ACCOUNT, "config_src": "cloudflare", "deleted_at": None}],
            {"id": TUNNEL, "name": f"hermes-{DEPLOYMENT}", "account_tag": ACCOUNT, "config_src": "cloudflare", "deleted_at": None},
            "connector-token-value-123",
            {"config": {"ingress": [{"hostname": HOST, "service": "http://wrong:80"}, {"service": "http_status:404"}]}},
        ]
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "state.json"
            self.module.write_state(state, state_data)
            api = FakeAPI(replies)
            with self.assertRaisesRegex(RuntimeError, "configuration conflicts"):
                self.module.provision(api, DEPLOYMENT, ACCOUNT, ZONE, "example.com", state, lambda: "ffffffffffff")
        self.assertFalse(any(method in {"POST", "PUT", "PATCH", "DELETE"} for method, *_ in api.calls))

    def test_conflicting_connector_token_stops_before_route_mutation(self):
        state_data = {
            "version": 1, "deployment_id": DEPLOYMENT, "account_id": ACCOUNT,
            "zone_id": ZONE, "zone_name": "example.com", "tunnel_id": TUNNEL,
            "tunnel_name": f"hermes-{DEPLOYMENT}", "hostname": HOST,
        }
        tunnel = {
            "id": TUNNEL, "name": f"hermes-{DEPLOYMENT}",
            "account_tag": ACCOUNT, "config_src": "cloudflare", "deleted_at": None,
        }
        replies = [
            {"status": "active"},
            {"id": ZONE, "name": "example.com", "account": {"id": ACCOUNT}},
            [tunnel], tunnel, "different-connector-token-456",
        ]
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "state.json"
            token = Path(directory) / "token"
            self.module.write_state(state, state_data)
            self.module.write_connector_token(token, "original-connector-token-123")
            api = FakeAPI(replies)
            with self.assertRaisesRegex(ValueError, "no API mutation"):
                self.module.provision(
                    api, DEPLOYMENT, ACCOUNT, ZONE, "example.com", state,
                    lambda: "ffffffffffff", token,
                )
        self.assertFalse(any(method in {"POST", "PUT", "PATCH", "DELETE"} for method, *_ in api.calls))

    def test_conflicting_dns_stops_before_empty_config_is_mutated(self):
        state_data = {
            "version": 1, "deployment_id": DEPLOYMENT, "account_id": ACCOUNT,
            "zone_id": ZONE, "zone_name": "example.com", "tunnel_id": TUNNEL,
            "tunnel_name": f"hermes-{DEPLOYMENT}", "hostname": HOST,
        }
        tunnel = {
            "id": TUNNEL, "name": f"hermes-{DEPLOYMENT}",
            "account_tag": ACCOUNT, "config_src": "cloudflare", "deleted_at": None,
        }
        replies = [
            {"status": "active"},
            {"id": ZONE, "name": "example.com", "account": {"id": ACCOUNT}},
            [tunnel], tunnel, "connector-token-value-123", {"config": {}},
            [{"id": "foreign", "type": "A", "name": HOST, "content": "192.0.2.1"}],
        ]
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "state.json"
            self.module.write_state(state, state_data)
            api = FakeAPI(replies)
            with self.assertRaisesRegex(RuntimeError, "DNS ownership conflicts"):
                self.module.provision(
                    api, DEPLOYMENT, ACCOUNT, ZONE, "example.com", state,
                    lambda: "ffffffffffff",
                )
        self.assertFalse(any(method in {"POST", "PUT", "PATCH", "DELETE"} for method, *_ in api.calls))

    def test_verify_storage_accepts_install_mount_options(self):
        lsblk = mock.Mock(stdout='{"blockdevices":[{"path":"/dev/nvme1n1","type":"disk","serial":"vol0123456789abcdef0"}]}')
        findmnt = mock.Mock(stdout="/var/lib/hermes /dev/nvme1n1 xfs rw,nosuid,nodev,relatime,seclabel\n")
        with mock.patch.object(self.module.subprocess, "run", side_effect=[lsblk, findmnt]), \
                mock.patch.object(self.module.os.path, "realpath", side_effect=lambda path: path):
            self.module.verify_storage("vol-0123456789abcdef0")

    def test_verify_storage_rejects_missing_nodev(self):
        lsblk = mock.Mock(stdout='{"blockdevices":[{"path":"/dev/nvme1n1","type":"disk","serial":"vol0123456789abcdef0"}]}')
        findmnt = mock.Mock(stdout="/var/lib/hermes /dev/nvme1n1 xfs rw,nosuid,relatime\n")
        with mock.patch.object(self.module.subprocess, "run", side_effect=[lsblk, findmnt]), \
                mock.patch.object(self.module.os.path, "realpath", side_effect=lambda path: path):
            with self.assertRaisesRegex(RuntimeError, "mount options are unsafe"):
                self.module.verify_storage("vol-0123456789abcdef0")

    def test_token_write_is_owner_only_and_mismatch_is_retained(self):
        with tempfile.TemporaryDirectory() as directory:
            token_path = Path(directory) / "token"
            self.module.write_connector_token(token_path, "first-connector-token-123")
            self.assertEqual(token_path.read_text(), "first-connector-token-123")
            self.assertEqual(stat.S_IMODE(token_path.stat().st_mode), 0o600)
            with self.assertRaisesRegex(ValueError, "connector credential conflicts"):
                self.module.write_connector_token(token_path, "second-connector-token-456")
            self.assertEqual(token_path.read_text(), "first-connector-token-123")


if __name__ == "__main__":
    unittest.main()
