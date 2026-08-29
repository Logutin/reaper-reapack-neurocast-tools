# Windows local qualification: Neurocast Tools 0.1.0-pre1

> Qualification snapshot: 2026-08-29. This record applies only to package
> commit `3960757e8a9a0452c8aac1a36248f26a4a9274fe` and Windows x64. It is not
> macOS, update, migration, signing, notarization, or broad production-release
> evidence.

## Verdict

**PASS for the required Windows x64 local packaging gates.** The candidate can
proceed to the next limited internal ReaPack publication milestone. It is not a
broadly qualified public production release.

The package payload and version were not changed during qualification. The
repository still has no root `index.xml`, tag, GitHub release, or GitHub Actions
workflow.

## Environment

- Package commit: `3960757e8a9a0452c8aac1a36248f26a4a9274fe`
- Windows: 64-bit Windows, build `26200`
- REAPER: `7.79/x64`
- Disposable executable: `C:\extra_Reapers\Reaper_Empty_01\reaper.exe`
- Isolated resource path: `C:\extra_Reapers\Reaper_Empty_01`
- ReaPack: `1.2.6`
- ReaImGui: `0.10.0.5`, external and pre-existing
- Native extension: `reaper_cyr_essentials.dll`, package-provided for this run
- Telemetry identity: fresh per-installation user state, installed manually and
  byte-verified without displaying or logging its client token

`reaper.exe` and `reaper.ini` were both resolved inside the disposable root.
Only that executable was observed running. The normal REAPER installation and
normal resource directory were not used for installation or testing.

## Temporary repository

`reapack-index 1.2.6` generated an external temporary index by scanning the
exact package commit with `--no-config`, strict warnings, no commit, the eight
committed discovery-ignore paths, and an immutable raw-GitHub URL template.
The generated repository was named
`Neurocast Tools Windows Qualification 0.1.0-pre1 f4992fbc`.

Validation and semantic inspection confirmed:

- one package, version `0.1.0-pre1`, by Slava Logutin;
- 93 source records: 35 `win64`, 29 `darwin64`, and 29 `darwin-arm64`;
- six Windows Main actions and one Windows extension source;
- all source URLs pinned to package commit
  `3960757e8a9a0452c8aac1a36248f26a4a9274fe`;
- no filesystem, branch, Linux, or generic-darwin source URL;
- no duplicate same-platform destination;
- strict check result: exactly one package, zero failures, zero warnings.

The workspace was
`C:\Users\Slava\AppData\Local\Temp\neurocast-tools-qualification-20260829-130354-f4992fbc`.
Python PID `5760` served it only on `127.0.0.1:50068`. A loopback GET of
`http://127.0.0.1:50068/index.xml` returned `200` and matched the generated
index SHA-256
`c85cdb5f49a1ed69747655b4fc5fd456053df20b1b810c32267da36f4a48e3fd`.
The feed remained available through uninstall, then its ReaPack repository and
cache entry were removed, the server was stopped, and the workspace was
deleted.

## Installation and static inspection

The owner installed the package through the real ReaPack client from the
loopback feed and restarted the disposable REAPER. ReaPack recorded
`0.1.0-pre1` as installed.

- Installed script/support payload: 34 files
  - 27 Lua files
  - 3 Windows utilities
  - 4 component notices
- Installed native payload: 1 file in `UserPlugins`
- Every installed file matched the byte size and SHA-256 of the immutable
  package commit.
- No macOS, Linux, generic-darwin, or unexpected payload was installed.
- `curl.exe` reported curl `8.13.0`.
- `7z.exe`, using its adjacent packaged `7z.dll`, reported 7-Zip `26.00 x64`.
- curl, 7-Zip, its DLL, and `reaper_cyr_essentials.dll` all had PE machine type
  `0x8664` (x86_64).
- The native DLL hash was
  `1df283154fa3183c4437132b621ca9bda908f4a52dbca9051bee5c07410c1527`.

