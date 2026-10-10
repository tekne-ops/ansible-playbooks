from __future__ import annotations

import sys
import unittest
from pathlib import Path

INSTALL_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(INSTALL_DIR / "lib"))

from tekne_profiles import load_profiles, shell_init  # noqa: E402


class InstallProfilesTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.data = load_profiles()

    def test_package_lists_have_no_duplicates(self) -> None:
        package_lists = {
            "global.pacstrap_base_packages": self.data["global"]["pacstrap_base_packages"],
        }
        for hostname, profile in self.data["hosts"].items():
            package_lists[f"{hostname}.mcode_packages"] = profile["mcode_packages"]

        for name, packages in package_lists.items():
            with self.subTest(name=name):
                self.assertEqual(len(packages), len(set(packages)))

    def test_profiles_define_installer_policy(self) -> None:
        for hostname, profile in self.data["hosts"].items():
            with self.subTest(hostname=hostname):
                self.assertTrue(profile["chroot_ansible_tags"])
                self.assertIn("user", profile["chroot_ansible_tags"])
                self.assertTrue(profile["post_install_command"])
                self.assertNotIn("sudo ", profile["post_install_command"])
                self.assertTrue(profile["maintenance_playbook"])
                self.assertTrue(profile["maintenance_inventory"])
                self.assertTrue(profile["maintenance_tags"])
                profile_path = (
                    INSTALL_DIR.parent
                    / "inventories"
                    / "host_profiles"
                    / f"{hostname}.yml"
                )
                self.assertTrue(profile_path.is_file())

    def test_host_packages_do_not_repeat_base_packages(self) -> None:
        base = set(self.data["global"]["pacstrap_base_packages"])
        for hostname, profile in self.data["hosts"].items():
            with self.subTest(hostname=hostname):
                self.assertFalse(base.intersection(profile["mcode_packages"]))

    def test_shell_init_exports_profile_policy(self) -> None:
        output = shell_init(self.data)
        self.assertIn("HOST_CHROOT_ANSIBLE_TAGS", output)
        self.assertIn("HOST_POST_INSTALL_COMMAND", output)
        self.assertIn("HOST_DISK1_START_MIB", output)
        self.assertIn("[ASTER]=1", output)
        self.assertIn("HOST_ROOT_FSTYPE", output)
        self.assertIn("HOST_DISK1_FSTYPE", output)
        self.assertIn("[ASTER]=ext4", output)
        self.assertIn("[ASTER]=xfs", output)
        self.assertIn("[THEMIS]=f2fs", output)
        self.assertIn("declare -gr GPT_TAIL_RESERVE_MIB=4", output)
        self.assertIn("declare -gA HOST_DISK0_LBAF=(\n)", output)
        self.assertIn("declare -gA HOST_DISK1_LBAF=(\n)", output)
        self.assertIn("declare -gA HOST_DISK2_LBAF=(\n)", output)

    def test_lbaf_stays_unset_until_a_profile_opts_in(self) -> None:
        data = load_profiles()
        data["hosts"]["ASTER"]["disk0_lbaf"] = 1
        data["hosts"]["ASTER"]["disk1_lbaf"] = 0
        output = shell_init(data)
        self.assertIn("declare -gA HOST_DISK0_LBAF=(\n  [ASTER]=1\n)", output)
        self.assertIn("declare -gA HOST_DISK1_LBAF=(\n  [ASTER]=0\n)", output)

    def test_lbaf_and_tail_reserve_reject_invalid_values(self) -> None:
        data = load_profiles()
        data["hosts"]["ASTER"]["disk0_lbaf"] = -1
        with self.assertRaises(ValueError):
            shell_init(data)
        data = load_profiles()
        data["global"]["gpt_tail_reserve_mib"] = True
        with self.assertRaises(ValueError):
            shell_init(data)


if __name__ == "__main__":
    unittest.main()
