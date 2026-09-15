# Neurocast Tools 0.1.5 release record

> **Source snapshot warning:** This record describes release preparation on
> 2026-09-15. Recheck source pins, feed bytes, installed receipts, and owner
> acceptance before relying on it for publication or a later release.

## Status and scope

Candidate preparation is authorized. The owner requested the release routine,
preferred minimal tests, and authorized the disposable installation at
`C:\extra_Reapers\Reaper_Empty_01\reaper.exe`. The public root feed remains
`0.1.4`; `0.1.5` awaits the owner-run packaged startup check and exact installed
receipt/byte/action readback before root-feed promotion.

Runtime source pin: `auphonic-mt`
`04fbd164ae06796bef170a7f9c3c6d8624cdbe74`.
Previous distribution baseline: `d34a5ad87d408cbdd46a08c0d722744d351ffad9`.

Only three shipped Lua inputs change, copied byte-for-byte from that source:

- `scr/elevenlabs_manager_tool.lua` (`SCRIPT_VERSION v0.2.2`)
- `scr/modules-neurocast/elevenlabs_manager_user_view.lua`
- `scr/modules-neurocast/reaper_manager_elevenlabs_api.lua`

Manager adds explicit connections, balance/access editing, exact large
fractional balance handling, and visible actionable validation errors that
survive background success. This release packages the already accepted source;
it does not change or revalidate the backend contract. Source verification and
the owner's September 14 local balance/validation acceptance are recorded in
`auphonic-mt/docs/testing_and_verification.md`.

All other 57 Lua files, binaries, native extensions, and notices retain their
previous package bytes. Eight unchanged Lua files retain historical CRLF bytes;
the changed Manager adapter now matches its LF source blob exactly. Inventory
remains 60 Lua inputs, 192 platform source records, 68 Windows owned files,
and 14 Main actions. Package minimum remains REAPER 7.72+ with external
ReaImGui. Script/toolset labels remain independent of package `0.1.5`.

## Minimal verification

Read-only baseline verification passed in the authorized disposable:
REAPER 7.80, installed `0.1.4`, all 68 owned files matching the published
payload, and 14 exactly-once Main actions. REAPER was closed. The saved
repository uses the public root feed and manual installation. Existing
identity material is present and is excluded from the package.

Fresh focused source checks passed: 156 Manager API checks, 64 Manager
workflow checks, and the Manager user-list regression. These are headless
checks, separate from owner-observed behavior.

`python qualification/verify_0_1_5.py` passed source fidelity, 60 Lua syntax
checks, exact dependency closure and exclusions, unchanged binary/notice
hashes, local 7-Zip DLL resolution, metadata inventory and action counts.
`reapack-index --check --strict --warnings .` passed with one package and zero
failures. Candidate index generation and its immutable history/payload checks
are the next mechanical steps.

## What to check in REAPER live

1. Open only `C:\extra_Reapers\Reaper_Empty_01\reaper.exe`. In Actions,
   load `qualification/Neurocast_Tools_0_1_5_candidate_and_smoke.lua` from
   this repository. The helper refuses any other executable/resource path.
2. Apply only the Neurocast Tools `0.1.4 -> 0.1.5` update, then run the
   helper again. It checks the Manager source version marker, not full bytes.
3. Open the installed `elevenlabs_manager_tool.lua` from Actions. Confirm
   `v0.2.2` opens without a missing-module or Lua error, then close it normally.
4. Report whether the update/startup passed. The agent checks installed bytes,
   ownership, and all action registrations before promoting the root feed.

The focused source workflow has prior owner acceptance; this minimal package
gate does not repeat authenticated writes or tests of unchanged workflows.
The helper changes only the disposable's Neurocast repository URL with manual
installation, queues synchronization, and opens the package browser. It does
not launch tools or perform remote processing. After publication, the existing
`qualification/Neurocast_Tools_restore_public_feed.lua` restores the public URL.

## Evidence limits

This is a limited-internal release for selected team members. Production
Manager/backend compatibility, broader authenticated workflows, difficult
networks, macOS, other machines, clean install/uninstall, and legacy migration
are not qualified by this update/startup gate. No new native release, tag,
GitHub release, or direct-era ZIP is part of this routine.