ReaPack installed script payload below its isolated repository/category path,
`Scripts/Neurocast Tools Windows Qualification 0.1.0-pre1 f4992fbc/Neurocast_Tools/`.
The extra repository-name directory is normal ReaPack feed isolation; package
relative paths remained unchanged.

## Action, native, and tool tests

Package Main-action registrations were:

| Checkpoint | Count |
|---|---:|
| Before install | 0 |
| After install | 6 |
| After launching both tools | 6 |
| After uninstall | 0 |

Every package action path was registered once. Opening the full tools created
no duplicate wrapper registration.

The four maintained wrappers each produced a fresh timestamp in ExtState
section `nc_dDeSm_Acr33` for its exact key:

- `fast_STS_flow_action_for_hotkey_trigger` — PASS
- `fast_TTS_flow_action_for_hotkey_trigger` — PASS
- `audio_tags_insert_selected_notes_action_for_hotkey_trigger` — PASS
- `audio_tags_remove_brackets_selected_notes_action_for_hotkey_trigger` — PASS

A temporary diagnostic confirmed both native preview APIs were present. The
owner audibly confirmed a local 440 Hz WAV played, a 660 Hz WAV replaced it,
and Stop produced silence.

Both `elevenlabs_tool.lua` and `elevenlabs_manager_tool.lua` opened their
ReaImGui windows from the installed package without missing-module or package
path errors. With owner-entered production credentials:

- `elevenlabs_tool.lua` authenticated, loaded its account/shared-voice views,
  and played and stopped remote previews as intended;
- `elevenlabs_manager_tool.lua` authenticated and completed its normal initial
  read-only load as intended; no assignment, remap, block, or other manager
  mutation was performed.

## Logs and telemetry

Four local logs under
`C:\extra_Reapers\Reaper_Empty_01\CirilicaTools_telemetry\logs` were inspected.
Targeted readback from the production telemetry workbook found 66 events for
this exact installation between `2026-08-29T10:36:19.246Z` and
`2026-08-29T10:40:22.701Z`:

- 55 events from `elevenlabs_tool`;
- 11 events from `elevenlabs_manager_tool`;
- all 66 at `info` level;
- only HTTP `200` and `201` where an HTTP code was recorded;
- successful Curl exit status where recorded;
- account and shared-voice preview download, start, cache, and stop evidence;
- three completed manager operations.

One manager log recorded a transient telemetry flush response
`SERVER_ERROR`. It was classified as retryable; the next flush returned HTTP
`200`, accepted all three queued events, and removed the sent queue file. The
live workbook readback and installation `last_seen_at` confirmed delivery. No
raw client token appeared in the inspected spreadsheet rows or report output.
This is an accepted telemetry-service warning, not a packaging or backend
feature failure.

## Uninstall and preservation

The owner uninstalled through ReaPack, removed both temporary diagnostic
registrations, removed the temporary repository, restarted once to release the
extension, and closed REAPER. Automated inspection then confirmed:

- 35 package-owned files removed: 34 script/support files plus one native DLL;
- zero package action registrations;
- zero diagnostic action registrations;
- no temporary repository entry, cache XML, or package registry row;
- the unrelated sentinel remained byte-identical with SHA-256
  `048451a0a4b8fa1c3c2d39c24dcac512ec981ba8f7c42d9bb938c5ab488be67b`;
- ReaPack and ReaImGui remained installed;
- the telemetry identity and four runtime log files remained present;
- user/runtime state was not deleted with the package.

## Explicitly deferred and unqualified

- macOS x86_64 installation, native loading, and preview behavior;
- macOS ARM64 installation, native loading, and preview behavior;
- macOS signing, notarization, Gatekeeper, and quarantine behavior;
- prior-version update behavior, because no earlier Neurocast Tools ReaPack
  version exists;
- migration of legacy `Neurocast_Tools__*.lua` files and registrations, because
  this run used a fresh disposable environment;
- another team member or another computer;
- GitHub Actions;
- public repository `index.xml`;
- tag or GitHub release;
- signing or notarization;
- broad public production qualification.

macOS was deliberately skipped by owner decision. The Windows result does not
imply qualification of any deferred area.
