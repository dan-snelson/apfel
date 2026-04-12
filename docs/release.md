# Release Process

## Overview

apfel uses semantic versioning. Releases are fully automated through GitHub Actions. Local builds (`make build`, `make install`) never change the version number.

## The release flow

```
make preflight              local qualification (git, build, tests, policy files)
       |
       v pass
make release [TYPE=]        dispatch GitHub Actions
       |
       v workflow runs on macos-26
  bump .version
       |
  build release binary
       |
  unit tests (335+)
       |
  integration tests (7 suites)
       |
  commit + tag + push
       |
  package tarball + publish GitHub Release
       |
  update Homebrew tap formula
       |
       v
./scripts/post-release-verify.sh
```

## Before releasing

```bash
make preflight
```

The preflight script checks:
- Git working tree is clean
- On main branch, up to date with origin
- Release build succeeds
- Unit tests pass (335+)
- Integration tests pass (7 suites: cli_e2e, performance, openai_client, openapi_spec, security, mcp_server, openapi_conformance)
- SECURITY.md, STABILITY.md, LICENSE exist
- Binary version matches .version

Do not release if preflight fails.

## Release commands

```bash
make release                    # patch bump (1.0.0 -> 1.0.1)
make release TYPE=minor         # minor bump (1.0.x -> 1.1.0)
make release TYPE=major         # major bump (1.x.y -> 2.0.0)
```

This dispatches the Publish Release GitHub Actions workflow.

## What the workflow does

1. Bumps `.version` via `make release-patch` / `release-minor` / `release-major`
2. Regenerates `Sources/BuildInfo.swift` and README version badge
3. Builds the release binary on `macos-26`
4. Runs unit tests (`swift run apfel-tests`)
5. Starts servers and runs 7 integration test suites
6. Commits `.version`, `README.md`, `Sources/BuildInfo.swift`, tags, and pushes to main
7. Packages `apfel-<version>-arm64-macos.tar.gz`
8. Publishes GitHub Release with changelog and tarball
9. Updates the Homebrew tap formula (`Arthur-Ficial/homebrew-tap`)

Total time: ~5 minutes.

## After releasing

```bash
./scripts/post-release-verify.sh
```

Verifies: GitHub Release exists with tarball, git tag exists, .version matches, installed binary matches.

## Homebrew distribution

apfel is currently distributed through the custom tap:

```bash
brew tap Arthur-Ficial/tap
brew install apfel
brew upgrade apfel
```

The release workflow automatically updates the tap formula with each release.

### homebrew-core transition (pending)

PR #276365 is pending to add apfel to homebrew-core. Once accepted:
- Install simplifies to `brew install apfel` (no tap needed)
- homebrew-core autobump picks up new releases automatically
- Remove tap update steps from publish-release.yml
- Update all install docs to remove tap references

## One-time setup

The `HOMEBREW_TAP_PUSH_TOKEN` secret must exist on `Arthur-Ficial/apfel`:

1. Create a fine-grained GitHub token with **Contents: Read and write** access to `Arthur-Ficial/homebrew-tap`
2. Store it:
   ```bash
   gh secret set HOMEBREW_TAP_PUSH_TOKEN --repo Arthur-Ficial/apfel
   ```

## Versioning rules

apfel follows semver. See [STABILITY.md](../STABILITY.md) for the full stability policy.

- **PATCH** (1.0.x): bug fixes, documentation, CI improvements
- **MINOR** (1.x.0): new flags, new endpoints, backward-compatible features
- **MAJOR** (x.0.0): removed flags, changed exit codes, breaking API changes

Model output changes from macOS updates are NOT version bumps.

## What triggers a release

- Bug fix merged -> patch
- New flag or endpoint merged -> minor
- Accumulation of small improvements -> patch
- Breaking change to CLI/API contract -> major (update STABILITY.md)

## What does NOT trigger a release

- Docs-only changes (commit to main, no release needed)
- CI/workflow changes (commit to main, no release needed)
- Test-only changes (commit to main, no release needed)

## What NOT to do

- Do not run `bump-patch`, `bump-minor`, `bump-major` directly
- Do not manually edit `.version`, `BuildInfo.swift`, or the README badge
- Do not create git tags manually
- Do not run `gh release create` manually
- Do not push to the Homebrew tap manually (the workflow handles it)
- Do not run `make package-release-asset` outside the workflow
