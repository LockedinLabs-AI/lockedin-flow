export function rustHost(output) {
  const host = output
    .split(/\r?\n/)
    .find((line) => line.startsWith("host: "))
    ?.slice(6)
    .trim();
  if (!host || !/^[-a-z0-9_]+$/.test(host))
    throw new Error("A Rust target triple is required.");
  return host;
}

// Git's Windows tar interprets a drive-qualified archive name as a remote host.
// Resolve the working directory first and pass only the local basename.
export function archiveExtraction(directory) {
  return {
    args: ["-xzf", "upstream.crate"],
    options: { cwd: directory, stdio: "pipe" },
  };
}
