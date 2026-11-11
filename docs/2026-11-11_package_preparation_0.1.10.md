# Neurocast Tools 0.1.10 preparation

> **Source snapshot: November 11, 2026.** This record becomes stale when commits,
> running services or installation state change. Recheck them before cutover.

## State and ownership

The owner passed ElevenLabs v2.1.11 and v2.1.12 in live REAPER, requested client
commit/push and resumed backend/client release preparation. Source commit
[`49ef8535efa44dd8e49ad20e124fed7809d7dc51`](https://github.com/Logutin/auphonic-mt/commit/49ef8535efa44dd8e49ad20e124fed7809d7dc51)
is pushed to source `main`. No runtime correction was needed during final review.

The owner explicitly authorized `C:\extra_Reapers\Reaper_Empty_01` for candidate
installation/file checks. GUI acceptance remains owner-run. The initial readback
confirmed package 0.1.9, 71 exact Windows files and 14 Main actions. Preparation
does not change that installation, its private telemetry identity or settings.

Public root `index.xml` remains **0.1.9**. Candidate 0.1.10 has not been accepted
in REAPER or promoted. Production cutover and root-feed publication need a
separate final go-ahead after preparation. No agent-run REAPER or paid call was
performed. The October vacation hold is superseded for preparation only.

The owner deferred the 19 four-manual screenshots and new IPA capture. Complete
text-first manuals can ship; screenshot requests remain an editorial backlog.
Original embedded images are preserved. Missing screenshots and untested visual
layouts are not marked accepted.

## Frozen inputs and package scope

| Input | Pin / count |
| --- | --- |
| Runtime/manual source | `49ef8535efa44dd8e49ad20e124fed7809d7dc51` |
| Frozen candidate payload | `3e6419b14efd607463deec3d2ee7264ebcf83b92` |
| Previous distribution baseline | `48aeb1062bbe45c75656b7960f8d90375656e213` |
| Lua payload | 63 files: 13 changed/new exact source blobs, 50 unchanged historical payload files |
| Offline manuals | Six canonical HTML files, exact source bytes |
| Platform records | 219: Windows 77, macOS x86_64 71, macOS ARM64 71 |
| Main actions | 14 per platform |
| Native utilities, extensions and notices | Unchanged pinned bytes |

ElevenLabs v2.1.12 adds the IPA client, selected-track voice, contextual preview
and guarded Apply with slash-delimited IPA. The two new modules are
`pronunciation_controller.lua` and `pronunciation_context.lua`. AutoMix v0.1.3,
MVSEP v0.2.2, Script Aligner v0.1.1 and Manager v0.2.3 bring their previously
prepared Help wiring; their four HTML files enter the package for the first time.
DOCX v0.1.1 and its manual remain unchanged. Source versions are independent of
the package number. No legacy direct-era source is included.

Payload verification passed syntax, dependency closure (including custom require
wrappers), source/blob equality, all six Help paths, original image counts,
binary/notice pins, exact platform/action records and strict ReaPack validation.
The generated [candidate feed](../qualification/Neurocast_Tools_0.1.10_candidate.xml)
pins all 219 new source records to that payload commit and preserves all nine
historical versions. Its SHA-256 is
`c5814cca525a05098f1fd42a0c310547add5c97eae7661fe930b755858c1fc0a`.
Root `index.xml` is byte-identical to the previous distribution baseline.
The owner helper passed Lua syntax and six headless cases: both incorrect path
guards, missing prerequisites, setup, setup failure and installed instructions.
The disposable's identity, ReaPack configuration and action-list hashes remain
unchanged from the initial readback. No candidate install is claimed yet.
Source verification passed 15 Lua suites, localization (929 entries), manual,
link, hash, image-preservation and whitespace checks. Source live passes are
owner evidence; headless checks do not replace packaged GUI acceptance.

## Backend artifact and readiness

The backend remains clean on `fix/rpr-elevenlabs-provider-errors`, source
`7e7f1426753d24bdadaa8b7b2eb618cb3693b213`. All backend preparation ran inside
Ubuntu-24.04 WSL at `/home/slava/code/neurocast-reaper`. No backend push/merge or
production mutation was performed.

| Artifact | Identity |
| --- | --- |
| Source archive | `backend-7e7f142.tar` |
| Source archive SHA-256 | `4e37d4ff9c904e8420df42f6de464e3fea7c0202fd354afaf5c650f5d8c9401f` |
| Local image tag | `neurocast-reaper:release-7e7f142` |
| Image ID | `sha256:82bf36113c89555339a3468603a814f06dcdc12148afbf9e888b0689d68503e4` |
| Exported image | `backend-image-7e7f142.tar.gz`, 235736341 bytes |
| Exported image SHA-256 | `515a0d09393f9b43600cb1b08afde78e7d40662346e24ee34265be070548e04a` |
| Runtime | Linux amd64, non-root UID 1000, `1.15-pronunciation-20261109` |

Artifacts/logs live outside Git in WSL
`.tmp/release-preparation-20261111/`. The source archive and small evidence
receipts are also copied to `C:\code\auphonic-mt\tmp\release-preparation-20261111`.
The image was built from `git archive HEAD`, not the working directory: ignored
local `.tmp` fixtures must never enter a production build context. Inspection
confirmed no `.env` or `.tmp` inside the image. Configured-secret/prohibited-file
checks cover the selected archive, not all Git history or arbitrary secret forms.

Fresh Linux lint, typecheck, all **70 Jest suites / 979 tests** and build passed.
GRACE XML checks found 288 unique RPR semantic IDs, resolved all RPR references
and all 92 graph path/glob patterns. New-image probes passed actual eSpeak
regional profiles, gruut French, offline partial results, cache/feedback reuse
after container recreation, resident-worker timeout/restart, and live Wiktionary
extraction for French and both Portuguese regions. Disposable probe containers
and volume were removed; the existing local backend was unchanged and healthy.

Live local OpenAPI (16:19:29 UTC) advertises `1.15-pronunciation-20261109` and
both IPA routes. Production OpenAPI (16:03:05 UTC) returned HTTP 200 but still
advertises `1.9-manager-balance-precision-20260913`, without IPA routes. A healthy
old backend does not satisfy new-client readiness.

WSL host GitHub DNS failed during remote inspection (`Could not resolve host:
github.com`). Docker build/container internet and live Wiktionary succeeded.
This is not evidence of a Wiktionary outage. Host routes were left untouched.
The source archive/image provide a concrete handoff; remote source delivery,
registry/transport and production environment still need Nikita's coordination.

## Deployment and remaining owner check

Deploy the backend before publishing this client. Follow the source
[backend rollout record](https://github.com/Logutin/auphonic-mt/blob/49ef8535efa44dd8e49ad20e124fed7809d7dc51/docs/2026-11-11_release_preparation.md).
Nikita owns actual production Compose, secrets, networking, SQLite volume,
backup/cutover and rollback. Confirm the old image/config and a consistent
restorable SQLite backup; attach the same authoritative volume, start the pinned
image and verify migration 5. Do not deploy the local fixture or local Compose.
Read back image identity, health, OpenAPI/routes, auth/refresh, existing data and
one cached lookup in each locale. These checks need no paid audio. Existing
manager connections require explicit reconnection after restart.

For the candidate, the only remaining owner check is packaged startup/Help:

1. Start `C:\extra_Reapers\Reaper_Empty_01\reaper.exe` and run
   `qualification/Neurocast_Tools_0_1_10_candidate_and_smoke.lua` from this repository.
   It refuses another resource/executable path, configures the candidate feed
   and opens ReaPack for a manual 0.1.9 to 0.1.10 update.
2. Install 0.1.10, then run the helper again. Open installed ElevenLabs, confirm
   v2.1.12 starts and TTS > Pronunciation / IPA expands. No new listening test or
   IPA request against old production is needed.
3. Open Help in ElevenLabs, AutoMix, MVSEP, Script Aligner and ElevenLabs Manager.
   Confirm their own installed manuals are readable offline. Close normally and
   report pass or the exact failure.
4. After the owner's result, run `qualification/verify_0_1_10.py --installed`
   to verify receipt 0.1.10, all 77 installed bytes and 14 Main actions. Compare
   private identity with its saved baseline without publishing its contents.

Only after backend readiness, that packaged check/readback and final go-ahead
may the exact accepted candidate be promoted to root `index.xml`. Preserve all
nine historical versions and verify the public feed/update readback. macOS,
full browser/print layout and difficult-network qualification are not claimed.
