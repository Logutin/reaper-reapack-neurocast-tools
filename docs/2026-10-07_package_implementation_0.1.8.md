# Neurocast Tools 0.1.8 release record

> **Source snapshot warning:** Release preparation as of 2026-10-07. Recheck
> feed, source pins and installed state before relying on this dated record.

## Scope and status

Prepared for limited-internal delivery at the owner's request. Public feed
remains at 0.1.7 until the installed startup/Help check and byte readback pass.
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
