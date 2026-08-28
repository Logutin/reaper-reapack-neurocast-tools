# Neurocast Tools

This repository is the ReaPack distribution repository for **Neurocast Tools**.
The approved first pre-release package is `Neurocast_Tools` version
`0.1.0-pre1`.

Runtime Lua source and the Neurocast-backend release workflow are owned and
documented in
[Logutin/auphonic-mt](https://github.com/Logutin/auphonic-mt). Native preview
extension source and build evidence are owned by
[Logutin/reaper_cyr_essentials](https://github.com/Logutin/reaper_cyr_essentials).
This repository will contain only the ReaPack distribution surface.

The planned architecture is one self-contained metapackage with exactly six
Main actions: the full `elevenlabs_tool.lua` and
`elevenlabs_manager_tool.lua` entrypoints plus four fixed maintained actions in
`actions-neurocast/` for fast STS, fast TTS, audio-tag insertion, and
audio-tag bracket removal. The target matrix is Windows x64, macOS x86_64,
and macOS ARM64. ReaImGui remains an external prerequisite.

**Current status:** planning and inventory only. No installable package,
package metadata, or ReaPack index has been assembled or published yet.

See [the release plan](docs/release_plan_neurocast_backend.md) and the
[`0.1.0-pre1` runtime inventory](docs/runtime_inventory_0.1.0-pre1.md).
