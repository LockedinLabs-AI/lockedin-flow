# AI-assisted secure development

LockedIn Flow uses AI-assisted implementation and review with explicit release
controls. This document describes the process and evidence used for the public
LockedIn Flow source. It does not claim a retrospective audit of every development
session or certification of the engineering organization.

## Lifecycle and evidence

| Stage | Required work | Reviewable evidence |
| --- | --- | --- |
| Define | Establish supported platforms, privacy boundary, failure semantics, and measurable acceptance | [Architecture](architecture.md), [threat model](threat-model.md), [compatibility matrix](compatibility.md) |
| Assess | Review new dependencies, licenses, model provenance, and data movement before adoption | [Third-party risk](third-party-risk.md), [model inventory](model-licenses.md), pinned source and model manifests |
| Implement | Keep capture, recognition, text processing, insertion, and storage boundaries explicit; pair fixes with regression tests | Separate Swift targets, [tests](../Tests), change history |
| Challenge | Examine wrong-target insertion, duplicate delivery, insecure fields, clipboard races, key failure, model tampering, and logging disclosure | [Insertion tests](../Tests/InsertionEngineTests), [storage tests](../Tests/VoiceCoreTests), [model tests](../Tests/SpeechEngineTests) |
| Verify | Run formatting, compilation, tests, dependency advisory checks, static analysis, secret scanning, and artifact-policy checks | [CI](../.github/workflows/ci.yml), [Security](../.github/workflows/security.yml), [validation](validation.md) |
| Release | Bind source, dependencies, models, SBOM, signature, and acceptance results to one artifact | [Release process](release-process.md), packaged build provenance and CycloneDX SBOM |
| Respond | Accept private vulnerability reports, investigate impact, add regression coverage, and issue a versioned correction | [Security policy](../SECURITY.md), [changelog](../CHANGELOG.md) |

AI-generated code is subject to the same checks as other contributions. A model
response, a passing test count, or a successful notarization is not evidence of
functional acceptance. Reviewers must inspect changed security boundaries and
test observable behavior. Only synthetic data belongs in prompts, examples,
test fixtures, screenshots, public issues, and published evidence.

## Public-source adversarial review

The September 2026 source hardening examined the following failure paths:

- runtime diagnostics accepting error descriptions or transcript strings;
- automatic and temporary clipboard writes becoming eligible for cross-device
  clipboard transfer;
- test-mode Keychain shortcuts being compiled into release artifacts;
- target replacement and focus movement between recording and insertion;
- duplicate delivery after an uncertain paste receipt;
- microphone interruption and preservation of captured samples;
- unverified model files, unsafe provisioning paths, and partial activation;
- private data in source history, media metadata, or workflow output; and
- new upstream vulnerabilities after a dependency was originally accepted.

The source now restricts logging types, uses device-local clipboard preparation,
excludes test-mode hooks from release compilation, validates targets at delivery,
does not blindly retry ambiguous writes, verifies model inventories, and checks
public history and dependency advisories. Local clipboard readers, compromised
hosts, incorrectly behaving target applications, and undetected defects remain
in the threat model. No independent penetration test is implied by this review.

Installed microphone, application-compatibility, performance, and blocked-network
acceptance are tracked separately in the [validation record](validation.md).

## Standards mapping

The [engineering standards map](project-standards.md) links concrete controls to
OpenSSF practices, NIST SSDF 1.1, and SLSA guidance. Those references inform the
development process; they are not product certifications. Claims must describe
implemented controls and recorded evidence, never controls that exist only in
a roadmap.
