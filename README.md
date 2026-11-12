# Neurocast Tools

The current published package is **Neurocast Tools 0.1.10**, a
limited-internal release for selected team members.

> **Published, 2026-11-12:** the owner authorized promotion after installed
> Windows production/IPA/cache and Help checks passed. The public root feed
> promotes the documentation-corrected candidate unchanged. The disposable
> public-feed switch and same-version reinstall/readback remain pending.
> See the [release record](docs/2026-11-12_package_acceptance_0.1.10.md).

Install/update through the repository
[index.xml](https://raw.githubusercontent.com/Logutin/reaper-reapack-neurocast-tools/main/index.xml).
ReaImGui remains an external prerequisite; package minimum remains REAPER 7.72+.

## Current release: 0.1.10

ElevenLabs v2.1.12 adds regional IPA suggestions, selected-track previews,
contextual sentence preview and undoable slash-delimited item replacements.
The package includes safe TTS retry controls and six offline manuals, including
the four newly packaged Help integrations. Status prose now reflects production
backend 1.15 and the owner's Windows acceptance. Missing illustrations remain
deferred; no broader platform or pronunciation-accuracy claim is made.

- Source/manual pin: `fa51860c858df0c810d3d124899ec709c54216b3`.
- Frozen corrected payload: `91e233c5be1478d72659cf1789d08c1a27ab32e6`.
- 63 Lua files, 219 platform records, 77 Windows files and 14 Main actions.
- All nine historical public versions preserved; native components unchanged.

The owner-tested runtime is unchanged by the subsequent manual correction.
Final corrected-manual installation readback is pending in the authorized
`C:\extra_Reapers\Reaper_Empty_01`; no repeat paid listening test is required.

## Previous release: 0.1.9

ElevenLabs v2.1.7 accepts broad STS selections: empty/MIDI items and tracks
without matching voices are skipped while eligible audio continues. The
Russian/English report shows skipped counts and reasons. The offline manual
now explains select-all, omissions and FAST/shortcut behavior. Its 31 existing
screenshots and anchors are preserved, with older screenshot dates identified.

The owner passed the source workflow and packaged Windows startup/STS
explanation/Help/normal-close checks on 2026-10-09. Independent readback
verified receipt 0.1.9, all 71 exact Windows files and 14 exactly-once Main
actions. The public feed promotes the unchanged accepted candidate and
preserves all eight prior public versions. No Computer Use or repeated paid
processing was performed. The owner completed the disposable's switch to
the public feed. Final URL/cache, installed-file/action and settings readback
passed on 2026-10-09; the limited-internal release routine is complete.

Runtime source: 1f5ca2a87e0fc36e5cd621f1c86934fa85fd6a15.
Frozen distribution payload: ac23a1d76c45b297dd40b196ce50e2b320122389.
Two Lua files and the ElevenLabs HTML change; 59 other Lua files, DOCX HTML,
binaries, native extensions and notices retain their exact prior bytes.
The package retains 201 platform records and 14 Main actions per platform.

This is limited Windows package acceptance, not broad platform, network,
other-machine or full lifecycle qualification. Full manual content/layout
acceptance, existing MVSEP telemetry and Script Aligner retry limitations
remain separate. Script/toolset identities remain independent of ReaPack.

See the [0.1.9 release record](docs/2026-10-09_package_implementation_0.1.9.md),
[payload manifest](release-manifest.yml), and [source lock](release-source-lock.yml).
The [0.1.8 record](docs/2026-10-07_package_implementation_0.1.8.md) preserves
the previous DOCX manual/Help release. Failed candidate 0.1.6 remains excluded.

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
