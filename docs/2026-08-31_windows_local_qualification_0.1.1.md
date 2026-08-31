# Neurocast Tools 0.1.1 Windows qualification

> **Source snapshot warning:** This evidence records the Windows x64
> qualification performed on 2026-08-31. Re-check the current feed, source
> commits, receipts, and installed bytes before relying on it for a later
> release.

## Verdict

**PASS for the selected limited-internal Windows x64 scope.**

This is not broad production qualification. macOS, signing/notarization,
legacy-install migration, difficult-network coverage, authenticated workflow
requalification, and another-user or another-machine testing remain
unqualified.

## Environment

- Disposable installation: `C:\extra_Reapers\Reaper_Empty_01`
- REAPER: 7.79/x64
- ReaPack: 1.2.6
- Package: `Neurocast_Tools 0.1.1`
- Runtime source: `auphonic-mt`
  `109e5d138b0f459319caa849b6684e602acfe629`
- Candidate distribution commit: `414ad8712ab63cc6b2a921f36fe1c7230129f40e`
- Package minimum: REAPER 7.72+

## Pre-assembly live evidence

The owner confirmed:

- DOCX Import parsed a clean two-row fixture with zero warnings and complete
  end timecodes, then created two items with 1.000 and 1.500 second lengths;
- Search Text created the expected marker;
- the setter and both toggle directions behaved correctly;
- Merge converted two selected items into one three-second item with ordered
  notes, removed temporary objects, and restored prior selection.

## Deterministic candidate checks

- 53 byte-exact Lua files: 13 Main actions and 40 support modules;
- all Lua files passed syntax checks;
- strict `reapack-index` validation passed;
- 171 platform-scoped sources: 61 win64 and 55 for each macOS architecture;
- all pinned binaries, notices, and native files matched recorded sizes and
  SHA-256 hashes;
- release-local curl 8.13.0 and 7-Zip 26.00 were used;
- release-local 7-Zip resolved its matching DLL and listed
  `word\document.xml` from the DOCX fixture;
- no telemetry identity, credentials, tests, generated wrappers, Network Fault
  Lab files, or FakeReaper files entered the package.

## ReaPack lifecycle

### Update from 0.1.0-pre1

The transaction reported `0.1.0-pre1 -> 0.1.1`. CLI readback verified:

- ReaPack receipt version `0.1.1`;
- 61 owned Windows files, including one native extension;
- exactly 13 registered Main actions with existing targets;
- all 60 package-directory files byte-matched the frozen candidate;
- no extra/generated wrappers;
- correct native-extension hash;
- preserved telemetry identity.

### Uninstall

CLI readback verified:

- no remaining ReaPack receipt or owned-file rows;
- package directory removed;
- all 13 action registrations removed;
- native extension removed;
- telemetry identity preserved.

### Clean install

The transaction reported `Neurocast Tools [new]` version `0.1.1`. CLI readback
again verified the 61-file receipt, 13 actions, exact package bytes, native
extension hash, zero generated wrappers, and preserved telemetry identity.

## Evidence boundary

No authenticated test account existed for this cycle. Authenticated
ElevenLabs, Manager, MVSEP, and Script Aligner workflows were not simulated and
remain explicitly unqualified for `0.1.1`.

Script Aligner remains the documented `https://studio.neurocast.tech` endpoint
exception. Its ambiguous-create duplicate risk is accepted technical debt and
is not a blocker for this limited-internal release.
