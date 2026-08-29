# Neurocast Tools

This repository is the ReaPack distribution repository for **Neurocast Tools**.
The approved first pre-release package is `Neurocast_Tools` version
`0.1.0-pre1`.

Runtime Lua source and the Neurocast-backend release workflow are owned and
documented in
[Logutin/auphonic-mt](https://github.com/Logutin/auphonic-mt). Native preview
extension source and build evidence are owned by
[Logutin/reaper_cyr_essentials](https://github.com/Logutin/reaper_cyr_essentials).
This repository contains only the ReaPack distribution surface.

The assembled architecture is one self-contained metapackage with exactly six
Main actions: the full `elevenlabs_tool.lua` and
`elevenlabs_manager_tool.lua` entrypoints plus four fixed maintained actions in
`actions-neurocast/` for fast STS, fast TTS, audio-tag insertion, and
audio-tag bracket removal. The target matrix is Windows x64, macOS x86_64,
and macOS ARM64. ReaImGui remains an external prerequisite.

**Current status:** the `0.1.0-pre1` package source tree and metadata are
assembled, pass the local static source checks, and passed the Windows x64
local install/live-test/uninstall qualification on 2026-08-29. macOS x86_64
and ARM64 remain deliberately unqualified. The candidate is suitable for the
next limited internal ReaPack publication milestone, not a broadly qualified
public production release. There is still no repository `index.xml`, tag,
GitHub release, GitHub Actions workflow, signing, or notarization.

See [the release plan](docs/release_plan_neurocast_backend.md) and the
[`0.1.0-pre1` runtime inventory](docs/runtime_inventory_0.1.0-pre1.md). The
complete payload inventory is in [`release-manifest.yml`](release-manifest.yml),
the version-specific input record is in
[`release-source-lock.yml`](release-source-lock.yml), and the dated assembly
record is in
[`docs/2026-08-29_package_implementation_0.1.0-pre1.md`](docs/2026-08-29_package_implementation_0.1.0-pre1.md).
The Windows evidence is in
[`docs/2026-08-29_windows_local_qualification_0.1.0-pre1.md`](docs/2026-08-29_windows_local_qualification_0.1.0-pre1.md).
