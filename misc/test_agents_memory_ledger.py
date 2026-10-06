"""Protect the durable facts imported from the former project memories."""
from pathlib import Path
import unittest


AGENTS = (Path(__file__).resolve().parents[1] / "AGENTS.md").read_text()


class AgentsMemoryLedgerContract(unittest.TestCase):
    def test_codex_memory_reconciliation_is_recorded(self):
        for witness in (
            "Codex memory reconciliation (re-audited 2026-10-07)",
            "$CODEX_HOME/memories/",
            "$CODEX_HOME/memories_1.sqlite",
            "zero `stage1_outputs` rows",
            "no additional Codex memory remained outside this repository",
        ):
            self.assertIn(witness, AGENTS)

    def test_indexed_topics_are_self_contained(self):
        for heading in (
            "autosignd on-demand signing",
            "Chroot DNS and the self-contained proxy",
            "Claude Code inside the macOS chroot",
            "macOS cross-build SDK setup",
        ):
            self.assertIn(heading, AGENTS)

    def test_current_porting_candidate_is_not_promoted_to_validated(self):
        for witness in (
            "iPad14,3 (M2), iPadOS 16.5.1 / 20F75",
            "Porting candidate only",
            "B5CBF457-B300-3FD0-A646-1261DA6E86B0",
            "legacy `0x70` shape",
            "not an accepted",
        ):
            self.assertIn(witness, AGENTS)

    def test_recovered_macpad_only_compatibility_facts_are_retained(self):
        for witness in (
            "Recovered iPadOS 16.4.1 compatibility work",
            "`024c0fb`",
            "Unknown results enable no legacy mutation",
            "type-`0x82`",
            "dyld interposition plus `RTLD_NEXT`",
            "never recursively `chown` the rootfs",
            "misc/agx_device_info_probe.c",
        ):
            self.assertIn(witness, AGENTS)

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
