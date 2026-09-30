// Measure requestAnimationFrame cadence inside the one live TestUFO target.
// This is intentionally read-only: it neither navigates the page nor creates
// another benchmark tab, so repeated profiling cannot multiply GPU load.

import process from "node:process";

const endpoint = process.argv[2] || "http://127.0.0.1:19223";
const durationMilliseconds = Math.max(
  500, Math.min(Number(process.argv[3] || 3000), 10000));

const targets = await (await fetch(`${endpoint}/json/list`, {
  headers: {Host: "127.0.0.1:9222"},
})).json();
const candidates = targets.filter((target) => target.type === "page" &&
  /(^|\.)testufo\.com\/?/i.test(new URL(target.url).hostname) &&
  target.webSocketDebuggerUrl);
if (candidates.length !== 1) {
  throw new Error(`expected exactly one TestUFO target, found ${candidates.length}`);
}

const target = candidates[0];
const socketURL = target.webSocketDebuggerUrl.replace(
  /^ws:\/\/127\.0\.0\.1:\d+/, endpoint.replace(/^http/, "ws"));
const socket = new WebSocket(socketURL);
let nextID = 1;
const pending = new Map();
socket.addEventListener("message", (event) => {
  const message = JSON.parse(String(event.data));
  if (message.id === undefined) return;
  const waiter = pending.get(message.id);
  if (!waiter) return;
  pending.delete(message.id);
  message.error ? waiter.reject(new Error(JSON.stringify(message.error)))
                : waiter.resolve(message.result);
});
await new Promise((resolve, reject) => {
  socket.addEventListener("open", resolve, {once: true});
  socket.addEventListener("error", reject, {once: true});
});
function send(method, params = {}) {
  const id = nextID++;
  const result = new Promise((resolve, reject) => {
    pending.set(id, {resolve, reject});
  });
  socket.send(JSON.stringify({id, method, params}));
  return result;
}

await send("Runtime.enable");
const response = await send("Runtime.evaluate", {
  expression: `(async () => {
    const duration = ${JSON.stringify(durationMilliseconds)};
    const intervals = [];
    let first = 0;
    let last = 0;
    await new Promise((resolve) => {
      const started = performance.now();
      const tick = (timestamp) => {
        if (!first) first = timestamp;
        if (last) intervals.push(timestamp - last);
        last = timestamp;
        if (performance.now() - started >= duration) resolve();
        else requestAnimationFrame(tick);
      };
      requestAnimationFrame(tick);
    });
    const sorted = intervals.slice().sort((left, right) => left - right);
    const percentile = (fraction) => sorted.length
      ? sorted[Math.min(sorted.length - 1,
          Math.max(0, Math.ceil(sorted.length * fraction) - 1))]
      : 0;
    const elapsed = Math.max(0, last - first);
    return {
      title: document.title,
      visibility: document.visibilityState,
      focused: document.hasFocus(),
      samples: intervals.length,
      elapsed_ms: elapsed,
      average_fps: elapsed > 0 ? intervals.length * 1000 / elapsed : 0,
      interval_ms: {
        p50: percentile(0.50),
        p95: percentile(0.95),
        p99: percentile(0.99),
        maximum: sorted.length ? sorted[sorted.length - 1] : 0,
      },
      gaps_over_12_5_ms: intervals.filter((value) => value > 12.5).length,
      gaps_over_20_ms: intervals.filter((value) => value > 20).length,
      device_pixel_ratio: devicePixelRatio,
      viewport: [innerWidth, innerHeight],
    };
  })()`,
  awaitPromise: true,
  returnByValue: true,
});
socket.close();
if (response.exceptionDetails) {
  throw new Error(JSON.stringify(response.exceptionDetails));
}
console.log(JSON.stringify({
  target_count: candidates.length,
  target: {id: target.id, title: target.title, url: target.url},
  renderer: response.result.value,
}, null, 2));
