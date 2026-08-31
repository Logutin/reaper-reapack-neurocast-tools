# Neurocast Tools 0.1.1 candidate assembly

> **Source snapshot warning:** This record describes the candidate assembled on
> 2026-08-31. Re-check current commits, hashes, index contents, and qualification
> state before using it for a later release.

## Status

`Neurocast Tools 0.1.1` is assembled but not yet published. The repository's
root `index.xml` still exposes only the immutable `0.1.0-pre1` release.

This release remains limited internal for selected team members. The plain
version does not claim broad production readiness.

## Frozen sources

- Runtime repository: `Logutin/auphonic-mt`
- Runtime commit: `109e5d138b0f459319caa849b6684e602acfe629`
- Runtime Lua policy: 53 selected files copied byte-for-byte
- Windows curl: 8.13.0 x64, existing pinned hash
- Windows 7-Zip: 26.00 x64 executable and matching DLL, existing pinned hashes
- Native preview extension: unchanged pinned Windows/macOS artifacts and build
  evidence from the `0.1.0-pre1` package
- Component notices: unchanged pinned texts from the `0.1.0-pre1` package

## Candidate shape

The metapackage has 13 Main actions:

- five Tools: ElevenLabs, Manager, DOCX Import, Script Aligner, and MVSEP;
- four fixed ElevenLabs Tool Actions;
- four standalone Utilities under `utilities-neurocast/`.

The Lua closure is 53 files: 13 Main actions and 40 support modules. The
platform-scoped `@provides` matrix contains 171 rows:

- win64: 61;
- darwin64: 55;
- darwin-arm64: 55.

Package minimum is REAPER 7.72+.

## Verification completed before installed-package qualification

- Both source and distribution repositories were clean, on `main`, and aligned
  with their respective `origin/main` before assembly.
- Every selected Lua destination matches its frozen source bytes.
- All 53 Lua files pass `luac -p`.
- `reapack-index --check --strict --warnings` reports zero failures.
- Manifest closure is exactly 53 Lua files with no missing or extra destination.
- All ten pinned non-Lua inputs match their recorded sizes and SHA-256 hashes.
- No telemetry identity, credential artifact, test fixture, generated wrapper,
  Network Fault Lab, or FakeReaper file is present.
- Bundled curl reports 8.13.0.
- Bundled 7-Zip reports 26.00 and lists `word\document.xml` from the qualified
  DOCX fixture using the release-local executable and DLL pair.

## Live evidence and explicit deferrals

The owner authorized only the disposable installation at
`C:\extra_Reapers\Reaper_Empty_01`.

The owner confirmed the staged DOCX Tool's clean two-row import and all four
Utilities' focused real-REAPER behavior. The Merge check verified two selected
items became one three-second item with ordered notes, and the temporary test
objects were removed with prior selection restored.

No authenticated test account exists for this cycle. ElevenLabs, Manager,
MVSEP, and Script Aligner authenticated workflows are therefore explicitly
unqualified for `0.1.1`; they were not simulated. Existing earlier live results
remain historical evidence and do not become fresh package qualification.

macOS, signing/notarization, difficult-network behavior, prior legacy-install
migration, and another-user or another-machine testing also remain unqualified.

## Known technical debt

Script Aligner remains the explicit backend-target exception and uses
`https://studio.neurocast.tech`. Its create POST remains within a generic retry
surface, so an ambiguous response can cause a duplicate alignment. This is an
accepted non-blocker for the limited-internal release. Operators must inspect
existing Studio jobs before retrying an ambiguous create failure.

## Remaining gate

Before `0.1.1` is exposed in the public ReaPack index, qualify the candidate's
Windows update/clean-install/uninstall behavior in the authorized disposable
REAPER, verify 13 registered Main actions and package-owned cleanup, then run a
real raw-GitHub feed delivery check. Record every deferred scope without
upgrading the claim beyond limited internal.
