const vscode = require("vscode");
const fs = require("fs");
const net = require("net");

const urlSocketPath = "/private/tmp/macws_vscode_url.sock";
const lifecycleReceiptPath = "/private/tmp/macws_vscode_webview_lifecycle.json";
const maximumURLBytes = 8192;
const closeTestWebviewsRequest = "macws-control:close-test-webviews-v1";
const ownedWebTabs = new Set();
let requestQueue = Promise.resolve();
const lifecycleStats = {
  schema: "macws-vscode-webview-lifecycle-v1",
  requests: 0,
  openedTabs: 0,
  closedTabs: 0,
};

function allTabs() {
  return vscode.window.tabGroups.all.flatMap(group => group.tabs);
}

function restoredAquariumTabs() {
  // The private URL route cannot recover object identity after VS Code has
  // restored a previous session.  The Aquarium document title is the narrow
  // persistent ownership witness; ordinary Simple Browser pages and editor
  // tabs remain outside this cleanup boundary.
  return allTabs().filter(tab => tab.label === "WebGL Aquarium");
}

function writeLifecycleReceipt(event) {
  const temporaryPath = `${lifecycleReceiptPath}.${process.pid}`;
  const receipt = {
    ...lifecycleStats,
    event,
    timestamp: new Date().toISOString(),
    ownedTabs: [...ownedWebTabs].filter(tab => allTabs().includes(tab)).length,
    visibleAquariumTabs: restoredAquariumTabs().length,
  };
  try {
    fs.writeFileSync(temporaryPath, `${JSON.stringify(receipt)}\n`, {mode: 0o600});
    fs.renameSync(temporaryPath, lifecycleReceiptPath);
  } catch (error) {
    try { fs.unlinkSync(temporaryPath); } catch (_) {}
    console.error("MACWS webview lifecycle receipt failed", error);
  }
}

async function closeTestWebviews() {
  const liveTabs = new Set(allTabs());
  for (const tab of ownedWebTabs) {
    if (!liveTabs.has(tab)) ownedWebTabs.delete(tab);
  }
  const candidates = [...new Set([
    ...[...ownedWebTabs].filter(tab => liveTabs.has(tab)),
    ...restoredAquariumTabs(),
  ])];
  if (candidates.length === 0) {
    writeLifecycleReceipt("close-none");
    console.log("MACWS test webview cleanup closed 0 tab(s)");
    return 0;
  }
  const closed = await vscode.window.tabGroups.close(candidates, true);
  if (!closed) {
    throw new Error(`failed to close ${candidates.length} MacWS test webview(s)`);
  }
  for (const tab of candidates) ownedWebTabs.delete(tab);
  lifecycleStats.closedTabs += candidates.length;
  writeLifecycleReceipt("close");
  console.log(`MACWS test webview cleanup closed ${candidates.length} tab(s)`);
  return candidates.length;
}

function validatedWebURL(value) {
  if (typeof value !== "string" || value.length === 0) return undefined;
  try {
    const parsed = new URL(value);
    if ((parsed.protocol !== "http:" && parsed.protocol !== "https:") ||
        parsed.username || parsed.password) return undefined;
    return parsed.toString();
  } catch {
    return undefined;
  }
}

async function openWebURL(value) {
  const url = validatedWebURL(value);
  if (!url) throw new Error("MacWS rejected an invalid web URL");

  // simpleBrowser.show always creates a new webview.  Replace the preceding
  // socket-owned page instead of accumulating one Chromium renderer and AGX
  // resource graph for every profiling request.  Also retire Aquarium tabs
  // restored from the disposable profile before opening an ordinary page.
  await closeTestWebviews();
  const before = new Set(allTabs());
  await vscode.commands.executeCommand("simpleBrowser.show", url);
  const created = allTabs().filter(tab => !before.has(tab));
  for (const tab of created) ownedWebTabs.add(tab);
  if (created.length === 0) {
    throw new Error("Simple Browser resolved without publishing a new tab");
  }
  lifecycleStats.openedTabs += created.length;
  writeLifecycleReceipt("open");
  console.log(
    `MACWS web URL accepted by Simple Browser; tracking ${created.length} new tab(s)`,
  );
}

function handleURLRequest(value) {
  if (value === closeTestWebviewsRequest) return closeTestWebviews();
  return openWebURL(value);
}

function enqueueURLRequest(value) {
  // A burst of controller requests must not take its before/after tab
  // snapshots concurrently.  Keep the queue live after a rejected request so
  // one bad URL cannot permanently disable the private endpoint.
  lifecycleStats.requests += 1;
  const operation = requestQueue.then(
    () => handleURLRequest(value),
    () => handleURLRequest(value),
  );
  requestQueue = operation.catch(() => undefined);
  return operation;
}

function removeOwnedSocket() {
  try {
    const status = fs.lstatSync(urlSocketPath);
    if (status.isSocket()) fs.unlinkSync(urlSocketPath);
  } catch (error) {
    if (error?.code !== "ENOENT") {
      console.error("MACWS URL socket cleanup failed", error);
    }
  }
}

