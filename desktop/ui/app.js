"use strict";

const $ = (id) => document.getElementById(id);
const invoke = window.__TAURI__?.core?.invoke;
let phase = "loading";
let pending = false;
let lastView;
let statusEpoch = 0;
let statusKnown = false;

const labels = {
  needsModel: [
    "Installation needs attention",
    "The bundled model could not be verified.",
  ],
  loading: [
    "Getting ready",
    "Verifying the model bundled with this application.",
  ],
  ready: ["Ready when you are", "Start dictation, then speak naturally."],
  recording: [
    "Listening to you",
    "Your microphone is active. No audio is being uploaded.",
  ],
  transcribing: [
    "Finding your words",
    "Processing the recording on this device.",
  ],
  recovery: [
    "Your recording is still here",
    "Retry transcription or discard this recording.",
  ],
};

function render(view) {
  lastView = view;
  phase = view.phase;
  const recording = phase === "recording";
  const ready = phase === "ready";
  $("phase-heading").textContent = labels[phase]?.[0] ?? "Status unavailable";
  $("phase-detail").textContent =
    labels[phase]?.[1] ?? "Please reopen LockedIn Flow.";
  $("capture-title").textContent = recording
    ? "RECORDING ON THIS DEVICE"
    : phase === "transcribing"
      ? "LOCAL TRANSCRIPTION"
      : "MICROPHONE IS OFF";
  $("record").textContent = recording
    ? "Stop and transcribe"
    : phase === "recovery"
      ? "Retry transcription"
      : "Start dictation";
  $("record").disabled =
    pending || !statusKnown || !["ready", "recording", "recovery"].includes(phase);
  $("record").classList.toggle("recording", recording);
  document.querySelector(".capture").classList.toggle("recording", recording);
  const level = Math.max(0, Math.min(1, Number(view.peak) * 4 || 0));
  document.querySelector(".meter").style.setProperty("--level", String(level));
  $("discard").hidden = !["recording", "recovery"].includes(phase);
  $("discard").disabled = pending || !statusKnown;
  $("retry-model").hidden = phase !== "needsModel";
  $("retry-model").disabled = pending || !statusKnown;
  const seconds = Math.max(0, Number(view.seconds) || 0);
  $("timer").textContent =
    `${String(Math.floor(seconds / 60)).padStart(2, "0")}:${String(seconds % 60).padStart(2, "0")}`;
  if ($("status").textContent !== view.message)
    $("status").textContent = view.message;
  if ($("transcript").value !== view.transcript)
    $("transcript").value = view.transcript;
  const words = view.transcript.trim().split(/\s+/u).filter(Boolean).length;
  $("word-count").textContent = `${words} ${words === 1 ? "word" : "words"}`;
  $("copy").disabled =
    pending || !statusKnown || ["loading", "transcribing"].includes(phase) || !view.transcript;
  $("clear").disabled = pending || !statusKnown || !ready || !view.transcript;
  $("apply-vocabulary").disabled = pending || !statusKnown || !ready;
  $("vocabulary").disabled = !ready;
  $("term-count").textContent = `${view.vocabularyCount} terms`;
  $("model-name").textContent = view.model;
}

async function action(name) {
  if (!invoke || pending || !statusKnown) return;
  pending = true;
  statusEpoch++;
  if (lastView) render(lastView);
  try {
    await invoke("perform_action", { action: name });
  } catch {
    $("status").textContent =
      "The action could not be completed. Wait for the current operation and try again.";
  } finally {
    // Read the worker's completed state before unlocking controls, so a second
    // click cannot use the pre-command recording/recovery phase.
    await finishCommand();
  }
}

$("record").addEventListener("click", () =>
  action(
    phase === "recording" ? "stop" : phase === "recovery" ? "retry" : "start",
  ),
);
$("discard").addEventListener("click", () => action("discard"));
$("copy").addEventListener("click", () => action("copy"));
$("clear").addEventListener("click", () => action("clear"));
$("retry-model").addEventListener("click", () => action("reloadModel"));
$("apply-vocabulary").addEventListener("click", async () => {
  if (!invoke || pending || !statusKnown) return;
  pending = true;
  statusEpoch++;
  if (lastView) render(lastView);
  try {
    await invoke("set_vocabulary", { text: $("vocabulary").value });
  } catch {
    $("status").textContent =
      "Vocabulary could not be applied. Check the format and try again.";
  } finally {
    await finishCommand();
  }
});

async function finishCommand() {
  // Ignore polls started before this command completed.
  statusEpoch++;
  try {
    const view = await invoke("get_status");
    statusKnown = true;
    render(view);
  } catch {
    statusKnown = false;
  }
  pending = false;
  if (lastView) render(lastView);
  if (!statusKnown) $("status").textContent =
    "The local engine is not responding. Your last visible transcript is still selectable.";
}

async function refresh() {
  if (!invoke) {
    $("status").textContent =
      "Interface preview only. Open the installed LockedIn Flow application to record.";
    $("phase-heading").textContent = "Desktop interface preview";
    $("phase-detail").textContent =
      "Recording is available in the native app, not in this browser preview.";
    return;
  }
  const epoch = statusEpoch;
  try {
    const view = await invoke("get_status");
    if (epoch === statusEpoch) {
      statusKnown = true;
      render(view);
    }
  } catch {
    if (epoch === statusEpoch) {
      statusKnown = false;
      if (lastView) render(lastView);
      $("status").textContent =
        "The local engine is not responding. Your last visible transcript is still selectable.";
    }
  }
  setTimeout(refresh, 300);
}
refresh();
