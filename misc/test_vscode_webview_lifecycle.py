"""Behavioral contract for the private VS Code Simple Browser lifecycle."""

from pathlib import Path
import json
import subprocess
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[1]
EXTENSION = ROOT / "misc/vscode-aquarium-runner/extension.js"


class VSCodeWebviewLifecycleTests(unittest.TestCase):
    def run_node(self, body: str) -> dict:
        script = textwrap.dedent(f"""
            const Module = require("module");
            const fs = require("fs");
            fs.writeFileSync = () => undefined;
            fs.renameSync = () => undefined;
            fs.unlinkSync = () => undefined;
            const tabs = [
              {{label: "notes.txt", isActive: false}},
              {{label: "WebGL Aquarium", isActive: true}},
            ];
            const closeCounts = [];
            let nextLabel = "WebGL Aquarium";
            const vscode = {{
              window: {{
                tabGroups: {{
                  all: [{{tabs}}],
                  close: async (closing) => {{
                    closeCounts.push(closing.length);
                    for (const tab of closing) {{
                      const index = tabs.indexOf(tab);
                      if (index >= 0) tabs.splice(index, 1);
                    }}
                    return true;
                  }},
                }},
              }},
              commands: {{
                executeCommand: async (_command, url) => {{
                  await new Promise(resolve => setTimeout(resolve, 5));
                  tabs.push({{label: nextLabel, isActive: true, url}});
                }},
              }},
              workspace: {{getConfiguration: () => ({{get: () => false}})}},
            }};
            const originalLoad = Module._load;
            Module._load = function(request, parent, isMain) {{
              if (request === "vscode") return vscode;
              return originalLoad.call(this, request, parent, isMain);
            }};
            const extension = require({json.dumps(str(EXTENSION))});
            (async () => {{
              {textwrap.indent(textwrap.dedent(body), '  ')}
            }})().catch(error => {{
              console.error(error?.stack || String(error));
              process.exitCode = 1;
            }});
        """)
        result = subprocess.run(
            ["node", "-e", script], text=True, capture_output=True,
            timeout=20, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return json.loads(result.stdout.strip().splitlines()[-1])

    def test_repeated_urls_replace_previous_owned_and_restored_aquarium_tabs(self):
        observed = self.run_node("""
            await extension._test.enqueueURLRequest(
              "https://webglsamples.org/aquarium/aquarium.html?numFish=1000");
            await extension._test.enqueueURLRequest(
              "https://webglsamples.org/aquarium/aquarium.html?numFish=2000");
            const beforeCleanup = tabs.map(tab => tab.label);
            await extension._test.enqueueURLRequest(
              "macws-control:close-test-webviews-v1");
            console.log(JSON.stringify({
              beforeCleanup,
              afterCleanup: tabs.map(tab => tab.label),
              closeCounts,
            }));
        """)
        self.assertEqual(observed["beforeCleanup"], [
            "notes.txt", "WebGL Aquarium",
        ])
        self.assertEqual(observed["afterCleanup"], ["notes.txt"])
        self.assertEqual(observed["closeCounts"], [1, 1, 1])

    def test_concurrent_requests_are_serialized_to_one_live_test_webview(self):
        observed = self.run_node("""
            await extension._test.closeTestWebviews();
            nextLabel = "Apple";
            await Promise.all([
              extension._test.enqueueURLRequest("https://apple.com/one"),
              extension._test.enqueueURLRequest("https://apple.com/two"),
              extension._test.enqueueURLRequest("https://apple.com/three"),
            ]);
            console.log(JSON.stringify({
              labels: tabs.map(tab => tab.label),
              urls: tabs.map(tab => tab.url ?? null),
              closeCounts,
            }));
        """)
        self.assertEqual(observed["labels"], ["notes.txt", "Apple"])
        self.assertEqual(observed["urls"][-1], "https://apple.com/three")
        self.assertEqual(observed["closeCounts"], [1, 1, 1])

    def test_invalid_request_does_not_poison_queue(self):
        observed = self.run_node("""
            try {
              await extension._test.enqueueURLRequest("file:///etc/passwd");
            } catch (_) {}
            nextLabel = "Apple";
            await extension._test.enqueueURLRequest("https://apple.com/");
            console.log(JSON.stringify({
              labels: tabs.map(tab => tab.label),
              closeCounts,
            }));
        """)
        self.assertEqual(observed["labels"], ["notes.txt", "Apple"])
        self.assertEqual(observed["closeCounts"], [1])


if __name__ == "__main__":
    unittest.main()
