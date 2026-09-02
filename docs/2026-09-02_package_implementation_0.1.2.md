# Neurocast Tools 0.1.2 candidate assembly

> **Source snapshot warning:** This record describes the `0.1.2` candidate
> assembled from the repositories and release decision as of 2026-09-02.
> Re-check current commits, hashes, index contents, installed receipts, and
> qualification state before using it for a later release.

## Status

`Neurocast Tools 0.1.2` is an unpublished limited-internal candidate. The
public `index.xml` must remain at the published `0.1.1` state until the owner
reports that the minimal disposable-REAPER update/UI smoke passed.

This candidate is intended to start deeper testing by selected team members.
It is not broad public production qualification.

## Frozen sources

- Runtime repository: `Logutin/auphonic-mt`.
- Runtime commit: `3b5cb2078afbaa5f7f4b2ca15054065faae98416`.
- Runtime Lua policy: all 53 selected files match the commit-qualified source
  content after the source repository Git clean filter. The two changed MVSEP
  runtime files are byte-exact source blobs. Thirteen unchanged distribution
  files retain their historical CRLF bytes so the approved runtime delta is not
  widened merely to normalize line endings; the exact list is recorded in
  `release-source-lock.yml`.
- Changed runtime blobs relative to `0.1.1`:
  `scr/mvsep_tool.lua` and `scr/modules-neurocast/mvsep_reaper.lua`.
- Windows curl and 7-Zip inputs: unchanged pinned `0.1.1` inputs.
- Native preview extension and component notices: unchanged pinned `0.1.1`
  inputs.

The MVSEP script identity advances from `v0.1.0` to `v0.2.0`. The ReaPack
package version is independently `0.1.2`; unchanged scripts do not receive
artificial implementation-version bumps.

## Candidate shape

The package remains one metapackage with 13 Main actions: five Tools, four Tool
Actions, and four Utilities. The Lua closure remains 53 files: 13 Main actions
and 40 support modules. The platform-scoped `@provides` matrix remains 171
rows: 61 for Windows x64 and 55 for each macOS architecture. Package minimum
remains REAPER 7.72+.

The changed MVSEP scope removes Free/project-regions modes, queues only a
selected-track time selection, renders when queued, persists normalized `1`-`4`
concurrency, and imports results below the retained source or starting at a
captured existing track. The direct MVSEP track is not part of this package and
was not changed.

Direct and Neurocast module trees have known intentional drift; detailed parity
analysis was not performed for this release.

## Required deterministic checks

Before the owner-run smoke, verify:

- the source lock resolves to the clean pushed runtime commit;
- all 53 selected Lua destinations match their commit-qualified source content
  after the source clean filter, with the two changed MVSEP blobs matching
  byte-for-byte and the 13 recorded historical CRLF files remaining unchanged;
- every Lua file passes `luac -p`;
- strict ReaPack validation passes;
- the manifest closure and 171 platform rows remain exact;
- all pinned binaries, notices, and native files retain their recorded sizes
  and SHA-256 hashes;
- release-local curl and 7-Zip checks pass;
- telemetry identities, credentials, tests, generated wrappers, Network Fault
  Lab files, FakeReaper files, and qualification helpers are excluded from the
  package.

## Deliberately minimal Windows gate

The owner authorized only
`C:\extra_Reapers\Reaper_Empty_01\reaper.exe` and requested no Computer Use.
The supplied Lua helper is not part of the package. It must:

- stop outside that exact REAPER resource path;
- configure/open the local candidate feed only when the candidate payload is
  not installed;
- verify installed `v0.2.0` markers and required dependencies;
- open the packaged MVSEP UI without creating, selecting, renaming, moving, or
  modifying tracks, items, time selections, or other project state.

The owner performs the smallest useful visual check and reports the result. No
remote MVSEP job is required. Clean install, uninstall, authenticated workflow
requalification, difficult-network testing, macOS, another user/machine,
signing, notarization, tags, GitHub Releases, and CI release automation remain
unqualified or out of scope.

If the smoke passes, the permitted claim is: Windows `0.1.1 -> 0.1.2` update/UI
smoke passed for limited-internal team testing. Do not call `0.1.2` broadly
Windows-qualified, workflow-qualified, production-ready, or broadly
public-qualified.