function createURLServer() {
  removeOwnedSocket();
  const server = net.createServer((socket) => {
    let bytes = Buffer.alloc(0);
    let expectedLength;
    let completed = false;
    const reject = (error) => {
      if (completed) return;
      completed = true;
      console.error("MACWS URL request rejected", error);
      socket.end(Buffer.from([0]));
    };
    socket.setTimeout(10000, () => reject(new Error("request timed out")));
    socket.on("error", (error) => {
      if (!completed) console.error("MACWS URL connection failed", error);
      completed = true;
    });
    socket.on("data", (chunk) => {
      if (completed) return;
      bytes = Buffer.concat([bytes, chunk]);
      if (expectedLength === undefined && bytes.length >= 4) {
        expectedLength = bytes.readUInt32BE(0);
        bytes = bytes.subarray(4);
        if (expectedLength === 0 || expectedLength > maximumURLBytes) {
          reject(new Error(`invalid URL byte count ${expectedLength}`));
          return;
        }
      }
      if (expectedLength === undefined || bytes.length < expectedLength) return;
      if (bytes.length !== expectedLength) {
        reject(new Error("URL request contains trailing bytes"));
        return;
      }
      completed = true;
      const value = bytes.toString("utf8");
      enqueueURLRequest(value).then(
        () => socket.end(Buffer.from([1])),
        (error) => {
          completed = false;
          reject(error);
        },
      );
    });
  });
  server.on("error", (error) => {
    console.error("MACWS URL server failed", error);
  });
  server.listen(urlSocketPath, () => {
    fs.chmod(urlSocketPath, 0o600, (error) => {
      if (error) console.error("MACWS URL socket chmod failed", error);
    });
    console.log(`MACWS URL server listening at ${urlSocketPath}`);
  });
  return server;
}

async function openAquarium() {
  const configuration = vscode.workspace.getConfiguration("macwsAquarium");
  const url = configuration.get("url");
  if (typeof url !== "string" || !url.startsWith("https://")) {
    throw new Error(`macwsAquarium.url must be an HTTPS URL, got: ${url}`);
  }

  // simpleBrowser.show is the built-in extension's public command.  VS Code
  // hides it from the desktop command palette with `when: isWeb`, but command
  // execution still activates the extension and creates a normal webview
  // panel.  This keeps the workbench renderer alive instead of navigating it
  // away through CDP, which VS Code immediately detects and replaces.
  await openWebURL(url);
}

async function ensureOneAquarium(createIfMissing = true) {
  const restored = restoredAquariumTabs();
  if (restored.length === 0) {
    if (createIfMissing) await openAquarium();
    return;
  }

  // Keep the already-active Aquarium when there is one; otherwise retain the
  // newest restored panel.  Close only duplicate benchmark webviews.  This is
  // an ownership fix, not a memory-pressure fallback: every duplicate is a
  // complete renderer and native-AGX resource graph created by this extension.
  const keeper = restored.find(tab => tab.isActive) ?? restored.at(-1);
  ownedWebTabs.add(keeper);
  const duplicates = restored.filter(tab => tab !== keeper);
  if (duplicates.length > 0) {
    const closed = await vscode.window.tabGroups.close(duplicates, true);
    if (!closed) {
      throw new Error(`failed to close ${duplicates.length} duplicate Aquarium tabs`);
    }
  }
  console.log(
    `MACWS Aquarium reused restored tab; closed ${duplicates.length} duplicate(s)`,
  );
}

async function convergeToOneAquarium() {
  // onStartupFinished can precede VS Code's asynchronous editor restoration.
  // The first pass may legitimately see no webview and create the benchmark;
  // two later, bounded passes only prune duplicates after restored tabs have
  // entered tabGroups.  Later passes never create another panel.
  await ensureOneAquarium(true);
  await new Promise(resolve => setTimeout(resolve, 3000));
  await ensureOneAquarium(false);
  await new Promise(resolve => setTimeout(resolve, 4000));
  await ensureOneAquarium(false);
}

function activate(context) {
  const urlServer = createURLServer();
  context.subscriptions.push({
    dispose: () => {
      urlServer.close();
      removeOwnedSocket();
    },
  });
  context.subscriptions.push(
    vscode.commands.registerCommand("macwsAquarium.open", openAquarium),
  );

  const configuration = vscode.workspace.getConfiguration("macwsAquarium");
  if (configuration.get("openOnStartup")) {
    // onStartupFinished means the workbench is available, but the built-in
    // Simple Browser extension may still be completing activation.  Queueing
    // one short delay avoids racing its command registration without adding
    // a retry loop to the benchmark path.
    const timer = setTimeout(() => {
      convergeToOneAquarium().catch((error) => {
        console.error("MACWS Aquarium startup failed", error);
      });
    }, 1500);
    context.subscriptions.push({ dispose: () => clearTimeout(timer) });
  }
}

function deactivate() {}

module.exports = {
  activate,
  deactivate,
  _test: {
    closeTestWebviews,
    enqueueURLRequest,
    openWebURL,
  },
};
