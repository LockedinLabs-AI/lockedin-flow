# Engineering and publication standards

LockedIn Flow is developed for reviewable, on-device voice input. This page
connects the project's practices to established open-source and software supply
chain guidance. It is an implementation map, not a certification or a badge.

See the [AI-assisted development lifecycle](secure-development.md) and
[third-party risk register](third-party-risk.md) for operational ownership,
adversarial-review scope, and evidence boundaries.

## Product engineering contract

These are release requirements, not a claim that every candidate already meets
them. The approach follows the evidence-linked practices in
[Agent Console's engineering principles](https://github.com/LockedinLabs-AI/agent-console/blob/211f00598af4bcbabc329ee3ad6f1089b275868b/docs/PRINCIPLES.md),
adapted for an offline desktop application. We reuse the standard, not another
product's test results or network architecture.

| Promise | Required proof in LockedIn Flow | Release boundary |
| --- | --- | --- |
| An ordinary person can install it | Test the actual published download and documented installation steps on a clean supported machine; verify version, model availability, first dictation, and uninstall | A build or source-setup command alone is insufficient |
| Speech processing stays local | Pinned model identity, offline runtime policy, synthetic speech with networking denied, and exact-artifact network observation | Include OS/webview processes and destination/clipboard policies; setup networking is separate |
| Dictation survives ordinary disruption | Recovery regression tests and repeated physical microphone, sleep/wake, focus-change, and meeting-app coexistence checks | No lost completed transcript, duplicate delivery, or unsafe insertion in the accepted matrix; refusals are recorded separately |
| Permissions are understandable and minimal | Branded first-use prompts; record/review/Copy without Accessibility; explicit opt-in for automatic typing | No background permission grants or requests from an unbranded executable |
| Source and dependencies are inspectable | Clear module boundaries, locked inputs, license notices, reviewed model manifests, SBOM, and dependency/advisory checks | State inventory/scanner coverage and record unresolved exceptions |
| Changes are reviewable | Focused commits, regression tests, required independent review, protected branches, and security-boundary documentation | AI review supplements, rather than impersonates, an independent maintainer |
| Downloads are verifiable | Exact source and artifact hashes, signing, provenance, versioned release notes, and download-byte verification | Evaluation-artifact attestations do not cover a later signed release |
| Claims match the product | Current screenshots with synthetic examples; keyboard/screen-reader checks; published support matrix and measured performance | Do not turn a successful build, illustration, or planned feature into an acceptance claim |
| The project can be maintained | Private vulnerability reporting, dependency monitoring, documented upgrade/rollback/removal, support ownership, and a supported-version policy | Do not promise response-time guarantees or long-term support without staffed ownership |

Tests, source, and procedures for these requirements are linked in
[Validation evidence](validation.md), [Compatibility](compatibility.md),
[Release process](release-process.md), and the [desktop port](../desktop/README.md).
A portable source tree is not universal desktop support: each operating-system,
architecture, installer, and feature combination earns its own acceptance.

### Reuse across LockedIn Labs projects

For each new open-source product, publish the same small set of reviewable
answers: what it does, what it reads/writes/transmits, how to install and remove
it, which platforms actually passed, how each important promise is tested, how
to verify a download, and who handles defects. Keep the evidence next to the
implementation and bind release results to an exact revision and artifact.

Apply controls where the product has the relevant boundary. Agent Console needs
authenticated reporting and network isolation; LockedIn Flow's core dictation
does not need a server, accounts, SSO, or a listener. Adding those solely to look
enterprise-oriented would enlarge its security and operational surface.

## Reference practices

| Reference | Application in this project | Evidence |
| --- | --- | --- |
| [OpenSSF Best Practices](https://www.bestpractices.dev/en/criteria/0) | Clear licensing, build instructions, contribution and vulnerability-reporting paths, versioned releases, tests, and static analysis | [MIT License](../LICENSE), [getting started](getting-started.md), [contributing](../CONTRIBUTING.md), [security policy](../SECURITY.md), [CI](../.github/workflows/ci.yml) |
| [NIST Secure Software Development Framework 1.1](https://csrc.nist.gov/pubs/sp/800/218/final) | Document boundaries, review sensitive code, protect release integrity, minimize defaults, and address defects with regression tests | [Threat model](threat-model.md), [CODEOWNERS](../.github/CODEOWNERS), [release process](release-process.md), [tests](../Tests) |
| [SLSA supply chain guidance](https://slsa.dev/spec/v1.1/levels) | Record source and dependency identity, generate an SBOM, and attest the exact produced artifact | [Build workflow](../.github/workflows/ci.yml), [SBOM validation](../scripts/validate-sbom.sh), [validation status](validation.md) |
| [GitHub repository publication guidance](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/managing-repository-settings/setting-repository-visibility) | Review the complete publication surface, including history, author metadata, issues, pull requests, workflow logs, and artifacts | Publication process below |

The project does not claim an OpenSSF badge, SLSA level, regulatory
certification, or completed enterprise acceptance. Platform-specific dependencies
and outstanding validation are recorded in [model licenses](model-licenses.md)
and [validation evidence](validation.md).

## Public material

Only product source, synthetic tests, reviewed visuals, build tooling, and
public documentation belong in the repository. Do not add chat exports,
recordings, transcript logs, internal handoffs, personal files, customer data,
credentials, or generated build output.

Run `npm run check:public` before a pull request. The check rejects common private
file types, personal contact patterns, machine-specific paths, conversation
exports, unreviewed binary assets, and broken local documentation links. Its
output contains rule names and hashed file identifiers, never matching content
or unreviewed file paths. An entry identifier is the first 12 characters of the
SHA-256 of the repository-relative path; resolve it locally when investigating.

The [Public metadata workflow](../.github/workflows/public-metadata.yml) also
checks pull-request titles and descriptions on creation, edits, and code updates.
It detects the publication policy's private-content patterns and a narrow set of
credential shapes, without printing matched text or validating secrets online.
It runs without repository secrets or privileged pull-request execution. It
does not scan issue comments, recognize all confidential prose, or erase text
already posted publicly. Review before posting; a failed check requires private
incident triage and credential rotation when applicable, not merely editing the
description until it turns green.

Run `npm run check:public -- --history` against the complete proposed publication
history before first publication. Use a full clone: a shallow clone cannot prove
what earlier revisions contain. TruffleHog independently checks credential
patterns. Neither automated check can determine whether every natural-language
paragraph is private; a maintainer must review text, fixtures, visuals, and
metadata as well.

Visuals must come from the product with synthetic examples, or be explicitly
labeled as illustrations. Raster assets have an explicit reviewed hash inventory.
Any change requires a new visual and metadata review before updating that hash.
Copyright attribution in third-party notices is retained.

The developer preview renderer produces the product views using synthetic
fixtures. `node scripts/sanitize-public-media.mjs` removes ancillary PNG metadata
from the reviewed asset paths without changing compressed pixel data. Review
the output and update `security/public-media.json` explicitly; the sanitizer
does not approve its own output.

## Initial publication

1. Review the exact candidate tree and intended public documentation.
2. Export only that tree into a new, unrelated repository when the source history
   contains material outside the public product. Do not copy Git internals,
   workflow logs, discussions, issues, or pull requests from a private project.
3. Scan every reachable revision and review commit metadata. Maintainers use an
   approved public identity and corporate or GitHub private email address.
4. Configure least-privilege Actions, required review and checks, CODEOWNERS,
   branch protection, secret scanning, and private vulnerability reporting.
5. Obtain owner approval of the actual sanitized candidate before changing
   visibility. Record source, tree, and artifact identities in the release record.
6. Publish a signed application only after the separate artifact and installed
   acceptance gates pass. Source availability does not imply a binary release.

Repository access settings and branch protections are hosting configuration;
their presence must be checked on GitHub, not inferred from a workflow file.

## Operational privacy

Application diagnostics use fixed event messages and numeric or boolean
metadata. The logging API does not accept interpolated strings; error logging
retains only a numeric code, excluding descriptions, domains, user information,
file paths, app identities, and dictated content. Developer-only transcription
diagnostics are excluded from production binaries and require synthetic inputs.

Model provisioning is a separate, explicit setup step. Application runtime has
no updater, telemetry client, inbound listener, or hosted inference adapter.
Enterprise deployments pre-stage models and enforce their own network policy.
The receiving application follows its own data policy after insertion.
