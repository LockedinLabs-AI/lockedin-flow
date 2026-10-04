import assert from "node:assert/strict";
import test from "node:test";
import { unresolvedGlibAdvisories } from "../scripts/backport-policy.mjs";

test("the verified backport resolves only its exact advisory and known alias", () => {
  assert.deepEqual(
    unresolvedGlibAdvisories(["RUSTSEC-2024-0429", "GHSA-wrw7-89jp-8q8g"]),
    [],
  );
  assert.deepEqual(
    unresolvedGlibAdvisories(["SYNTHETIC-NEW-ADVISORY", "RUSTSEC-2024-0429"]),
    ["SYNTHETIC-NEW-ADVISORY"],
  );
});
