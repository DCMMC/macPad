# VS Code test-webview lifecycle and heat containment — 2026-09-30

## Finding

The production URL socket reached `openWebURL()` in
`misc/vscode-aquarium-runner/extension.js`. Before this change, that function
called `simpleBrowser.show` for every request and had no close operation. The
only duplicate pruning lived in the separate `openOnStartup` path, while the
production setting has `macwsAquarium.openOnStartup=false`. This is the source
path used by the repeated Aquarium profiling requests.

The user's visible observation was three to four simultaneous Aquarium tabs.
This change does not assign a numerical share of the earlier heat to those tabs
without an intentionally hot multi-tab A/B. The existing runtime control in
`docs/ui-performance-profiler-20260811.md` independently measured one
still-running Aquarium tree at 95.05% of one CPU core while the foreground
Terminal scene itself was idle, so leaving multiple autonomous WebGL pages is
not an acceptable test-harness state.

## Upstream lifecycle fix

- Each private-socket URL request first closes the preceding socket-owned
  webview and any `WebGL Aquarium` tabs restored by the disposable profile.
- Requests are serialized across the close/snapshot/open transaction, so a
  concurrent burst cannot create multiple untracked pages.
- The explicit `macws-control:close-test-webviews-v1` request closes the final
  page after evidence collection.
- `macws_frame_power_profile.py --cleanup-command` runs that request after a
  successful profile and through `atexit` after an exception or interruption.
- Cleanup is ownership-scoped. Unrelated editor and user-opened Simple Browser
  tabs are not selected.

This is a resource-lifetime repair, not a frame-rate cap, timer throttle, or
thermal-response bypass.

## Runtime acceptance on iPad `100.102.101.80`

The updated extension was installed in both the packaged asset and live
production extension directory, then VS Code was relaunched. Three sequential
Aquarium URLs (1000, 1100, and 1200 fish) produced these atomic receipts:

```json
{"requests":1,"openedTabs":1,"closedTabs":0,"event":"open","ownedTabs":1,"visibleAquariumTabs":0}
{"requests":2,"openedTabs":2,"closedTabs":1,"event":"open","ownedTabs":1,"visibleAquariumTabs":0}
{"requests":3,"openedTabs":3,"closedTabs":2,"event":"open","ownedTabs":1,"visibleAquariumTabs":0}
```

The exact close request then produced:

```json
{"requests":4,"openedTabs":3,"closedTabs":3,"event":"close","ownedTabs":0,"visibleAquariumTabs":0}
```

These are runtime-confirmed via
`/private/tmp/macws_vscode_webview_lifecycle.json`: every replacement retired
its predecessor, no more than one socket-owned test page was live, and the
final cleanup retired that last page.

Over the following ten seconds, the cumulative CPU times for the final Simple
Browser renderer PID 27560 stayed at `0:00.83 -> 0:00.83`; the Electron main
process changed `0:04.09 -> 0:04.10`, MacWSHost `0:10.39 -> 0:10.42`, and
WindowServer `0:19.51 -> 0:19.69`. The effective temperature declined from
36.69 C to 36.50 C and remained `thermal-state=nominal`. The complete GUI stack
was then stopped with `cleanup_all.sh`; only `macwshostd` remained.

## Regression gates

- Three Node-backed lifecycle tests cover sequential replacement, concurrent
  request serialization, explicit final close, and queue recovery after a bad
  URL.
- Full mirror suite: 588 tests passed, 13 skipped.
- Runtime-switch audit: 286 environment names, 83 flag files, 441 entries.
