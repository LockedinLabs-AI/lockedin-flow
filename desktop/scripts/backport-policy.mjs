// Two database identities for the same upstream defect, not a package-wide waiver.
// https://github.com/advisories/GHSA-wrw7-89jp-8q8g references RUSTSEC-2024-0429.
export function unresolvedGlibAdvisories(ids) {
  const fixed = new Set(["RUSTSEC-2024-0429", "GHSA-wrw7-89jp-8q8g"]);
  return ids.filter((id) => !fixed.has(id));
}
