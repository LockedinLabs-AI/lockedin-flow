# Supplemental upstream notices

`supplemental.json` retains authentic notice bytes from immutable upstream revisions
for six checksum-pinned Cargo packages whose published archives omit these files.
For the first four packages, the original manifest and inspected Rust source files
match the recorded upstream revision exactly. The generator checks the registry, package
version, declared license and Cargo.lock checksum before associating notice text.
The material file and individual UTF-8 notice texts have pinned SHA-256 digests.
No build-time network retrieval is performed by this addition.

For `dlopen2` 0.8.2 and `dlopen2_derive` 0.4.3, the published manifests differ
from the pinned upstream revision only by CRLF versus LF line endings; the derive
package also has that difference in `src/common.rs`. Of the 37 Rust files inspected
in `dlopen2` and five in `dlopen2_derive`, all other files match exactly. Their
published source metadata does not mark the revision dirty. The retained upstream
MIT notice includes its original copyright attributions. `sourceComparison`
records each differing file's distinct published/upstream hashes and upstream Git
blob: this is an explicit line-ending comparison, not byte equality or a general
normalization rule. The generator still requires the exact registry archive
checksum. No source or notice bytes are normalized during the build.

The `dasp_sample` Apache file is a short notice/reference, not the full Apache
license. Its MIT text is retained separately. Neither a notice association nor an
SBOM entry establishes runtime linkage or completes redistribution review.

No supplemental notices are assigned to `audio-core`, `selectors` or `realfft`:
dirty-source provenance or missing full notice text remain unresolved. They must not inherit another
package's license text. Updating the fixed material requires reviewing immutable
upstream provenance, carrier and text identities, then updating the material digest
in `scripts/supplemental-notices.mjs` and running its focused tests. The publication
scanner allows upstream copyright contacts only for the exact pinned material
digest at this path; changes must pass a new attribution review.
