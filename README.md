# Neurocast Tools

This is the ReaPack distribution repository for **Neurocast Tools**.
The current published package is `Neurocast_Tools 0.1.3`, a limited-internal
update for selected team members, not a broadly qualified production release.

Install/update through the repository
[`index.xml`](https://raw.githubusercontent.com/Logutin/reaper-reapack-neurocast-tools/main/index.xml).
ReaImGui remains an external prerequisite; package minimum remains REAPER 7.72+.

## Current release: 0.1.3

- ElevenLabs Manager `v0.1.3`: local name/username/email filtering with retained
  sorting, filtered/total counts, and explicit empty states.
- ElevenLabs `v2.1.1`: permanent voice deletion removed from the client UI,
  workflow, and request builder. Manager `Block` still removes only an account
  assignment. Backend enforcement against older clients is separate work.
- Unchanged binaries, native extension, other tools, and action inventory.
  The new filter helper increases Windows ownership from 61 to 62 files.

The owner confirmed the Windows `0.1.2 -> 0.1.3` update/UI smoke on 2026-09-03
in `C:\extra_Reapers\Reaper_Empty_01`. Readback verified all 62 installed files
against the frozen candidate and exactly 13 registered Main actions. The full
manager source checklist was separately owner-confirmed earlier that day.
The disposable installation's switch back from the candidate index to the
published feed and final readback remain pending.

This narrow gate did not repeat clean install, uninstall, remote generation,
broad authenticated workflows, difficult-network, macOS, or another-machine
testing. The prior `0.1.2` release was reported in live team testing; no wider
team outcome is inferred for `0.1.3`. No tag, GitHub Release, signing,
notarization, or release CI is added.

Runtime source is frozen at `auphonic-mt` commit
`7c7def2d31526fa6cd0f9fd387c246ed44a34e21`. Every `0.1.3` source URL is pinned
to distribution candidate `04be44ea863067e0b7f645899404fb4bdb9497e8`.
The historical `0.1.0-pre1`, `0.1.1`, and `0.1.2` version records and source
URLs remain unchanged.

See the [0.1.3 release record](docs/2026-09-03_package_implementation_0.1.3.md),
[payload manifest](release-manifest.yml), and [source lock](release-source-lock.yml).

## Ownership and package shape

Runtime Lua source, source tests, and release policy belong to
[Logutin/auphonic-mt](https://github.com/Logutin/auphonic-mt).
Native extension source/build evidence belongs to
[Logutin/reaper_cyr_essentials](https://github.com/Logutin/reaper_cyr_essentials).
This repository owns the selected payload copies, metadata, source lock, and
generated ReaPack index. Frozen direct-era sources are not package inputs.

One metapackage exposes 13 Main actions: five Tools (`*_tool.lua`), four
ElevenLabs Tool Actions (`action_neurocast_tools_*`), and four standalone
Utilities (`utility_neurocast_*`). The target matrix is Windows x64, macOS
x86_64, and macOS ARM64; target support does not imply live qualification.

Historical design and evidence:
[release plan](docs/release_plan_neurocast_backend.md),
[0.1.1 Windows qualification](docs/2026-08-31_windows_local_qualification_0.1.1.md),
[0.1.2 update/UI smoke](docs/2026-09-02_windows_local_qualification_0.1.2.md).
