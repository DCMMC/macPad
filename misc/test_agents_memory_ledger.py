"""Protect the durable facts imported from the former project memories."""
from pathlib import Path
import unittest


AGENTS = (Path(__file__).resolve().parents[1] / "AGENTS.md").read_text()


class AgentsMemoryLedgerContract(unittest.TestCase):
    def test_indexed_topics_are_self_contained(self):
        for heading in (
            "autosignd on-demand signing",
            "Chroot DNS and the self-contained proxy",
            "Claude Code inside the macOS chroot",
            "macOS cross-build SDK setup",
        ):
            self.assertIn(heading, AGENTS)

    def test_autosignd_failure_modes_and_protocol_are_retained(self):
        for witness in (
            "/var/mnt/rootfs/tmp/autosignd.sock",
            "posix_spawnp",
            "five seconds",
            "fail-open",
            "dlsym(RTLD_NEXT, ...)",
            "Always ad-hoc re-sign",
            "incompatible platform:",
        ):
            self.assertIn(witness, AGENTS)

    def test_proxy_and_claude_runtime_details_are_retained(self):
        for witness in (
            "socks5h://127.0.0.1:1082",
            "Starting `ssh -f`",
            "undici client does not use a SOCKS proxy",
            "GIGACAGE_ENABLED=0",
            "BUN_JSC_useGigacage",
            "EBADEXEC`/errno `-85",
            "ANTHROPIC_API_KEY",
            "ANTHROPIC_AUTH_TOKEN",
            "NO_PROXY",
            "real prompt",
        ):
            self.assertIn(witness, AGENTS)

    def test_sdk_and_removed_subproject_history_are_retained(self):
        for witness in (
            "bin/dm.pl",
            "bin/fakeroot.sh",
            "vendor/ios-xpc/xpc/",
            "OS_OBJECT_DECL_SENDABLE_CLASS",
            "symlinks it into `$THEOS/sdks`",
            "rejected alternative",
            "obsolete `login` subproject",
            "five root subprojects",
            "historical implementation details",
        ):
            self.assertIn(witness, AGENTS)


if __name__ == "__main__":
    unittest.main()
