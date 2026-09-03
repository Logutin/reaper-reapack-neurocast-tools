# Neurocast Tools 0.1.3 release record

> **Source snapshot warning:** This record describes the release as of
> 2026-09-03. Recheck commits, hashes, receipts, and publication state before
> relying on it for another release.

## Status and scope

`Neurocast Tools 0.1.3` is published for limited-internal team testing through
the public root `index.xml`. The owner confirmed the minimal Windows
`0.1.2 -> 0.1.3` update/UI gate. The disposable installation's switch back to
the published feed and final synchronization/readback remain pending.

Runtime source is frozen at `auphonic-mt` commit
`7c7def2d31526fa6cd0f9fd387c246ed44a34e21`. The only runtime changes from
`0.1.2` are `elevenlabs_tool.lua`, `elevenlabs_manager_tool.lua`,
`modules-neurocast/elevenlabs_api_via_neurocast.lua`, and the new
`modules-neurocast/elevenlabs_manager_user_view.lua`.

Manager `v0.1.3` adds local name/username/email filtering, retained sorting,
filtered/total counts, and explicit empty states. ElevenLabs `v2.1.1` removes
permanent voice deletion from the UI/workflow and client request builder.
Manager Block still removes only an account assignment. No backend route or
authorization change is included; older-client deletion is not claimed blocked.

## Frozen package and deterministic checks

- Distribution candidate: `04be44ea863067e0b7f645899404fb4bdb9497e8`.
  All 174 published `0.1.3` source records are pinned to this commit.
- 54 Lua files: 13 Main actions and 41 support modules. Platform rows are
  62 Windows x64, 56 macOS x86_64, and 56 macOS ARM64.
- Four changed/new files are byte-exact frozen source blobs. The 50 other Lua
  files retain their existing bytes, including ten historical CRLF files
  identified in `release-source-lock.yml`.
- Native variants, curl, matching 7-Zip binaries, notices, REAPER 7.72+
  minimum, and external ReaImGui prerequisite are unchanged.
- Source filter, deletion/static UI, active manager adapter, auth, and secret
  tests pass. All packaged Lua syntax, source fidelity, dependency closure,
  binary/notice hashes, action/platform rows, and exclusions pass.
- Tests, helpers, credentials, telemetry identities, legacy runtime, and
  development artifacts are excluded.
- The generated index preserves every historical version element and source
  URL for `0.1.0-pre1`, `0.1.1`, and `0.1.2`.
- Read-only downloads of all four changed/new files through the candidate
  GitHub URLs matched their exact frozen bytes.

Verification commands:

```powershell
python qualification/verify_0_1_3.py --index index.xml --candidate 04be44ea863067e0b7f645899404fb4bdb9497e8
reapack-index --check --strict --warnings .
git diff --check
```

Generate the index with `reapack-index --scan
04be44ea863067e0b7f645899404fb4bdb9497e8 --no-amend --strict --warnings
--no-commit .`; do not manually edit XML or rebind version sources.

## Owner-run Windows evidence

Authorized installation: `C:\extra_Reapers\Reaper_Empty_01\reaper.exe`.
Before the update, its receipt was `0.1.2`, 61 owned files, 13 Main actions.

The owner used the guarded candidate helper and confirmed on 2026-09-03:

- the ReaPack update to `0.1.3` passed;
- Manager `v0.1.3` opened and its filter/counts worked;
- ElevenLabs `v2.1.1` opened and Account Voices loaded without deletion controls.

Agent readback then verified the `0.1.3` receipt, all 62 installed files
byte-for-byte against the candidate, and exactly-once registration of all
13 Main actions. The full manager source checklist was separately owner-confirmed
earlier that day. These are owner-run GUI results plus agent-run read-only checks,
not agent-operated GUI tests.

## Remaining delivery cleanup and evidence boundary

Run the guarded `qualification/Neurocast_Tools_restore_public_feed.lua` in the
same disposable REAPER and allow synchronization. Then verify the real-feed
setting/cache, installed receipt and bytes, and stop the temporary loopback
server. Final delivery cleanup is not complete until that readback passes.

Uninstall, clean install, remote generation, broad authenticated workflow testing,
difficult-network, macOS, another machine/user, signing, notarization, tags,
GitHub Releases, and release CI are outside this gate. Earlier team testing
and older release qualification are historical evidence, not new `0.1.3`
results. This is not broad Windows, workflow, or production qualification.
