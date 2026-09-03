# Neurocast Tools 0.1.3 candidate and release record

> **Source snapshot warning:** This record describes the approved candidate as
> of 2026-09-03. Recheck commits, hashes, receipts, and publication state before
> relying on it for another release.

## Status and scope

The four-file candidate is assembled. Public `index.xml` still publishes `0.1.2`;
`0.1.3` is not published or live-qualified yet. The owner approved a deliberately
minimal Windows update/UI gate in `C:\extra_Reapers\Reaper_Empty_01\reaper.exe`.

Runtime source is frozen at `auphonic-mt` commit
`7c7def2d31526fa6cd0f9fd387c246ed44a34e21`. The only runtime changes from `0.1.2`
are `elevenlabs_tool.lua`, `elevenlabs_manager_tool.lua`,
`modules-neurocast/elevenlabs_api_via_neurocast.lua`, and the new
`modules-neurocast/elevenlabs_manager_user_view.lua`.

Manager `v0.1.3` adds entirely local name/username/email filtering, retained
sorting, filtered/total counts, and explicit empty states. The owner already
confirmed its full source live checklist. ElevenLabs `v2.1.1` removes permanent
voice deletion from the UI/workflow and client request builder. Manager Block
still removes only an account assignment. No backend route or authorization
change is included; older-client deletion is not claimed to be blocked.

## Package invariants

- 54 Lua files: 13 Main actions and 41 support modules.
- Platform source rows: 62 Windows x64, 56 macOS x86_64, 56 macOS ARM64 (174 total).
- Four changed/new files are byte-exact frozen source blobs. The 50 other Lua
  files retain their existing distribution bytes, including ten historical CRLF
  files listed in `release-source-lock.yml`.
- Native extension variants, curl, matching 7-Zip binaries, notices, minimum
  REAPER 7.72+, and external ReaImGui prerequisite are unchanged.
- No tests, helpers, credentials, telemetry identities, legacy runtime, or
  development artifacts enter the package. Historical release sources stay pinned.

## Minimal owner gate and remaining work

Source filter, deletion/static UI, active manager adapter, auth, and secret-audit
tests pass. `python qualification/verify_0_1_3.py` verifies all packaged Lua
syntax/content, dependency closure, unchanged inputs, platform rows, and exclusions.
`reapack-index --check --strict --warnings .` passes with one package and zero
failures. The guarded Lua helper passes syntax and headless wrong-path/candidate
marker checks. Generated-index and live results will be recorded after source freeze.

After deterministic checks, use the guarded qualification helper to select the
local candidate index in the disposable REAPER, then install `0.1.3` with ReaPack.
Check both changed tool titles/startup, one manager filter/count result, and
Account Voices loading without deletion controls. No assignment mutation or
remote generation job is required. Stop for the owner's report before publishing
the public index, then verify real-feed receipt/hashes and clean pushed repositories.

Uninstall, clean install, broad authenticated workflow testing, difficult-network,
macOS, another machine/user, signing, notarization, tags, GitHub Releases, and
release CI are deliberately outside this gate. This is limited-internal team
testing, not broad Windows, workflow, or production qualification.
