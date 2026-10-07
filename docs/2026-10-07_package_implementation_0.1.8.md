# Neurocast Tools 0.1.8 release record

> **Source snapshot warning:** Release record as of 2026-10-07. Recheck
> feed, source pins and installed state before relying on this dated record.

## Scope and status

Published for limited-internal delivery after owner acceptance and exact
installed readback on 2026-10-07. The root feed promotes the unchanged tested
candidate; final disposable public-feed/cache/settings readback passed.
The owner authorized end-to-end release work using only
`C:\extra_Reapers\Reaper_Empty_01\reaper.exe`, with minimal testing.

Main change: directly maintained Russian DOCX Import manual v1, eight chapters,
eleven owner PNGs preserved byte-for-byte, and 36 separate vector callouts.
DOCX v0.1.1 adds localized Help. ElevenLabs v2.1.6 opens its renamed canonical
manual. The shared resolver takes a fixed per-tool path; generated DOCX
localization preserves existing translations and adds the Help strings.
All eight DOCX chapters still await owner content review. Release smoke does
not imply full content or import-workflow acceptance.

Source pin: `adbcf6fd7bf51460f990279f532f396edf2b5874` in auphonic-mt.
Baseline published distribution: `cf2d22471c994858550aa127c8d2e1cc781a108a`.
Four Lua inputs change; 57 retain their previous bytes. Both HTML support
assets match the source commit exactly. The old ElevenLabs filename is removed
through the versioned package migration. The Windows installation guide is
repository-only. All binaries, native extensions, notices and unrelated tools
retain their previous bytes. No backend change, identity creation, native build,
GitHub Release, tag or direct-era ZIP is included.

Inventory: 61 Lua inputs, two HTML assets, 201 platform source records,
71 Windows files, 65 files per Mac target and 14 Main actions per platform.
Package minimum remains REAPER 7.72+ with external ReaImGui.

## Focused preparation evidence

- Both repositories began clean, on main and synchronized with origin/main.
- Payload verifier passed syntax/content/dependency closure for all 61 Lua
  inputs, the four changed exact blobs, unchanged remaining inputs, both exact
  HTML assets and all binary/notice pins. Metadata matches all 201 records.
- `reapack-index --check --strict --warnings .` passed with zero failures.
- Read-only disposable baseline: 0.1.7 receipt, 70 exact owned files, 14
  exactly-once Main actions, public repository and existing telemetry identity.
- REAPER 7.81 in the named disposable has an existing test project open.
  The package gate is startup, Help opening the installed DOCX and ElevenLabs
  HTML, illustrated DOCX content visible, normal close, then exact readback.
  No import, project edit, authenticated processing or paid call is needed.

Current source validation and screenshot integrity are recorded in
[the source audit](https://github.com/Logutin/auphonic-mt/blob/adbcf6fd7bf51460f990279f532f396edf2b5874/docs/testing_and_verification.md#docx-help-and-manual-documentation-audit-2026-10-06).
Broader import/Undo, responsive/print layout, real Mac opening, difficult-network,
other-machine and lifecycle qualification remain separate.

## Candidate handoff (pre-acceptance evidence)

Frozen payload: `1287e97cb20f5278b381ad1894c8bbfa93a7bded`.
Candidate/helper publication: `0b3ea66` on main. Candidate feed:
`qualification/Neurocast_Tools_0.1.8_candidate.xml`.

The generated candidate has 201 immutable source URLs and preserves all seven
public historical versions exactly. Strict index checks pass. Candidate feed,
helper, both HTML files, DOCX entrypoint and opener downloaded from GitHub match
their committed bytes. At this preparation stage, the public root feed remained byte-identical to 0.1.7.

The owner selected an owner-run install/Help check on 2026-10-07. Run
`qualification/Neurocast_Tools_0_1_8_candidate_and_smoke.lua` only in the named
disposable, apply 0.1.8 through ReaPack, then rerun the helper. Confirm DOCX
v0.1.1 opens its illustrated installed manual and ElevenLabs v2.1.6 opens its
own renamed manual; both tools close normally. Report the actual observations.
At handoff, installed verification and promotion were pending the owner's
report. The acceptance and independent readback below complete those gates.

Candidate feed SHA-256: `301ea1773c8f3c322b39598d63dbccbe3b055da10e1e9b9736b46a684bf76b65` (committed LF bytes).

## Acceptance and public promotion

On 2026-10-07 the owner replied "Confirmed. Passed." to the candidate checklist.
This is owner-reported startup, installed DOCX illustrated manual opening,
ElevenLabs renamed manual opening and normal close. The two supplied captures
show DOCX v0.1.1 and ElevenLabs v2.1.6 with their Russian Help controls; they
show startup/header states, not browser rendering or executed import/Undo.
No agent-run live processing or project edit occurred.

Independent read-only verification passed: receipt 0.1.8, 71 owned Windows
files byte-identical to the frozen candidate, and 14 exactly-once Main actions.
The public root index now contains the exact committed candidate bytes, with
201 immutable 0.1.8 source records and all seven historical versions preserved.
No runtime or HTML payload changed after acceptance. Public URL download
passed byte-for-byte against the committed root feed and accepted candidate.
Publication commit: `2d788b6`.

## Disposable public-feed follow-up (completed)

The owner stopped Computer Use during the repository-manager step, then
explicitly requested no Computer Use while in a meeting and said they would
switch and check later. No repository setting was applied by the agent.
The first follow-up captures showed the temporary candidate URL and installed
0.1.8. The owner then switched to the published root feed and supplied updated
captures showing the public URL and 0.1.8. Final read-only verification passed:
enabled public URL; exact cached/public/committed/accepted-candidate index;
receipt 0.1.8, 71 owned files and 14 exactly-once Main actions. Repository default
policy 2 matches the pre-update baseline; global `autoinstall=0` and
`prereleases=0`, unrelated repositories, private telemetry identity and telemetry
settings are unchanged. No further Computer Use, project operation, processing
or Help test was performed. Publication and installation follow-up are complete.

Public feed:
https://raw.githubusercontent.com/Logutin/reaper-reapack-neurocast-tools/main/index.xml

Public download, committed root index and accepted candidate all match
SHA-256 `301ea1773c8f3c322b39598d63dbccbe3b055da10e1e9b9736b46a684bf76b65`.
Installed receipt/files/actions already passed exact readback. Publication is
complete, including the owner's public-feed switch and final readback. Package
contents and historical feed entries remain unchanged.
