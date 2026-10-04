#!/usr/bin/env python3
"""Render install/autoinstall.yaml and refuse unresolved placeholders."""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_TEMPLATE = REPO_ROOT / "install" / "autoinstall.yaml"
DEFAULT_VAULT = REPO_ROOT / "vars" / "vault.yml"

PLACEHOLDERS = (
    "REPLACE_WITH_VAULT_user_password",
    "REPLACE_WITH_OS_WIFI_PASSPHRASE",
    "REPLACE_WITH_SSH_AUTHORIZED_KEY",
    "REPLACE_WITH_DEVOPS_SSH_AUTHORIZED_KEY",
)

UNRESOLVED_RE = re.compile(r"REPLACE_WITH_[A-Za-z0-9_]+")
FORBIDDEN_TEXT = (*PLACEHOLDERS, "CHANGE_ME")


class RenderError(Exception):
    """The template could not be rendered into an installable file."""


def unresolved_placeholders(text: str) -> list[str]:
    found: list[str] = []
    for token in FORBIDDEN_TEXT:
        if token in text and token not in found:
            found.append(token)
    for token in UNRESOLVED_RE.findall(text):
        if token not in found:
            found.append(token)
    return found


def _read_key_file(path: Path) -> str:
    value = path.read_text(encoding="utf-8").strip()
    if not value or "\n" in value:
        raise RenderError(f"Authorized key file must be one non-empty line: {path}")
    return value


def _reject_value(label: str, value: str) -> None:
    if not value or not value.strip():
        raise RenderError(f"{label} is empty")
    if "\n" in value or "\r" in value:
        raise RenderError(f"{label} must be a single line")
    if '"' in value or "'" in value:
        raise RenderError(f"{label} contains a quote")
    if unresolved_placeholders(value):
        raise RenderError(f"{label} still contains an unresolved placeholder")


def load_vault_secrets(vault_file: Path, password_file: Path) -> dict[str, str]:
    result = subprocess.run(
        [
            "ansible-vault",
            "view",
            vault_file.as_posix(),
            "--vault-password-file",
            password_file.as_posix(),
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        detail = result.stderr.strip().splitlines()
        message = detail[-1] if detail else "vault decrypt failed"
        raise RenderError(message)
    try:
        import yaml
    except ImportError as exc:
        raise RenderError("PyYAML is required to read vault variables") from exc
    data = yaml.safe_load(result.stdout)
    if not isinstance(data, dict):
        raise RenderError("Vault file did not contain a mapping")
    secrets: dict[str, str] = {}
    for key in ("user_password", "os_wifi_passphrase"):
        value = data.get(key)
        if value is None:
            continue
        secrets[key] = str(value)
    return secrets


def render_text(template: str, replacements: dict[str, str]) -> str:
    rendered = template
    for token, value in replacements.items():
        _reject_value(token, value)
        if token not in rendered:
            raise RenderError(f"Template is missing {token}")
        rendered = rendered.replace(token, value)
    leftover = unresolved_placeholders(rendered)
    if leftover:
        raise RenderError(
            "Refusing to write autoinstall output; unresolved placeholders: "
            + ", ".join(leftover)
        )
    return rendered


def write_rendered(template_path: Path, output_path: Path, replacements: dict[str, str]) -> None:
    template = template_path.read_text(encoding="utf-8")
    rendered = render_text(template, replacements)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        dir=output_path.parent,
        prefix=f".{output_path.name}.",
        suffix=".tmp",
        delete=False,
    ) as handle:
        temp_path = Path(handle.name)
        handle.write(rendered)
    try:
        leftover = unresolved_placeholders(temp_path.read_text(encoding="utf-8"))
        if leftover:
            raise RenderError(
                "Refusing to write autoinstall output; unresolved placeholders: "
                + ", ".join(leftover)
            )
        os.chmod(temp_path, 0o600)
        temp_path.replace(output_path)
    except Exception:
        temp_path.unlink(missing_ok=True)
        raise


def _replacements_from_args(args: argparse.Namespace) -> dict[str, str]:
    replacements: dict[str, str] = {}
    if args.vault_password_file is not None:
        secrets = load_vault_secrets(args.vault_file, args.vault_password_file)
        if "user_password" in secrets:
            replacements["REPLACE_WITH_VAULT_user_password"] = secrets["user_password"]
        if "os_wifi_passphrase" in secrets:
            replacements["REPLACE_WITH_OS_WIFI_PASSPHRASE"] = secrets["os_wifi_passphrase"]
    if args.user_password_hash:
        replacements["REPLACE_WITH_VAULT_user_password"] = args.user_password_hash
    if args.wifi_passphrase:
        replacements["REPLACE_WITH_OS_WIFI_PASSPHRASE"] = args.wifi_passphrase
    if args.authorized_key_file is not None:
        replacements["REPLACE_WITH_SSH_AUTHORIZED_KEY"] = _read_key_file(args.authorized_key_file)
    if args.devops_authorized_key_file is not None:
        replacements["REPLACE_WITH_DEVOPS_SSH_AUTHORIZED_KEY"] = _read_key_file(
            args.devops_authorized_key_file
        )
    return replacements


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Render autoinstall.yaml and refuse unresolved placeholders.",
    )
    parser.add_argument("--template", type=Path, default=DEFAULT_TEMPLATE)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--vault-file", type=Path, default=DEFAULT_VAULT)
    parser.add_argument("--vault-password-file", type=Path)
    parser.add_argument("--user-password-hash")
    parser.add_argument("--wifi-passphrase")
    parser.add_argument("--authorized-key-file", type=Path)
    parser.add_argument("--devops-authorized-key-file", type=Path)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        write_rendered(args.template, args.output, _replacements_from_args(args))
    except RenderError as exc:
        print(f"render_autoinstall: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
