// Build-time only. Sends public upstream commit hashes, never application data.
export function dependencyQueries(resolved, inventory, profile) {
  if (resolved.version !== 3 || !Array.isArray(resolved.pins) || inventory.schemaVersion !== 1) {
    throw new Error("Unsupported dependency inventory.");
  }
  const pins = resolved.pins.map((pin) => {
    const known = profile.swiftPackages.find((entry) => entry.identity === pin.identity);
    if (!known || known.expectedLocation !== pin.location || pin.kind !== "remoteSourceControl") {
      throw new Error("Unreviewed Swift dependency.");
    }
    return { name: pin.identity, commit: pin.state?.revision };
  });
  const vendors = inventory.vendored.map((entry) => {
    const known = profile.vendoredComponents.find((component) => component.name === entry.name);
    if (!known || known.version !== entry.version || known.sourceURL !== entry.repository) {
      throw new Error("Vendored dependency review is out of date.");
    }
    return { name: entry.name, commit: entry.commit };
  });
  if (pins.length !== profile.swiftPackages.length || vendors.length !== profile.vendoredComponents.length) {
    throw new Error("Incomplete dependency inventory.");
  }
  const queries = [...pins, ...vendors];
  if (new Set(queries.map((entry) => entry.name)).size !== queries.length
      || queries.some((entry) => !/^[a-f0-9]{40}$/.test(entry.commit))) {
    throw new Error("Invalid immutable dependency identity.");
  }
  return queries;
}

export async function queryAdvisories(commit, fetcher = fetch) {
  if (!/^[a-f0-9]{40}$/.test(commit)) throw new Error("Invalid commit.");
  return queryIdentity({ commit }, fetcher);
}

export async function queryCrateAdvisories(name, version, fetcher = fetch) {
  if (!/^[a-z0-9_-]{1,64}$/.test(name) || !/^\d+\.\d+\.\d+(?:[-+][a-zA-Z0-9.-]+)?$/.test(version)) {
    throw new Error("Invalid public crate identity.");
  }
  return queryIdentity({ package: { ecosystem: "crates.io", name }, version }, fetcher);
}

async function queryIdentity(identity, fetcher) {
  const ids = new Set();
  const pages = new Set();
  let page;
  for (let attempt = 0; attempt < 20; attempt++) {
    const response = await fetcher("https://api.osv.dev/v1/query", {
      method: "POST", redirect: "error", signal: AbortSignal.timeout(30000),
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ ...identity, ...(page ? { page_token: page } : {}) }),
    });
    if (!response.ok) throw new Error("Advisory service unavailable.");
    const result = await response.json();
    if (!result || typeof result !== "object" || Array.isArray(result)
        || (result.vulns !== undefined && !Array.isArray(result.vulns))) {
      throw new Error("Invalid advisory response.");
    }
    for (const vulnerability of result.vulns ?? []) {
      if (!vulnerability || typeof vulnerability.id !== "string"
          || !/^[A-Za-z0-9._-]{1,128}$/.test(vulnerability.id)) {
        throw new Error("Invalid advisory identifier.");
      }
      if (!vulnerability.withdrawn) ids.add(vulnerability.id);
    }
    const next = result.next_page_token;
    if (next === undefined || next === "") return [...ids].sort();
    if (typeof next !== "string" || next.length > 4096 || pages.has(next)) {
      throw new Error("Invalid advisory pagination.");
    }
    pages.add(next);
    page = next;
  }
  throw new Error("Incomplete advisory scan.");
}
