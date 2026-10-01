from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
EXEC_HOOKS = (ROOT / "libmachook" / "exec_hooks.c").read_text()


class CodexCodeModeRuntimeContractTests(unittest.TestCase):
    def test_adapter_is_scoped_to_exact_helper_basename(self):
        helper = EXEC_HOOKS.split(
            "static bool is_codex_code_mode_host", 1
        )[1].split("static bool env_key_matches", 1)[0]
        self.assertIn('strcmp(basename, "codex-code-mode-host") == 0', helper)
        self.assertNotIn("strstr(", helper)

    def test_spawn_and_execve_force_both_wx_adapters(self):
        selector = EXEC_HOOKS.split(
            "static selected_env_t env_select_insert", 1
        )[1].split("static void env_selected_free", 1)[0]
        self.assertIn("is_codex_code_mode_host(path)", selector)
        self.assertIn('"MACWS_JIT_MPROTECT_COMPAT=1"', selector)
        self.assertIn('"MACWS_JIT_FAULT_WRITE_COMPAT=1"', selector)
        # Supplied zero/duplicate values must be removed before the validated
        # launch contract is appended exactly once.
        self.assertIn(
            'env_key_matches(source[i], "MACWS_JIT_MPROTECT_COMPAT")',
            selector,
        )
        self.assertIn(
            'env_key_matches(source[i], "MACWS_JIT_FAULT_WRITE_COMPAT")',
            selector,
        )

    def test_execv_family_restores_parent_environment_on_failure(self):
        process_selector = EXEC_HOOKS.split(
            "static saved_insert_t process_env_select_insert", 1
        )[1].split("// VS Code's macOS shell-environment resolver", 1)[0]
        for key in (
            "MACWS_JIT_MPROTECT_COMPAT",
            "MACWS_JIT_FAULT_WRITE_COMPAT",
        ):
            self.assertIn(f'setenv("{key}", "1", 1)', process_selector)
            self.assertIn(f'restore_environment_value("{key}"', process_selector)
        self.assertIn("if (saved->managed_codex_jit)", process_selector)

    def test_codex_flags_are_not_global_daemon_defaults(self):
        launch_daemons = ROOT / "layout" / "usr" / "macOS" / "LaunchDaemons"
        for plist in launch_daemons.glob("*.plist"):
            if plist.name == "com.apple.WindowServer.plist":
                # WindowServer has its own independent rendering contract.
                continue
            text = plist.read_text(errors="ignore")
            self.assertNotIn("codex-code-mode-host", text)


if __name__ == "__main__":
    unittest.main()
