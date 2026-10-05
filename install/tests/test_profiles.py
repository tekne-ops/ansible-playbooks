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


if __name__ == "__main__":
    unittest.main()
