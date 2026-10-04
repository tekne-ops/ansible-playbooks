from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

INSTALL_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(INSTALL_DIR))

import render_autoinstall  # noqa: E402

COMMITTED = INSTALL_DIR / "autoinstall.yaml"
FIXTURE = """
password: "REPLACE_WITH_VAULT_user_password"
wifi: "REPLACE_WITH_OS_WIFI_PASSPHRASE"
key: "REPLACE_WITH_SSH_AUTHORIZED_KEY"
devops: "REPLACE_WITH_DEVOPS_SSH_AUTHORIZED_KEY"
"""
REPLACEMENTS = {
    "REPLACE_WITH_VAULT_user_password": "$6$testsalt$testhashvalue",
    "REPLACE_WITH_OS_WIFI_PASSPHRASE": "wifi-secret",
    "REPLACE_WITH_SSH_AUTHORIZED_KEY": "ssh-ed25519 AAAAC3Rlc3Q= user@test",
    "REPLACE_WITH_DEVOPS_SSH_AUTHORIZED_KEY": "ssh-ed25519 AAAAC3Rlc3RkZXZvcHM= devops@test",
}


class RenderAutoinstallTest(unittest.TestCase):
    def test_committed_autoinstall_uses_placeholders(self) -> None:
        text = COMMITTED.read_text(encoding="utf-8")
        self.assertNotIn("$6$", text)
        self.assertNotIn("ssh-rsa ", text)
        self.assertNotIn("CHANGE_ME", text)
        for placeholder in render_autoinstall.PLACEHOLDERS:
            self.assertIn(placeholder, text)
        self.assertNotIn("interactive-sections", text)

    def test_render_replaces_every_placeholder(self) -> None:
        rendered = render_autoinstall.render_text(COMMITTED.read_text(encoding="utf-8"), REPLACEMENTS)
        self.assertEqual(render_autoinstall.unresolved_placeholders(rendered), [])
        self.assertIn(REPLACEMENTS["REPLACE_WITH_VAULT_user_password"], rendered)
        self.assertIn(REPLACEMENTS["REPLACE_WITH_SSH_AUTHORIZED_KEY"], rendered)
        self.assertNotIn("REPLACE_WITH_", rendered)
        self.assertIsInstance(yaml.safe_load(rendered), dict)

    def test_partial_render_refuses_and_does_not_write(self) -> None:
        partial = dict(REPLACEMENTS)
        del partial["REPLACE_WITH_OS_WIFI_PASSPHRASE"]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            template = root / "template.yaml"
            template.write_text(FIXTURE, encoding="utf-8")
            output = root / "autoinstall.yaml"
            with self.assertRaises(render_autoinstall.RenderError) as raised:
                render_autoinstall.write_rendered(template, output, partial)
            self.assertIn("REPLACE_WITH_OS_WIFI_PASSPHRASE", str(raised.exception))
            self.assertFalse(output.exists())

    def test_placeholder_value_is_refused(self) -> None:
        bad = dict(REPLACEMENTS)
        bad["REPLACE_WITH_VAULT_user_password"] = "REPLACE_WITH_VAULT_user_password"
        with self.assertRaises(render_autoinstall.RenderError):
            render_autoinstall.render_text(FIXTURE, bad)

    def test_cli_refuses_unresolved_template(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            template = root / "template.yaml"
            template.write_text(FIXTURE, encoding="utf-8")
            output = root / "autoinstall.yaml"
            completed = subprocess.run(
                [
                    sys.executable,
                    str(INSTALL_DIR / "render_autoinstall.py"),
                    "--template",
                    str(template),
                    "--output",
                    str(output),
                    "--user-password-hash",
                    REPLACEMENTS["REPLACE_WITH_VAULT_user_password"],
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(completed.returncode, 1)
            self.assertIn("unresolved placeholders", completed.stderr)
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
