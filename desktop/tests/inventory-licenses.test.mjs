import assert from "node:assert/strict";
import test from "node:test";
import { cargoLicenseExpression, assertLicenseExpression, assertInventoryLicenses } from "../scripts/inventory-licenses.mjs";

test("legacy Cargo alternatives become SPDX OR without changing license choice", () => {
  for (const input of ["MIT/Apache-2.0", "MIT / Apache-2.0", "  MIT/Apache-2.0  "])
    assert.equal(cargoLicenseExpression(input), "MIT OR Apache-2.0");
  assert.equal(cargoLicenseExpression("BSD-3-Clause/MIT"), "BSD-3-Clause OR MIT");
  assert.equal(cargoLicenseExpression("MIT/Apache-2.0/Zlib"), "MIT OR Apache-2.0 OR Zlib");
});

test("standard compound terms, exceptions and obligations are preserved", () => {
  for (const input of [
    "(MIT OR Apache-2.0) AND Unicode-3.0",
    "Apache-2.0 AND MIT",
    "GPL-2.0-only WITH Classpath-exception-2.0",
    "MPL-2.0",
  ]) assert.equal(cargoLicenseExpression(input), input);
});

test("ambiguous legacy syntax and invalid terms fail without reflecting input", () => {
  for (const input of ["MIT/Apache-2.0 AND Zlib", "MIT//Apache-2.0", "Unknown-Synthetic-License", "", "MIT\n", "MIT or Apache-2.0", "MIT OR", "x".repeat(1025)]) {
    assert.throws(() => cargoLicenseExpression(input),
      (error) => /license (expression|declaration)/.test(error.message) && !error.message.includes(input || "<empty>"));
  }
  assert.throws(() => cargoLicenseExpression(undefined), /Missing Cargo/);
  assert.throws(() => assertLicenseExpression("MIT\n"), /Invalid inventory/);
});

test("artifact inventory validates the application and every component license", () => {
  const sbom = {
    metadata: { component: { licenses: [{ license: { id: "MIT" } }] } },
    components: [{ licenses: [{ expression: "MIT OR Apache-2.0" }] }],
  };
  assertInventoryLicenses(sbom);
  const invalid = structuredClone(sbom);
  invalid.components[0].licenses[0].expression = "MIT/Apache-2.0";
  assert.throws(() => assertInventoryLicenses(invalid), /Invalid inventory/);
  delete invalid.metadata.component.licenses;
  assert.throws(() => assertInventoryLicenses(invalid), /Missing component/);
});

test("inventory rejects ambiguous choices and compound expressions disguised as IDs", () => {
  for (const licenses of [
    [{ expression: "MIT", license: { id: "MIT" } }],
    [{ expression: "MIT" }, { license: { id: "Apache-2.0" } }],
    [{ license: { id: "MIT OR Apache-2.0" } }],
    [{ license: { id: "GPL-2.0+" } }],
  ]) assert.throws(() => assertInventoryLicenses({ metadata: { component: { licenses } }, components: [] }));
});
