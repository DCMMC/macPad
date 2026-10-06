"""Protect the durable facts mirrored from the live local project memories."""
from pathlib import Path
import unittest


AGENTS = (Path(__file__).resolve().parents[1] / "AGENTS.md").read_text()


class AgentsMemoryLedgerContract(unittest.TestCase):
    def test_local_agent_memory_reconciliation_is_recorded(self):
        for witness in (
            "Local agent-memory reconciliation (corrected audit: 2026-10-07)",
            "~/.claude/projects/<encoded-old-checkout>/memory/",
            "$CODEX_HOME/memories/",
            "$CODEX_HOME/memories_1.sqlite",
            "zero `stage1_outputs` rows",
            "zero jobs",
            "`memory_mode=enabled`",
            "no injected memory block",
            "no unmatched durable project fact remained",
            "live shared-agent project memory directory contains one index and four",
        ):
            self.assertIn(witness, AGENTS)

    def test_live_memory_source_manifest_is_complete(self):
        for witness in (
            "`MEMORY.md`: a four-entry index",
            "`macos-build-sdk-setup.md`",
            "`claude-code-on-ios-chroot.md`",
            "`chroot-socks-proxy.md`",
            "`autosignd-on-demand-signing.md`",
            "`originSessionId`",
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
            "Unsupported",
            "totalSize = 68719476736",
            "Claude Code TUI environment",
            "`*-external` quota response/HTTP",
            "Not logged in · Please run /login",
            "npm registries returned 200",
            "/var/jb/usr/macOS/bin/entitlements.plist",
            "`sign_and_trustcache`",
            "`run_bash.sh` followed by `claude`",
            "chroot `/etc/hosts`",
            "port 1082 on the device's local address",
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
            "`set_macos_version.py`, then `ldid`, then `codesign`",
            "historical implementation details",
        ):
            self.assertIn(witness, AGENTS)


if __name__ == "__main__":
    unittest.main()
