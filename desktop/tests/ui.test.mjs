import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import test from "node:test";

const source = readFileSync(new URL("../ui/app.js", import.meta.url), "utf8");
const initial = {
  phase: "ready",
  transcript: "",
  message: "Ready.",
  seconds: 0,
  peak: 0,
  vocabularyCount: 0,
  model: "Synthetic test model",
};
async function surface(view, native = true) {
  const elements = new Map();
  const calls = [];
  const element = (id) => {
    if (!elements.has(id))
      elements.set(id, {
        textContent: "",
        value: "",
        disabled: true,
        hidden: false,
        listeners: {},
        classList: { toggle() {} },
        style: { setProperty() {} },
        addEventListener(type, fn) {
          this.listeners[type] = fn;
        },
      });
    return elements.get(id);
  };
  vm.runInNewContext(source, {
    window: native
      ? {
          __TAURI__: {
            core: {
              invoke: async (command, arguments_) => {
                calls.push([command, arguments_]);
                return command === "get_status" ? view : undefined;
              },
            },
          },
        }
      : {},
    document: { getElementById: element, querySelector: element },
    setTimeout() {},
  });
  await new Promise(setImmediate);
  return { element, calls };
}

test("browser preview cannot record or impersonate a ready native engine", async () => {
  const ui = await surface(initial, false);
  assert.equal(ui.element("record").disabled, true);
  assert.match(ui.element("status").textContent, /preview only/);
  await ui.element("record").listeners.click();
  assert.equal(ui.calls.length, 0);
});

test("recording and recovery expose the correct explicit actions", async () => {
  for (const [phase, action, label] of [
    ["ready", "start", "Start dictation"],
    ["recording", "stop", "Stop and transcribe"],
    ["recovery", "retry", "Retry transcription"],
  ]) {
    const ui = await surface({ ...initial, phase });
    assert.equal(ui.element("record").textContent, label);
    assert.equal(ui.element("record").disabled, false);
    await ui.element("record").listeners.click();
    assert.deepEqual(ui.calls.map(([command]) => command), ["get_status", "perform_action", "get_status"]);
    assert.equal(ui.calls[1][1].action, action);
  }
});

test("processing keeps the previous transcript selectable without queuing more actions", async () => {
  const ui = await surface({
    ...initial,
    phase: "transcribing",
    transcript: "Synthetic previous result.",
  });
  for (const id of [
    "record",
    "copy",
    "clear",
    "vocabulary",
    "apply-vocabulary",
  ])
    assert.equal(ui.element(id).disabled, true);
  assert.equal(ui.element("transcript").value, "Synthetic previous result.");
  assert.equal(ui.element("discard").hidden, true);
});

test("transcript content remains plain text, and copy is never automatic", async () => {
  const value = '<img src="invalid" onerror="invalid">';
  const ui = await surface({ ...initial, transcript: value });
  assert.equal(ui.element("transcript").value, value);
  assert.deepEqual(
    ui.calls.map(([command]) => command),
    ["get_status"],
  );
  await ui.element("copy").listeners.click();
  assert.deepEqual(ui.calls.map(([command]) => command), ["get_status", "perform_action", "get_status"]);
  assert.equal(ui.calls[1][1].action, "copy");
});
