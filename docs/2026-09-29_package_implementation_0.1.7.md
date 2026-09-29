# Neurocast Tools 0.1.7 release record

> **Source snapshot warning:** Release record as of 2026-09-29. Recheck
> current feeds, pins and restoration state before relying on this snapshot.

## Status and scope

Published limited-internal release after owner acceptance on 2026-09-29.
The owner reported the packaged check passed in the authorized disposable
`C:\extra_Reapers\Reaper_Empty_01\reaper.exe` and specifically confirmed Help
opened `file:///C:/extra_Reapers/Reaper_Empty_01/Scripts/Neurocast%20Tools/Neurocast_Tools/manuals/2026-09-28_elevenlabs_tool_manual_ru_draft.html`.
Independent readback then verified receipt 0.1.7, all 70 byte-exact owned files
and 14 exactly-once Main actions. The public root feed promotes the unchanged
candidate. Disposable public-feed restoration/final cache readback is pending.
The failed 0.1.6 candidate and frozen payload remain historical and unchanged.

Source pin: `b90ec1f60d699e42b1877900f0a2a2ab46a1d99a` in auphonic-mt.
Previous candidate baseline: `16c82af9edad735124501cd4de792203477c545b`.
Frozen payload: `3adfe1daf0355b9ff158a13cf75f6e3ec72ad447`.

Three Lua files change from 0.1.6: ElevenLabs to v2.1.5, its generated language
module and `offline_manual.lua`. The Russian HTML's overview and source metadata
are updated; its 31 images and chapter review states remain unchanged. All
four inputs match the pinned source bytes exactly. The remaining 58 Lua files,
all binaries, native extensions and notices keep their previous bytes.

Startup uses native `reaper.file_exists` once, caches availability and hides
Help if the manual is absent. The missing-manual condition calls `Util.msg`
at warning level 2, with `!SHOW:` to avoid opening a console, and no UI error.
Availability changes require restart. Present Help launches the direct system
opener via `ExecProcess(..., -2)`: system Explorer on Windows or `/usr/bin/open`
on macOS. There is no SWS lookup, PowerShell, temporary file, polling or cleanup.
The UI reports detected command-launch failures; successful submission does
not confirm browser rendering or detect later default-application errors.

The helper and manual retain their installation-relative paths. Inventory is
unchanged: 61 Lua inputs, one HTML asset, 198 platform source records, 70 Windows
files, 64 files on each Mac target and 14 Main actions per platform. Package
minimum remains REAPER 7.72+ with external ReaImGui; individual tool guards apply.
Script/toolset versions retain their independent source identities.

## Verification and limits

Read-only installed baseline passed for 0.1.6: all 70 owned files and 14
exactly-once Main actions match its frozen candidate. Its Help failure is
owner-observed; package fidelity did not imply working Help. No installed
payload, feed setting or project was changed directly by the agent.

Source checks passed: 10 focused Help groups, fixed-action regression, Lua
syntax, scoped localization validation/build and unchanged manual image/ID/
chapter metadata checks. Localization has 837 active strings, 605 Russian
translations and 232 retained English fallbacks. Help tests execute the real
startup/controller/header with OS/UI doubles; owner-reported Windows opening now passes.

The package verifier passes source fidelity, 61 Lua syntax/dependency checks,
exact HTML hash/path, excluded-file inventory, unchanged-file and binary/notice
checks, matching package-local 7-Zip pair, metadata counts and Main roles.
Strict ReaPack metadata checking and helper syntax checks pass. Candidate-index
validation passed: all six public historical versions are unchanged and all
198 new records pin the frozen payload. At candidate preparation, the public feed and failed 0.1.6
candidate feed retained their previous bytes. Publication changes only the public
feed to the accepted 0.1.7 candidate. Failed 0.1.6 remains in its separate historical
candidate feed, not in the public version history.

## Remaining owner action

Run `qualification/Neurocast_Tools_restore_public_feed.lua` only in the
authorized disposable REAPER, confirm restoration, wait for synchronization
and report done. The helper guards both executable and resource paths and
preserves manual installation. Final readback will check the public URL,
cached index bytes, installation settings, receipt, files and actions.

The candidate update/startup/Help check is complete. No login, processing or
repeat workflow test is requested. The agent did not directly edit installed
payload, REAPER settings or projects.

Real Mac opening, broader workflows and bad-network qualification remain
separate. No new backend contract, native build, telemetry identity, tag,
GitHub Release or direct-era ZIP is part of this correction.

Candidate feed: `qualification/Neurocast_Tools_0.1.7_candidate.xml`.
SHA-256: `cfdb17fe98c46fa567faf00e30cc97e7eef3e112446921cc6988437ec1962816`.
Generated with `reapack-index --scan 3adfe1daf0355b9ff158a13cf75f6e3ec72ad447
--no-amend --strict --warnings --no-commit` and the separate output path.
