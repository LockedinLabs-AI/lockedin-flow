// Window/process liveness only; this does not claim rendered-content or audio acceptance.
export async function waitForStableWindow({ child, findWindow, now, sleep, timeoutMs = 45000, stableMs = 5000 }) {
  const deadline = now() + timeoutMs;
  let visibleSince;
  while (now() < deadline) {
    if (child.exitCode !== null || child.signalCode !== null) throw new Error("Installed application exited during launch.");
    const visible = await findWindow();
    if (child.exitCode !== null || child.signalCode !== null) throw new Error("Installed application exited during launch.");
    if (visible) {
      visibleSince ??= now();
      if (now() - visibleSince >= stableMs) return;
    } else {
      visibleSince = undefined;
    }
    await sleep(250);
  }
  throw new Error("Installed application window did not remain visible.");
}
