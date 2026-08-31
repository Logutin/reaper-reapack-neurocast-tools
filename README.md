# Neurocast Tools

This repository is the ReaPack distribution repository for **Neurocast Tools**.
The currently published package is `Neurocast_Tools` version `0.1.0-pre1`.
All releases are currently limited internal for selected team members; future
plain versions such as `0.1.1` do not imply broad production qualification.

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

**Current status:** `0.1.0-pre1` is published through the repository
[`index.xml`](https://raw.githubusercontent.com/Logutin/reaper-reapack-neurocast-tools/main/index.xml)
for limited internal testing. Windows x64 passed local qualification and a
clean install from that real GitHub feed on 2026-08-29. macOS x86_64 and ARM64,
prior-version update, legacy-install migration, and another-user or
another-machine testing remain unqualified or pending. This is not a broadly
qualified public production release. No tag, GitHub release, GitHub Actions
workflow, signing, or notarization was added for this milestone.

## Release candidate: 0.1.1

`Neurocast Tools 0.1.1` is an assembled limited-internal candidate, not yet a
published package. It preserves the existing Manager and four fixed ElevenLabs
Tool Actions and contains 13 Main actions total: five Tools, four Tool Actions,
and four Utilities under `utilities-neurocast/`. Package minimum is REAPER
7.72+.

| Concept | Meaning | Naming |
| --- | --- | --- |
| Tool | Substantial user-facing workflow/application | `*_tool.lua` |
| Utility | Standalone, focused, one-shot REAPER operation | `utility_neurocast_*.lua` |
| Tool Action | Thin shortcut into functionality owned by a Tool | `action_neurocast_tools_*.lua` |

The Script Aligner ambiguous-create duplicate risk is accepted documented
technical debt and is not a blocker for this limited-internal release. The
`0.1.1` payload, manifest, source lock, and metapackage metadata are assembled
from `auphonic-mt` commit `109e5d138b0f459319caa849b6684e602acfe629`.
The published `index.xml` still exposes only `0.1.0-pre1`; `0.1.1` has not yet
been indexed, published, tagged, or released.

The owner supplied and authorized the disposable installation at
`C:\extra_Reapers\Reaper_Empty_01`. Pre-assembly Windows checks passed for DOCX
Import and all four Utilities. Authenticated Tool requalification is explicitly
deferred because no test account is available; macOS and broader reliability,
migration, and another-machine scopes remain unqualified.

See the dated
[`0.1.1` release plan](docs/2026-08-31_future_release_0.1.1.md) and
[`0.1.1` assembly record](docs/2026-08-31_package_implementation_0.1.1.md) for
the dependency closure, evidence boundaries, and gates. The published
`0.1.0-pre1` payload and its immutable historical sources remain unchanged.

See [the release plan](docs/release_plan_neurocast_backend.md) and the
[`0.1.0-pre1` runtime inventory](docs/runtime_inventory_0.1.0-pre1.md). The
complete payload inventory is in [`release-manifest.yml`](release-manifest.yml),
the version-specific input record is in
[`release-source-lock.yml`](release-source-lock.yml), and the dated assembly
record is in
[`docs/2026-08-29_package_implementation_0.1.0-pre1.md`](docs/2026-08-29_package_implementation_0.1.0-pre1.md).
The Windows evidence is in
[`docs/2026-08-29_windows_local_qualification_0.1.0-pre1.md`](docs/2026-08-29_windows_local_qualification_0.1.0-pre1.md).
