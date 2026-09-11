# Neurocast Tools

This is the ReaPack distribution repository for **Neurocast Tools**.
The current published package is **`Neurocast_Tools 0.1.4`**, a limited-internal
release for selected team members, now in team testing (owner report on
2026-09-11).

Install/update through the repository
[`index.xml`](https://raw.githubusercontent.com/Logutin/reaper-reapack-neurocast-tools/main/index.xml).
ReaImGui remains an external prerequisite; package minimum remains REAPER 7.72+.

## Current release: 0.1.4

- AutoMix `v0.1.2` is included in ReaPack for the first time, with collision-safe
  stem extraction and saved result insertion position.
- MVSEP `v0.2.1` adds repeat downloads from completed jobs, new filenames that
  preserve existing files, and explicit manual import.
- Windows ships the matching official 7-Zip `26.03` x64 executable and DLL.
- Six Tools, four Tool Actions, and four Utilities provide 14 Main actions.
  Windows ownership is 68 files. Native extensions, curl, and notices retain
  their previous bytes.

On 2026-09-11 the owner reported all requested live checks passed in
`C:\extra_Reapers\Reaper_Empty_01\reaper.exe`, including the `0.1.3 -> 0.1.4`
update and packaged startup/DOCX/AutoMix/MVSEP checks. The screenshot confirmed
only the helper's source-marker and local 7-Zip checks. Independent readback
verified version `0.1.4`, all 68 installed files byte-for-byte, and exactly 14
Main actions. The owner restored the disposable installation to the public
feed. Final readback verified its cached index against the published feed,
all 68 installed files, and 14 exactly-once Main actions. Manual installation
and the existing global install settings were preserved. Release delivery is complete.

This is owner-reported GUI/workflow acceptance plus agent-run mechanical
verification. It does not establish broad production, difficult-network,
macOS, other-machine, or full lifecycle qualification. AutoMix production-host
and large-upload checks remain open. MVSEP telemetry delivery errors and Script
Aligner ambiguous-create retry duplication remain documented limitations.

Runtime source is pinned to `auphonic-mt` commit
`9d734e197bea078e112c85eebbe7dd5283b0bf39`. All 192 `0.1.4` platform source
records are pinned to distribution payload
`7701c852f3baca5d890e699a422d6d21032fb9d0`. The four historical versions
`0.1.0-pre1`, `0.1.1`, `0.1.2`, and `0.1.3` retain their original records/URLs.
Script/toolset labels retain their independent source version identities.

See the [0.1.4 release record](docs/2026-09-11_package_implementation_0.1.4.md),
[payload manifest](release-manifest.yml), and [source lock](release-source-lock.yml).

## Ownership and package shape

Runtime source and source tests belong to
[Logutin/auphonic-mt](https://github.com/Logutin/auphonic-mt).
Native source/build evidence belongs to
[Logutin/reaper_cyr_essentials](https://github.com/Logutin/reaper_cyr_essentials).
This repository owns selected payload copies, metadata, source lock, and the
generated index. Frozen direct-era sources are not package inputs.

One metapackage targets Windows x64, macOS x86_64, and macOS ARM64. Platform
metadata does not imply live qualification. Tests, qualification helpers,
credentials, telemetry identities, caches, and logs are excluded from delivery.

Historical evidence:
[release plan](docs/release_plan_neurocast_backend.md),
[0.1.1 Windows qualification](docs/2026-08-31_windows_local_qualification_0.1.1.md),
[0.1.2 update/UI smoke](docs/2026-09-02_windows_local_qualification_0.1.2.md),
[0.1.3 release record](docs/2026-09-03_package_implementation_0.1.3.md).
