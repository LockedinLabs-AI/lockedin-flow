import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import test from "node:test";

const source = readFileSync(new URL("../ui/app.js", import.meta.url), "utf8");
const view = (phase) => ({ phase, message: "Synthetic state", transcript: "Synthetic text", seconds: 1, peak: 0, vocabularyCount: 0, model: "Synthetic model" });
const deferred = () => { let resolve, reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no; }); return { promise, resolve, reject }; };
const tick = () => new Promise((resolve) => setImmediate(resolve));
function interfaceFor(invoke) {
  const elements = new Map();
  const element = (id) => {
    if (!elements.has(id)) elements.set(id, { textContent: "", value: "", disabled: false, handlers: {},
      classList: { toggle() {} }, style: { setProperty() {} }, addEventListener(event, callback) { this.handlers[event] = callback; } });
    return elements.get(id);
  };
  const timers = [];
  vm.runInNewContext(source, { document: { getElementById: element, querySelector: element },
    window: { __TAURI__: { core: { invoke } } }, setTimeout: (callback) => timers.push(callback) });
  return { element, timers, click: (id) => element(id).handlers.click() };
}

test("Stop stays locked until worker acknowledgement and completed state arrive", async () => {
  const completion = deferred(), updated = deferred();
  let reads = 0, commands = 0;
  const ui = interfaceFor((name) => {
    if (name === "get_status") return ++reads === 1 ? Promise.resolve(view("recording")) : updated.promise;
    commands++; return completion.promise;
  });
  await tick();
  const stop = ui.click("record");
  assert.equal(ui.element("record").disabled, true);
  await ui.click("record");
  assert.equal(commands, 1);
  completion.resolve(); await tick();
  await ui.click("record");
  assert.equal(commands, 1);
  updated.resolve(view("ready")); await stop;
  assert.equal(ui.element("record").textContent, "Start dictation");
  assert.equal(ui.element("record").disabled, false);
});

test("an old poll cannot restore the pre-command recording state", async () => {
  const oldPoll = deferred(); let reads = 0;
  const ui = interfaceFor((name) => {
    if (name !== "get_status") return Promise.resolve();
    reads++; return reads === 2 ? oldPoll.promise : Promise.resolve(view(reads === 1 ? "recording" : "ready"));
  });
  await tick();
  const poll = ui.timers.shift()();
  await ui.click("record");
  oldPoll.resolve(view("recording")); await poll;
  assert.equal(ui.element("record").textContent, "Start dictation");
});

test("lost status disables commands without erasing the visible transcript", async () => {
  let reads = 0, commands = 0;
  const ui = interfaceFor((name) => {
    if (name === "get_status") return ++reads === 1 ? Promise.resolve(view("recording")) : Promise.reject(new Error("synthetic"));
    commands++; return Promise.resolve();
  });
  await tick(); await ui.click("record"); await ui.click("record");
  assert.equal(commands, 1);
  assert.equal(ui.element("record").disabled, true);
  assert.equal(ui.element("transcript").value, "Synthetic text");
});

test("vocabulary submission cannot queue a second command while pending", async () => {
  const completion = deferred(); let commands = 0;
  const ui = interfaceFor((name) => {
    if (name === "get_status") return Promise.resolve(view("ready"));
    commands++; return completion.promise;
  });
  await tick(); const applying = ui.click("apply-vocabulary");
  await ui.click("apply-vocabulary"); await ui.click("record");
  assert.equal(commands, 1);
  completion.resolve(); await applying;
  assert.equal(ui.element("apply-vocabulary").disabled, false);
});
