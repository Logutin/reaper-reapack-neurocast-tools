# Neurocast Tools

This repository is the ReaPack distribution repository for **Neurocast Tools**.
The currently published package is `Neurocast_Tools` version `0.1.2`.
All releases are currently limited internal for selected team members; a plain
semantic version does not imply broad production qualification.

Runtime Lua source and the Neurocast-backend release workflow are owned and
documented in
[Logutin/auphonic-mt](https://github.com/Logutin/auphonic-mt). Native preview
extension source and build evidence are owned by
[Logutin/reaper_cyr_essentials](https://github.com/Logutin/reaper_cyr_essentials).
This repository contains only the ReaPack distribution surface.

The assembled architecture is one self-contained metapackage with exactly 13
Main actions: five Tools, four fixed ElevenLabs Tool Actions, and four
Utilities under `utilities-neurocast/`. The target matrix is Windows x64,
macOS x86_64, and macOS ARM64. ReaImGui remains an external prerequisite.

**Current status:** `0.1.2` is published through the repository
[`index.xml`](https://raw.githubusercontent.com/Logutin/reaper-reapack-neurocast-tools/main/index.xml)
and is now **in live testing by the team**. On 2026-09-02, the owner updated the
authorized disposable Windows x64 installation from `0.1.1` to `0.1.2` and
confirmed the packaged MVSEP `script v0.2.0 / toolset v0.2.0` UI, its
time-selection-only queue presentation, absence of Free/Regions controls, and
presence of concurrency and result-placement controls. Headless readback
confirmed the `0.1.2` receipt, 61 owned files, 13 Main actions, and exact bytes
for both changed MVSEP files.

After publication, the disposable installation was read back using the real
raw-GitHub feed with the `0.1.2`, 61-file, 13-Main-action receipt. The owner
then recorded a `0.1.2` demo video for the team and reported that live team
testing is underway. No additional team test results are recorded yet.

This narrow smoke did not repeat uninstall, clean install, authenticated or
remote-job workflows, difficult-network testing, macOS qualification, or
another-user/machine testing. This is not a broadly qualified public production
release. No tag, GitHub release, GitHub Actions workflow, signing, or
notarization was added.

## Current release: 0.1.2

`Neurocast Tools 0.1.2` is a published limited-internal package. It changes only
the packaged `mvsep_tool.lua` and `modules-neurocast/mvsep_reaper.lua` runtime
behavior relative to `0.1.1`, advances the MVSEP script identity to `v0.2.0`,
and retains 13 Main actions: five Tools, four Tool Actions, and four Utilities
under `utilities-neurocast/`. Package minimum remains REAPER 7.72+.

| Concept | Meaning | Naming |
| --- | --- | --- |
| Tool | Substantial user-facing workflow/application | `*_tool.lua` |
| Utility | Standalone, focused, one-shot REAPER operation | `utility_neurocast_*.lua` |
| Tool Action | Thin shortcut into functionality owned by a Tool | `action_neurocast_tools_*.lua` |

The `0.1.2` runtime is frozen from `auphonic-mt` commit
`3b5cb2078afbaa5f7f4b2ca15054065faae98416`. Its published sources are pinned
to distribution candidate commit
`7586b148dafb68a0b5231167bc17fd2586fe4fa0`; index publication commit
`c2cb240e719ef8b192cc92795fe4dae8b7db70fe` preserves the immutable historical
sources and adds `0.1.2`.

The owner supplied and authorized the disposable installation at
`C:\extra_Reapers\Reaper_Empty_01`. The narrow `0.1.1 -> 0.1.2` update/UI smoke
passed there. The broader `0.1.1` lifecycle evidence remains historical and is
not silently promoted to `0.1.2` qualification.

See the dated [`0.1.2` assembly record](docs/2026-09-02_package_implementation_0.1.2.md)
and [`0.1.2` Windows smoke record](docs/2026-09-02_windows_local_qualification_0.1.2.md)
for the dependency closure, evidence boundaries, and gate. The published
`0.1.0-pre1` and `0.1.1` historical sources remain unchanged.

See [the release plan](docs/release_plan_neurocast_backend.md) and the
[`0.1.0-pre1` runtime inventory](docs/runtime_inventory_0.1.0-pre1.md). The
complete payload inventory is in [`release-manifest.yml`](release-manifest.yml),
the version-specific input record is in
[`release-source-lock.yml`](release-source-lock.yml), and the dated assembly
record is in
[`docs/2026-08-29_package_implementation_0.1.0-pre1.md`](docs/2026-08-29_package_implementation_0.1.0-pre1.md).
The Windows evidence is in
[`docs/2026-08-31_windows_local_qualification_0.1.1.md`](docs/2026-08-31_windows_local_qualification_0.1.1.md).
