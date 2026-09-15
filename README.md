# Neurocast Tools

The current published package is **`Neurocast_Tools 0.1.5`**, a
limited-internal release for selected team members.

Install/update through the repository
[`index.xml`](https://raw.githubusercontent.com/Logutin/reaper-reapack-neurocast-tools/main/index.xml).
ReaImGui remains an external prerequisite; package minimum remains REAPER 7.72+.

## Current release: 0.1.5

- ElevenLabs Manager `v0.2.2` adds explicit Manager connections, balance/access
  editing, exact large fractional balances, and persistent actionable errors.
- Only the Manager entrypoint and two Manager helpers change. The other 57 Lua
  files, native extensions, curl, matching 7-Zip 26.03 pair, and notices retain
  their `0.1.4` package bytes.
- Six Tools, four Tool Actions, and four Utilities provide 14 Main actions;
  Windows ownership remains 68 files.

On 2026-09-15 the owner reported the `0.1.4 -> 0.1.5` update and installed
Manager `v0.2.2` startup/normal close passed in
`C:\extra_Reapers\Reaper_Empty_01\reaper.exe`. Independent readback verified
all 68 installed files against the frozen candidate and exactly 14 Main
actions. The root feed publishes that unchanged candidate. The disposable's
public-feed URL restoration and final synchronization/readback remain pending.

Runtime source is pinned to `auphonic-mt` commit
`04fbd164ae06796bef170a7f9c3c6d8624cdbe74`; all 192 platform source records
pin distribution payload `da01965751fa3d8d925bdd8babe37d1068553421`.
All five historical version records/URLs remain unchanged. Script/toolset
labels retain their independent source identities.

This is owner-reported update/startup acceptance plus agent-run mechanical
verification. The earlier local Manager balance/validation acceptance remains
separate source evidence. Production Manager compatibility, broader authenticated
workflows, difficult networks, macOS, other machines, and full lifecycle
qualification were not repeated. Existing MVSEP telemetry and Script Aligner
ambiguous-create retry limitations remain documented. No `0.1.5` team-testing
outcome is implied.

See the [0.1.5 release record](docs/2026-09-15_package_implementation_0.1.5.md),
[payload manifest](release-manifest.yml), and [source lock](release-source-lock.yml).
The [0.1.4 record](docs/2026-09-11_package_implementation_0.1.4.md) preserves
its September 11 owner-reported workflow acceptance and team-testing status.

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
