import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const source = (file) => readFileSync(path.join(root, "Sources/LockedInFlowApp", file), "utf8");

test("model setup is an explicit local guide, not a downloader or recorder", () => {
  const guide = source("ModelSetupView.swift");
  assert.doesNotMatch(guide, /\b(?:Process|URLSession|AVCaptureSession|AudioCaptureManager)\s*[.(]/);
  assert.doesNotMatch(guide, /\.(?:onAppear|task)\s*\{/);
  assert.doesNotMatch(guide, /controller\.|NSWorkspace|requestMicrophoneAccess|requestAccessibilityAccess/);
  assert.match(guide, /Button\("Recheck models"\)\s*\{ Task \{ await state\.prepareModel\(\) \} \}/);
  assert.match(guide, /disabled\(!canRecheck\)/);
  assert.match(guide, /!state\.canRetryFailedDictation/);
});

test("recording never raises an Accessibility permission request", () => {
  const controller = source("DictationController.swift");
  assert.doesNotMatch(controller, /isTrusted\(prompt: true\)/);
  const meeting = controller.split("private func startMeeting() {")[1].split("private func startMeetingWatch()")[0];
  assert.doesNotMatch(meeting, /TextInserter|accessibilityTrusted/);
  assert.match(controller, /if deliveryMode\.requiresAccessibility \{\s*guard TextInserter\.isTrusted\(prompt: false\)/);
  assert.match(controller, /captureDeliveryMode = deliveryMode/);
  assert.match(controller, /let targetSnapshot =\s*captureDeliveryMode\.requiresAccessibility[\s\S]*?: nil/);
});

test("in-app transcripts never invoke external insertion, commands, or automatic clipboard writes", () => {
  const controller = source("DictationController.swift");
  const localCompletion = controller.split("private func completeInAppTranscription(")[1].split("private func recordHistory(")[0];
  assert.doesNotMatch(localCompletion, /inserter\.|writePasteboard|NSPasteboard|commandParser|autoCopyEnabled/);
  assert.match(localCompletion, /state\.lastFinal = final/);
  assert.match(localCompletion, /appName: nil/);
  assert.match(controller, /if context\.deliveryMode\.requiresAccessibility,\s*let command = commandParser/);
  assert.match(controller, /if context\.deliveryMode == \.inApp \{[\s\S]*?completeInAppTranscription\([\s\S]*?return\s*\}\s*await completeInsertion/);
  for (const marker of ["func reinsertLast() {", "func reinsert(\n"]) {
    const entry = controller.split(marker)[1];
    assert.ok(entry.indexOf("guard state.automaticInsertionEnabled") < entry.indexOf("FrontmostTracker.shared.focusLock()"));
  }
});

test("only a correctly named packaged app can request optional Accessibility after explanation", () => {
  const app = source("AppState.swift");
  const request = app.split("func requestAccessibilityAccess() {")[1].split("func useInAppTranscription()")[0];
  assert.equal((app.match(/isTrusted\(prompt: true\)/g) ?? []).length, 1);
  assert.match(request, /guard\s+AccessibilityRequestIdentity\.permitsPrompt/);
  assert.match(request, /guard alert\.runModal\(\) == \.alertFirstButtonReturn, canChangeTranscriptPolicy else \{ return \}/);
  assert.ok(request.indexOf("guard alert.runModal()") < request.indexOf("isTrusted(prompt: true)"));
  assert.match(request, /This is optional/);
  assert.match(request, /broad permission as control of your computer/);
  assert.match(source("OnboardingView.swift"), /No Accessibility access or control of other apps is required/);
});

test("managed guidance does not present source-download commands", () => {
  const guide = source("ModelSetupView.swift");
  assert.match(guide, /if installation == \.managedMac \{\s*managedInstructions\s*\} else \{\s*sourceInstructions/);
  const sourceRoute = guide.split("private var sourceInstructions:")[1].split("private var managedInstructions:")[0];
  const managedRoute = guide.split("private var managedInstructions:")[1].split("private func command(")[0];
  assert.match(sourceRoute, /command\("npm run provision:models"\)/);
  assert.match(sourceRoute, /command\("npm run provision:models -- --repair"\)/);
  assert.match(sourceRoute, /Model licenses are separate/);
  assert.doesNotMatch(managedRoute, /npm run|command\(/);
  assert.match(managedRoute, /approved deployment channel/);
});

test("onboarding completion is guarded and opens home without starting capture", () => {
  const completion = source("AppState.swift").split("func completeOnboarding() {")[1].split("func quit()")[0];
  assert.match(completion, /guard firstDictationReadiness\.canFinish, !isMarketingPreview else \{ return \}/);
  assert.match(completion, /closeOnboarding\(\)/);
  assert.match(completion, /showHomeWindow\(\)/);
  assert.doesNotMatch(completion, /controller|Task|requestMicrophoneAccess|requestAccessibilityAccess/);
  assert.match(source("WindowOpener.swift"), /func closeOnboarding\(\) \{\s*windows\.removeValue\(forKey: "onboarding"\)\?\.close\(\)/);
});

test("first-run controls have explicit keyboard and accessibility semantics", () => {
  const guide = source("ModelSetupView.swift");
  const onboarding = source("OnboardingView.swift");
  assert.match(guide, /keyboardShortcut\(\.cancelAction\)/);
  assert.match(guide, /keyboardShortcut\(\.defaultAction\)/);
  assert.match(guide, /textSelection\(\.enabled\)/);
  assert.match(guide, /accessibilityAddTraits\(\.isHeader\)/);
  assert.match(onboarding, /Button\("Review permissions"\) \{ page = 1 \}/);
  assert.match(onboarding, /Button\("Open LockedIn Flow"\)/);
  assert.match(onboarding, /Picker\("Setup step", selection: \$page\)/);
  assert.ok(onboarding.includes('accessibilityLabel("Allow \\(title) access")'));
  assert.match(onboarding, /if !state\.isMarketingPreview \{ startPermissionPolling\(\) \}/);
  for (const view of ["HomeView.swift", "MenuBarView.swift", "OnboardingView.swift"]) {
    assert.match(source(view), /showModelSetup\(state: state\)/);
  }
});
