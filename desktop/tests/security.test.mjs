import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import test from "node:test";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const read = (file) => readFileSync(path.join(root, file), "utf8");
const config = JSON.parse(read("app/tauri.conf.json"));

test("all installer identities use the actual product and publisher", () => {
  assert.equal(config.productName, "LockedIn Flow");
  assert.equal(config.bundle.publisher, "LockedIn Labs");
  assert.equal(config.identifier, "ai.lockedin.flow.desktop");
  assert.deepEqual(config.bundle.targets, [
    "nsis",
    "msi",
    "deb",
    "rpm",
    "appimage",
  ]);
  assert.equal(config.bundle.windows.allowDowngrades, false);
  assert.equal(config.bundle.windows.wix.version, "0.5.0.1");
  assert.equal(
    config.bundle.windows.wix.upgradeCode,
    "c010de70-43e8-51b6-a898-a970f9133c31",
  );
});

test("Windows installation does not download WebView2 on the endpoint", () => {
  assert.equal(
    config.bundle.windows.webviewInstallMode.type,
    "offlineInstaller",
  );
  assert.equal(config.bundle.windows.nsis.installMode, "currentUser");
  assert.ok(config.bundle.resources["resources/models/ggml-base.en.bin"]);
});

test("generated notices distinguish build inventory from redistributed platform payloads", () => {
  const generator = read("scripts/generate-inventory.mjs");
  assert.ok(generator.includes("not an extracted installer inventory or complete redistribution-notice review"));
  assert.ok(generator.includes("Windows offline WebView2 installer is a redistributed input, distinct from the installed shared Evergreen runtime"));
  assert.ok(generator.includes("AppImage can bundle native libraries and webview helpers"));
  assert.doesNotMatch(generator, /System libraries and the operating-system webview are administered separately/);
});

test("the native bridge has only three window-scoped commands", () => {
  const capability = JSON.parse(read("app/capabilities/dictation.json"));
  assert.deepEqual(capability.windows, ["main"]);
  assert.deepEqual(capability.permissions, [
    "allow-get-status",
    "allow-perform-action",
    "allow-set-vocabulary",
  ]);
  assert.equal(capability.remote, undefined);
  const csp = config.app.security.csp;
  assert.ok(csp.includes("default-src 'none'"));
  assert.ok(csp.includes("connect-src ipc: http://ipc.localhost"));
  assert.ok(csp.includes("form-action 'none'"));
  assert.doesNotMatch(csp, /https:|unsafe-eval|unsafe-inline|\*/);
  assert.equal(config.app.windows[0].devtools, false);
  assert.equal(config.app.windows[0].create, false);
  assert.match(
    read("app/src/main.rs"),
    /\.on_navigation\(allowed_navigation\)/,
  );
});

test("the model allowlist is pinned and matches the native verifier", () => {
  const model = JSON.parse(read("models.json"));
  const source = read("engine/src/model.rs");
  assert.match(model.url, /\/resolve\/[a-f0-9]{40}\/ggml-base\.en\.bin$/);
  assert.match(model.sha256, /^[a-f0-9]{64}$/);
  assert.ok(source.includes(model.sha256));
  assert.ok(source.includes(model.file));
  assert.ok(
    source.includes(model.size.toLocaleString("en-US").replaceAll(",", "_")),
  );
  assert.match(read("engine/src/speech.rs"), /new_from_buffer_with_params/);
  assert.doesNotMatch(read("engine/src/speech.rs"), /new_with_params/);
});

test("runtime code has no remote inference, shell, telemetry, or updater adapter", () => {
  const walk = (dir) =>
    readdirSync(path.join(root, dir), { withFileTypes: true }).flatMap(
      (entry) =>
        entry.isDirectory()
          ? walk(`${dir}/${entry.name}`)
          : [`${dir}/${entry.name}`],
    );
  for (const file of ["app/src", "core/src", "engine/src", "ui"].flatMap(
    walk,
  )) {
    if (!/\.(rs|js|html)$/.test(file)) continue;
    assert.doesNotMatch(
      read(file),
      /reqwest|ureq|TcpStream|TcpListener|std::process::Command|tauri_plugin_(http|shell|updater)|\bfetch\s*\(|XMLHttpRequest|WebSocket|sendBeacon|localStorage|sessionStorage|indexedDB/,
    );
  }
});

test("transcription does not log or render transcript markup", () => {
  const speech = read("engine/src/speech.rs");
  for (const flag of ["special", "progress", "realtime", "timestamps"])
    assert.ok(speech.includes(`set_print_${flag}(false)`));
  assert.ok(speech.includes("install_logging_hooks"));
  assert.doesNotMatch(
    read("ui/app.js"),
    /innerHTML|outerHTML|insertAdjacentHTML|\beval\(/,
  );
  assert.ok(
    read("ui/app.js").includes('$("transcript").value = view.transcript'),
  );
  assert.ok(read("ui/index.html").includes('aria-live="polite"'));
});

test("build tools have no automatic install hooks", () => {
  const pkg = JSON.parse(read("package.json"));
  assert.equal(pkg.private, true);
  for (const hook of ["preinstall", "install", "postinstall", "prepare"])
    assert.equal(pkg.scripts[hook], undefined);
  assert.equal(pkg.devDependencies["@tauri-apps/cli"], "2.12.0");
  const cpu = read(".cargo/config.toml");
  for (const flag of [
    "WHISPER_CURL",
    "WHISPER_FFMPEG",
    "WHISPER_BUILD_SERVER",
    "GGML_RPC",
    "GGML_BACKEND_DL",
    "GGML_NATIVE",
    "GGML_SSE42",
    "GGML_BMI2",
    "GGML_AVX",
    "GGML_AVX2",
    "GGML_AVX512",
    "GGML_FMA",
    "GGML_F16C",
  ])
    assert.ok(cpu.includes(`${flag} = { value = "OFF", force = true }`));
});

test("explicit clipboard writes request platform privacy exclusions", () => {
  const worker = read("app/src/worker.rs");
  assert.match(
    worker,
    /copy_with_privacy_hints\(clipboard, self\.session\.transcript\(\)\)/,
  );
  assert.doesNotMatch(worker, /\.set_text\(/);
  assert.match(
    worker,
    /use arboard::SetExtWindows;\s*setter\.exclude_from_monitoring\(\)/,
  );
  assert.match(
    worker,
    /use arboard::SetExtLinux;\s*setter\.exclude_from_history\(\)/,
  );
});
