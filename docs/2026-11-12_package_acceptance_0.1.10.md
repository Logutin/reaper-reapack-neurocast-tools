# Neurocast Tools 0.1.10 release and acceptance

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

The corrected candidate feed was regenerated from public 0.1.9 plus new
immutable payload commit `91e233c5be1478d72659cf1789d08c1a27ab32e6`, without
changing any of the nine public versions.
The verification command checks source/blob pins, all six manuals, dependency
closure, syntax, binaries, 219 platform rows and the new index URLs.

## Publication handoff

The owner explicitly authorized publication on November 12. Public root
`index.xml` promotes the corrected candidate byte-for-byte as limited-internal
0.1.10. No new paid listening test is required: runtime is unchanged and source
listening/Apply passed on November 11. Public download verification and the
owner disposable public-feed reinstall are complete. Independent readback
confirms 77 exact installed files and 14 actions; synchronization alone was
not used as proof of corrected-manual installation.

The current disposable contains the corrected published manuals; exact-file
verification passed after the owner reported the reinstall live test passed.
Missing illustrations stay deferred. This is limited
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
only in five HTML manuals and the non-runtime package metadata. Before the
final reinstall, all 77 disposable files matched the original accepted candidate;
after reinstall they match the corrected published payload.

The generated candidate index passed all 219 pinned URL/role/platform checks
and preservation of all nine historical versions. Candidate XML SHA-256:
`ba5f2ae988292766ea9aafd40242e8084c7baf8f6bb0aabf8896fd142d8ec6ce`. The public root
feed is now the exact same generated artifact, following final owner approval.
No published historical version or pinned payload was modified.

## Final disposable reinstall

The owner completed the public-feed switch and same-version reinstall in
`C:\extra_Reapers\Reaper_Empty_01`, then reported: "Reinstalled. Tested live.
Pass." Independent readback confirmed receipt 0.1.10, all 77 exact published
files, 14 exactly-once Main actions, one enabled public-root repository with
manual installation retained, byte-exact cached public index and the unchanged
private identity. All six manuals match the corrected frozen payload. The
limited-internal Windows release checks are complete.

## Public download verification

Publication commit: `cf54ff947482ef781d65e2b898cce8d1cad829f3`.
At 15:24:33 Moscow on November 12, the normal public
`https://raw.githubusercontent.com/Logutin/reaper-reapack-neurocast-tools/main/index.xml`
URL returned the exact promoted index. All five corrected immutable manual URLs
also returned byte-exact files. Root feed and candidate SHA-256 remain
`ba5f2ae988292766ea9aafd40242e8084c7baf8f6bb0aabf8896fd142d8ec6ce`.
A final normal-public-URL check at 15:46:19 Moscow returned HTTP 200 and the
same exact index, with ten versions and 219 current source records. The
post-reinstall payload/index/receipt/file/action verification passed, including
all nine historical versions. The local ReaPack cache matches this feed and
the private identity matches its pre-update baseline. The owner's final live
pass and these independent checks close the release. No paid generation or
agent-operated project changes were needed; deferred broader checks remain
separate.
