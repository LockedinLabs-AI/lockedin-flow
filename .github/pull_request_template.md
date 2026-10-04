## Summary

Describe the change and the user impact.

Review the title and description before posting: no private chats, real
transcripts, machine paths, personal contact details, or credentials. Automated
checks can detect some patterns after submission; they cannot undo disclosure.

## Security and privacy impact

- [ ] No change to permissions, network access, storage, logging, clipboard use, or target verification
- [ ] Any changed boundary is documented in `docs/security.md` and `docs/threat-model.md`
- [ ] Examples and fixtures are synthetic and contain no credentials, customer data, or protected health information

## Verification

- [ ] `npm ci --ignore-scripts --no-audit --no-fund && npm test`
- [ ] `npm run check:public` and visual/metadata review for changed images
- [ ] `swift build --force-resolved-versions`
- [ ] `swift build -c release --product lockedin-flow --force-resolved-versions`
- [ ] `swift test --force-resolved-versions`
- [ ] `scripts/test-sbom.sh`
- [ ] `scripts/test-production-binary-policy.sh`
- [ ] `scripts/test-runtime-network-policy.sh`

List any additional installed-app checks and their environment.
