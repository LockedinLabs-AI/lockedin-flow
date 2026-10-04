export function linkerPrivacyFlags(platform) {
  // MSVC's CodeView record is written by the linker, not compiler path remapping.
  return platform === "win32" ? ["-C", "link-arg=/PDBALTPATH:%_PDB%"] : [];
}

export function sourcePathMappings(mappings, platform) {
  const result = [];
  for (const [from, to] of mappings) {
    if (!from || !to || /[\x00-\x1f";]/.test(from + to))
      throw new Error("Unsupported compiler path mapping.");
    // Rust remapping is textual; Windows build tools use both separator forms.
    const forms = new Set(platform === "win32" ? [from, from.replaceAll("\\", "/")] : [from]);
    for (const form of forms) result.push([form, to]);
  }
  return result;
}

export function nativePrivacyFlags(mappings, platform) {
  return sourcePathMappings(mappings, platform).map(([from, to]) =>
    `${platform === "win32" ? "/clang:" : ""}-ffile-prefix-map=${from}=${to}`);
}

export function nativeCxxFlags(platform) {
  // clang-cl does not enable C++ exceptions by default; ggml requires them.
  return platform === "win32" ? ["/utf-8", "/EHsc"] : [];
}

export function nativeCompilerEnvironment(environment, mappings, platform) {
  const env = { ...environment };
  const flags = nativePrivacyFlags(mappings, platform).map((flag) => `"${flag}"`).join(" ");
  if (platform === "win32") {
    // clang-cl retains the MSVC ABI while supporting source-macro remapping.
    // Pass quoted flags directly to CMake, avoiding cc-rs whitespace splitting.
    env.CC = "clang-cl";
    env.CXX = "clang-cl";
    env.CMAKE_GENERATOR = "Ninja";
    env.CMAKE_C_FLAGS = [env.CMAKE_C_FLAGS, env.CFLAGS, flags].filter(Boolean).join(" ");
    env.CMAKE_CXX_FLAGS = [env.CMAKE_CXX_FLAGS, env.CXXFLAGS, ...nativeCxxFlags(platform), flags].filter(Boolean).join(" ");
  } else {
    // Preserve the existing cc-rs flag layout on Unix; do not quote the option
    // name itself, because cc-rs' default parser passes those quotes literally.
    const unixFlags = sourcePathMappings(mappings, platform)
      .map(([from, to]) => `-ffile-prefix-map="${from}"=${to}`).join(" ");
    env.CFLAGS = [env.CFLAGS, unixFlags].filter(Boolean).join(" ");
    env.CXXFLAGS = [env.CXXFLAGS, unixFlags].filter(Boolean).join(" ");
  }
  return env;
}

// Return classifications only. Raw paths and surrounding binary contents must
// never become diagnostics in a public build log.
export function privatePathFindings(binary, prefixes) {
  const findings = [];
  for (const { scope, prefix } of prefixes) {
    if (!["home", "checkout"].includes(scope) || !prefix || prefix.length < 3)
      throw new Error("Invalid artifact privacy boundary.");
    const forms = new Set([prefix, prefix.replaceAll("\\", "/")]);
    for (const form of forms) {
      for (const encoding of ["utf8", "utf16le"]) {
        const needle = Buffer.from(form, encoding);
        const kinds = new Map();
        let position = binary.indexOf(needle);
        while (position >= 0) {
          const codeView = encoding === "utf8" && position >= 24 &&
            binary.subarray(position - 24, position - 20).equals(Buffer.from("RSDS"));
          const kind = codeView ? "debug-symbol-reference" : "source-or-data";
          kinds.set(kind, (kinds.get(kind) ?? 0) + 1);
          position = binary.indexOf(needle, position + needle.length);
        }
        for (const [kind, count] of kinds) findings.push({ scope, encoding, kind, count });
      }
    }
  }
  return findings;
}
