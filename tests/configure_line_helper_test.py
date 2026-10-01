#!/usr/bin/env python3
import importlib.util
import os
import stat
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HELPER = Path(__file__).resolve().parents[1] / "scripts/support/configure-hermes-line.py"


class ConfigureLineTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("configure_line", HELPER)
        if spec is None or spec.loader is None:
            raise RuntimeError("unable to load helper")
        cls.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.module)

    def test_lock_env_permissions_adopts_permissive_regular_file(self):
        info = os.stat_result((0o100644, 1, 1, 1, 1000, 1000, 12, 0, 0, 0))
        locked = os.stat_result((0o100600, 1, 1, 1, 0, 0, 12, 0, 0, 0))
        with mock.patch.object(self.module.os, "fstat", side_effect=[info, locked]), \
                mock.patch.object(self.module.os, "fchown") as fchown, \
                mock.patch.object(self.module.os, "fchmod") as fchmod:
            self.module._lock_env_permissions(7)
        fchown.assert_called_once_with(7, 0, 0)
        fchmod.assert_called_once_with(7, 0o600)

    def test_lock_env_permissions_skips_matching_root_0600(self):
        info = os.stat_result((0o100600, 1, 1, 1, 0, 0, 12, 0, 0, 0))
        with mock.patch.object(self.module.os, "fstat", return_value=info), \
                mock.patch.object(self.module.os, "fchown") as fchown, \
                mock.patch.object(self.module.os, "fchmod") as fchmod:
            self.module._lock_env_permissions(7)
        fchown.assert_not_called()
        fchmod.assert_not_called()

    def test_lock_env_permissions_rejects_non_regular(self):
        info = os.stat_result((0o040755, 1, 1, 1, 0, 0, 12, 0, 0, 0))
        with mock.patch.object(self.module.os, "fstat", return_value=info):
            with self.assertRaisesRegex(ValueError, "must be a regular file"):
                self.module._lock_env_permissions(7)

    def test_validates_public_base_url(self):
        self.assertEqual(self.module.validate_public_url("https://edge.example.com"), "https://edge.example.com")
        for value in ("http://edge.example.com", "https://edge.example.com/path", "https://user@edge.example.com", "https://127.0.0.1"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.module.validate_public_url(value)

    def test_atomic_env_update_preserves_unrelated_values_and_mode(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / ".env"
            path.write_text("MODEL_KEY=keep\nLINE_CHANNEL_SECRET=old\n", encoding="utf-8")
            os.chmod(path, 0o600)
            self.module.update_env(path, {"LINE_CHANNEL_SECRET": "old", "LINE_CHANNEL_ACCESS_TOKEN": "token", "LINE_PUBLIC_URL": "https://edge.example.com"})
            text = path.read_text(encoding="utf-8")
            self.assertIn("MODEL_KEY=keep\n", text)
            self.assertEqual(text.count("LINE_CHANNEL_SECRET="), 1)
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)

    def test_conflicting_existing_value_fails_redacted(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / ".env"
            path.write_text("LINE_CHANNEL_SECRET=existing-secret\n", encoding="utf-8")
            os.chmod(path, 0o600)
            with self.assertRaisesRegex(ValueError, "conflicting existing LINE_CHANNEL_SECRET") as caught:
                self.module.update_env(path, {"LINE_CHANNEL_SECRET": "different-secret"})
            self.assertNotIn("existing-secret", str(caught.exception))
            self.assertNotIn("different-secret", str(caught.exception))

    def test_verify_storage_rejects_wrong_device(self):
        lsblk = mock.Mock(stdout='{"blockdevices":[{"path":"/dev/nvme1n1","type":"disk","serial":"vol0123456789abcdef0"}]}')
        findmnt = mock.Mock(stdout="/var/lib/hermes /dev/nvme2n1 xfs rw,nosuid,nodev,noexec\n")
        with mock.patch.object(self.module.subprocess, "run", side_effect=[lsblk, findmnt]):
            with self.assertRaisesRegex(RuntimeError, "wrong device"):
                self.module.verify_storage("vol-0123456789abcdef0")

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

    def test_webhook_write_is_read_back_before_test(self):
        client = mock.Mock()
        client.request.side_effect = [({}, 200), ({"endpoint": "https://edge.example.com/line/webhook", "active": True}, 200), ({"success": True}, 200)]
        self.module.configure_webhook(client, "https://edge.example.com")
        self.assertEqual([call.args[0] for call in client.request.call_args_list], ["PUT", "GET", "POST"])

    def test_webhook_mismatch_stops_before_test(self):
        client = mock.Mock()
        client.request.side_effect = [({}, 200), ({"endpoint": "https://other.example.com/line/webhook", "active": True}, 200)]
        with self.assertRaisesRegex(RuntimeError, "read-back did not match"):
            self.module.configure_webhook(client, "https://edge.example.com")
        self.assertEqual(client.request.call_count, 2)


if __name__ == "__main__":
    unittest.main()
