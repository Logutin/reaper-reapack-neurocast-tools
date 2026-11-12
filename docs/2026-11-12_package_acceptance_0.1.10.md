# Neurocast Tools 0.1.10 owner acceptance and manual correction

> **Source snapshot: November 12, 2026.** Recheck feed, deployment and installed
> files before publication. This record supersedes the pending deployment and
> owner-check status in the November 11 preparation record.

## Owner-tested candidate

The owner installed 0.1.10 over 0.1.9 in
`C:\extra_Reapers\Reaper_Empty_01` and reported **All pass** for installed
ElevenLabs v2.1.12 startup/login against `https://reaper.neurocast.tech`,
`tia` in pt-PT/pt-BR, `bonjour` in fr-FR, repeated cached lookup and the five
changed Help entrypoints (ElevenLabs, AutoMix, MVSEP, Script Aligner, Manager).
Normal close passed. The owner also identified obsolete IPA manual wording.

The independently verified payload was
`3e6419b14efd607463deec3d2ee7264ebcf83b92`, source
`49ef8535efa44dd8e49ad20e124fed7809d7dc51`: receipt 0.1.10, 77 byte-exact owned
Windows files, 14 exactly-once Main actions and unchanged private identity.
No private identity contents or hashes are published.

Production OpenAPI returned HTTP 200 at 14:46:41 Moscow on November 12,
version `1.15-pronunciation-20261109`, with conversion and feedback routes.
The owner merged backend PR #27; GitHub build #6 published the image and Nikita
reported a separate manual Coolify deployment. Exact deployed digest, backup
execution and migration internals were not inferred from these checks.

## Documentation-only revision

Five manuals now identify their 0.1.10 package and production/Windows acceptance
correctly. The original candidate remains identified above; it is not silently
relabelled as the corrected artifact. All 63 Lua files, native components,
utilities, notices and DOCX HTML remain byte-identical to the owner-tested
payload. Source script versions remain unchanged, including ElevenLabs v2.1.12.
The package metadata and lock/manifest identify the documentation correction.

The corrected candidate feed will be regenerated from public 0.1.9 plus a new
immutable payload commit, without changing any of the nine public versions.
The verification command checks source/blob pins, all six manuals, dependency
closure, syntax, binaries, 219 platform rows and the new index URLs.

## Publication handoff

Public root `index.xml` remains 0.1.9 until final owner authorization. No new
paid listening test is required: runtime is unchanged and source listening/
Apply passed on November 11. Once publication is approved, promote the corrected
candidate, verify the public feed, and have the owner switch the disposable to
the public feed and reinstall 0.1.10 to receive its corrected manuals. Verify
77 exact installed files and 14 actions again; a same-version synchronization
alone does not prove the manual update was installed.

The current disposable still contains the original tested manual bytes until
that reinstall. Do not claim a successful installed readback of the corrected
manuals before it occurs. Missing illustrations stay deferred. This is limited
Windows acceptance, not measured pronunciation accuracy, a fresh production
feedback write, bad-connection, macOS, print-layout or full-content acceptance.

## Mechanical verification

Corrected source/manual pin: `fa51860c858df0c810d3d124899ec709c54216b3`.
The five revised HTML files match that commit exactly. Source checks passed
229 exact UI labels, all manual anchors and embedded JSON, source/hash
preservation, unchanged original screenshots and changed Markdown file links.
Payload verification passed 63 Lua syntax/content/dependency checks, six Help
assets, binary/notice pins, 219 records and strict ReaPack validation with zero
failures. A direct comparison against the owner-tested candidate found changes
only in five HTML manuals and the non-runtime package metadata. All 77 files
in the disposable still match the original accepted candidate.
