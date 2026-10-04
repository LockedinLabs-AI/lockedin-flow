# Contributing

Thank you for helping improve LockedIn Flow. Keep changes focused, explain the
user impact, and include evidence appropriate to the risk.

## Before opening a pull request

Use a public fork for contribution branches. Upstream branch creation is
restricted to approved automation, and existing upstream branches reject force
pushes. Never push a private development checkout or private Git history here.

1. Open an issue for a material feature or behavior change so the security and
   compatibility boundary can be discussed first.
2. Use synthetic examples only. Never include credentials, personal data,
   customer data, protected health information, production recordings, or
   private screenshots.
3. Add or update tests for changed behavior.
4. Run:

   ```bash
   npm ci --ignore-scripts --no-audit --no-fund
   npm test
   npm run check:public
   swift build --force-resolved-versions
   swift build -c release --product lockedin-flow --force-resolved-versions
   swift test --force-resolved-versions
   scripts/test-sbom.sh
   scripts/test-production-binary-policy.sh
   scripts/test-runtime-network-policy.sh
   ```

5. Document changes that affect permissions, network access, storage,
   Accessibility behavior, dependencies, or release artifacts.

## Security rules

- Secure or unverifiable fields must fail closed.
- Never log transcript, audio, clipboard, or credential content.
- Use the content-free `FlowLog` API. It accepts fixed text, numeric values,
  booleans, and numeric error codes; never add string interpolation for paths,
  app identities, error descriptions, or user content.
- Do not add telemetry or a network dependency without an explicit threat-model
  and data-flow update.
- Keep diagnostic command paths out of release binaries.
- Pin GitHub Actions to immutable commits and review dependency license changes.

Report vulnerabilities privately through [SECURITY.md](SECURITY.md), not a
public issue.

## Contribution licensing

Contributions are licensed to recipients under this repository's MIT License.
By submitting a contribution, you certify that you authored it or otherwise
have the right to submit it under those terms. Add a `Signed-off-by` line to each
commit using `git commit -s`; this records agreement with the
[Developer Certificate of Origin 1.1](https://developercertificate.org/).

Do not contribute third-party material unless its license is compatible, its
provenance is documented, and required notices are included. Contributions do
not grant rights to LockedIn Labs or LockedIn Flow trademarks or protected brand
assets.
