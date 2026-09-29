# Neurocast Tools

The current published package is **`Neurocast_Tools 0.1.7`**, a
limited-internal release for selected team members.

Install/update through the repository
[`index.xml`](https://raw.githubusercontent.com/Logutin/reaper-reapack-neurocast-tools/main/index.xml).
ReaImGui remains an external prerequisite; package minimum remains REAPER 7.72+.

## Current release: 0.1.7

ElevenLabs v2.1.5 includes updated STS preparation/localization and localized
Help on the existing language/status row. The Russian offline manual ships in
`manuals/` alongside the script. Startup checks availability once; missing HTML
hides Help with a warning. Help uses the direct system opener without SWS,
temporary files or polling. Other tools and binaries retain their prior bytes.

On 2026-09-29 the owner reported the installed candidate check passed and
confirmed that Help opened the installed Russian manual in the authorized
`C:\extra_Reapers\Reaper_Empty_01\reaper.exe`. Independent readback verified
receipt 0.1.7, all 70 owned Windows files against the frozen payload, and
14 exactly-once Main actions. The root feed publishes the exact accepted
candidate. Restoring the disposable to the public feed and final cache readback
remain pending; no further workflow test is required for this release gate.

Runtime source is pinned to `auphonic-mt` commit
`b90ec1f60d699e42b1877900f0a2a2ab46a1d99a`; all 198 new platform source records
pin distribution payload `3adfe1daf0355b9ff158a13cf75f6e3ec72ad447`.
The six historical public versions remain unchanged. Failed candidate 0.1.6
is preserved only in its separate historical feed and is not published.
Script/toolset labels retain their independent source identities.

This is owner-reported Windows package/Help acceptance plus agent-run mechanical
verification. Real macOS opening, broader authenticated workflows, difficult
networks, other machines and full lifecycle qualification remain separate.
Existing MVSEP telemetry and Script Aligner ambiguous-create retry limitations
remain documented. No new team-testing outcome is implied.

See the [0.1.7 release record](docs/2026-09-29_package_implementation_0.1.7.md),
[payload manifest](release-manifest.yml), and [source lock](release-source-lock.yml).
The [0.1.5 record](docs/2026-09-15_package_implementation_0.1.5.md) and
[0.1.4 record](docs/2026-09-11_package_implementation_0.1.4.md) preserve prior
release and workflow acceptance.

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
