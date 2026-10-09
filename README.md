# Neurocast Tools

The current published package is **`Neurocast_Tools 0.1.8`**, a
limited-internal release for selected team members.

Install/update through the repository
[`index.xml`](https://raw.githubusercontent.com/Logutin/reaper-reapack-neurocast-tools/main/index.xml).
ReaImGui remains an external prerequisite; package minimum remains REAPER 7.72+.

## Candidate 0.1.9 (2026-10-09)

ElevenLabs v2.1.7 allows broad STS selections, skipping empty/MIDI items and
unmatched tracks while processing eligible audio. The Russian/English skip
report and offline manual are updated. Source live testing passed per the owner;
the packaged Windows check is pending. The public feed remains 0.1.8.
See the [candidate record](docs/2026-10-09_package_implementation_0.1.9.md).

## Current release: 0.1.8

The main change is the illustrated Russian offline DOCX Import manual v1:
eight chapters, eleven unchanged owner screenshot payloads and 36 separate
vector callouts. DOCX v0.1.1 adds localized Help; ElevenLabs v2.1.6 opens its
renamed canonical manual. Both manuals ship as support assets under `manuals/`.
The shared resolver uses fixed per-tool paths. Other tools, binaries, native
extensions and notices retain their prior bytes.

On 2026-10-07 the owner confirmed the candidate startup/Help check passed in
`C:\extra_Reapers\Reaper_Empty_01\reaper.exe`, covering both tools and manuals.
Independent readback verified receipt 0.1.8, all 71 owned Windows files against
the frozen payload, and 14 exactly-once Main actions. The root feed publishes
the exact accepted candidate. The owner switched the disposable to the public
feed; final read-only cache/settings/file/action verification passed and private
telemetry files are preserved. Publication and installation follow-up are
complete. No further Computer Use or repeat workflow test was performed.

Runtime source is pinned to `auphonic-mt` commit
`adbcf6fd7bf51460f990279f532f396edf2b5874`; all 201 new platform source records
pin distribution payload `1287e97cb20f5278b381ad1894c8bbfa93a7bded`.
All seven historical public versions remain unchanged. Failed candidate 0.1.6
is preserved only in its separate historical feed and is not published.
Script/toolset labels retain their independent source identities.

This is owner-reported Windows package/Help acceptance plus agent-run mechanical
verification. All eight DOCX chapters still await owner content review. Broader
import/Undo, desktop/narrow/print layout, real macOS opening, difficult networks,
other machines and full lifecycle qualification remain separate. Existing MVSEP
telemetry and Script Aligner ambiguous-create retry limitations remain documented.

See the [0.1.8 release record](docs/2026-10-07_package_implementation_0.1.8.md),
[payload manifest](release-manifest.yml), and [source lock](release-source-lock.yml).
The [0.1.7 record](docs/2026-09-29_package_implementation_0.1.7.md) preserves the
previous release and its owner-reported Help acceptance.

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
