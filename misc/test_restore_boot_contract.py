"""Guard the iOS-side repairs required by a filtered macOS rootfs restore."""
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
BIND = (ROOT / "layout/usr/macOS/bin/ensure_jb_usr_bind.sh").read_text()
AUTOSIGND = (ROOT / "layout/usr/macOS/bin/restart_autosignd.sh").read_text()
CONTROL = (ROOT / "control").read_text()
MAKEFILE = (ROOT / "Makefile").read_text()
PACKAGE_POSTINST = (ROOT / "layout/DEBIAN/postinst").read_text()


class RestoreBootContract(unittest.TestCase):
    def test_bind_probe_uses_the_ios_system_mount_binary(self):
        self.assertIn("system_mount=/sbin/mount", BIND)
        self.assertIn('[ -x "$system_mount" ]', BIND)
        self.assertEqual(BIND.count('if "$system_mount" | grep -Fq'), 1)
        self.assertIn('   "$system_mount" | grep -Fq', BIND)
        self.assertIn('grep -Fq " on $canonical_target ("', BIND)
        self.assertIn('grep -Fq " on $canonical_parent ("', BIND)
        self.assertNotIn(
            'grep -Fq "/var/jb/usr on $canonical_target ("', BIND)

    def test_filtered_restore_recreates_only_the_volatile_tmp_directory(self):
        self.assertIn("ROOTFS=/var/mnt/rootfs", AUTOSIGND)
        self.assertIn(
            '[ ! -f "$ROOTFS/System/Library/CoreServices/SystemVersion.plist" ]',
            AUTOSIGND)
        self.assertIn('mkdir -p "$ROOTFS/private/tmp" || exit 1', AUTOSIGND)
        self.assertIn('chmod 1777 "$ROOTFS/private/tmp" || exit 1', AUTOSIGND)
        self.assertIn('ln -s private/tmp "$ROOTFS/tmp" || exit 1', AUTOSIGND)
        self.assertLess(
            AUTOSIGND.index("SystemVersion.plist"),
            AUTOSIGND.index('mkdir -p "$ROOTFS/private/tmp"'))

    def test_package_declares_ios_tools_used_during_postinstall(self):
        depends = next(
            line.removeprefix("Depends:").strip()
            for line in CONTROL.splitlines() if line.startswith("Depends:"))
        self.assertEqual(
            {item.strip() for item in depends.split(",")},
            {"gawk", "ldid", "odcctools", "plutil", "python3"})

    def test_package_survives_dpkg_fat_macho_thinning(self):
        self.assertIn(
            'arm64="$(THEOS_STAGING_DIR)/usr/macOS/lib/libmachook_arm64.dylib"',
            MAKEFILE)
        self.assertIn('lipo "$$fat" -thin arm64 -output "$$arm64"', MAKEFILE)
        self.assertIn('lipo "$$fat" -thin arm64e -output "$$arm64e"', MAKEFILE)
        self.assertIn('elif [ -f "$LIBMACHOOK_ARM64" ]; then', PACKAGE_POSTINST)
        self.assertIn(
            '"$MACHO_PATCHER" "$LIBMACHOOK_ARM64" || exit 1',
            PACKAGE_POSTINST)

    def test_package_rejects_bootstraps_without_dynamic_trustcache_support(self):
        self.assertIn(
            'if [ ! -x /var/jb/usr/bin/jbctl ]; then',
            PACKAGE_POSTINST)
        self.assertIn(
            'NathanLR cannot admit the macOS shared-cache closure',
            PACKAGE_POSTINST)

    def test_package_restores_native_host_trust_before_publishing_it(self):
        declaration = (
            'HOST_APP=/var/jb/Applications/MacWSHost.app/MacWSHost')
        trust = 'trust_installed_macho "$HOST_APP"'
        publish = (
            '/var/jb/usr/bin/uicache -p '
            '/var/jb/Applications/MacWSHost.app')
        self.assertIn(declaration, PACKAGE_POSTINST)
        self.assertEqual(PACKAGE_POSTINST.count(trust), 1)
        self.assertLess(PACKAGE_POSTINST.index(trust),
                        PACKAGE_POSTINST.index(publish))

    def test_package_repairs_only_bounded_nas_owned_runtime_state(self):
        self.assertIn('normalize_restored_runtime_metadata()',
                      PACKAGE_POSTINST)
        self.assertIn(
            '"$cache_root/dyld_shared_cache_arm64e.01"',
            PACKAGE_POSTINST)
        self.assertIn('"$ROOTFS/var/db/macws/boot-trust"',
                      PACKAGE_POSTINST)
        self.assertIn('"$ROOTFS/var/db/macws/settings-runtime"',
                      PACKAGE_POSTINST)
        repair = PACKAGE_POSTINST.split(
            'normalize_restored_runtime_metadata() {', 1)[1].split('\n}', 1)[0]
        self.assertNotIn('chown -R', repair)
        self.assertIn('[ ! -L "$cache_path" ]', repair)
        self.assertIn('[ ! -L "$state_dir" ]', repair)

    def test_office_helper_gets_project_policy_before_trust_restore(self):
        postinst = (ROOT / "layout/usr/macOS/bin/postinst.sh").read_text()
        helper = (
            "/var/mnt/rootfs/Library/PrivilegedHelperTools/"
            "com.microsoft.office.licensingV2.helper")
        self.assertIn(
            "ensure_project_signature_and_trustcache \\\n    " + helper,
            postinst,
        )
        self.assertNotIn("add_all_trustcache \\\n    " + helper, postinst)


if __name__ == "__main__":
    unittest.main()
