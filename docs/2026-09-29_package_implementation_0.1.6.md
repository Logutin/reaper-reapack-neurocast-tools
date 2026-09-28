# Neurocast Tools 0.1.6 candidate record

> **Source snapshot warning:** This record describes preparation on 2026-09-29.
> Recheck current pins, feeds, installed receipts and owner acceptance before
> relying on it for publication or a later release.

## Status and scope

Candidate prepared for limited-internal use; owner packaged acceptance and
public-feed promotion are pending. The owner requested minimal tests and the
usual helper, and authorized only
`C:\extra_Reapers\Reaper_Empty_01\reaper.exe`. Public `index.xml` remains at
`0.1.5` until the owner accepts the installed candidate and mechanical readback
passes. The separate candidate is not a public-feed promotion.

Source pin: `auphonic-mt` `a3cb30115e19944133a01bbdd76fc667a5922211`.
Previous distribution baseline: `142103b81fa9f348ff420398cf5e3d735bad178b`.
Frozen payload commit: `a786551778352ec71cb4f9c78589b9a2765c3fd9`.

The owner reported "Tested all - works as intended" for the Windows Help
source checklist; this is recorded in the source pin. Existing STS preparation
and wording acceptance are also source evidence. This report does not qualify
a new installed package, real macOS opening or a specific SWS/no-SWS route.

Two existing shipped Lua files update: `elevenlabs_tool.lua` to `v2.1.4` and
`modules-neurocast/elevenlabs_tool_languages.lua`. One Lua support file is new:
`modules-neurocast/offline_manual.lua`. The new Russian HTML is a support asset
at `manuals/2026-09-28_elevenlabs_tool_manual_ru_draft.html`, resolved relative
to the installed entrypoint. All four files match committed source bytes.
All 31 original screenshot payloads are retained. SWS is optional; without it
the opener uses Windows PowerShell or macOS `open`.

This incorporates STS preparation/wording since packaged ElevenLabs `v2.1.1`.
The other 58 Lua files, binaries, native extensions and notices retain `0.1.5`
bytes. Seven unchanged Lua files retain historical CRLF; the updated language
module now uses exact LF source bytes. Inventory: 61 Lua inputs, one offline
HTML, 198 platform records, 70 Windows files, 64 files on each Mac target and
14 Main actions per platform. REAPER 7.72+ and external ReaImGui remain package
prerequisites; individual tool compatibility guards still apply. Source-level
script/toolset versions remain independent of package `0.1.6`.

## Minimal verification

Read-only baseline passed in the authorized disposable: installed `0.1.5`,
all 68 owned files matching package bytes and 14 exactly-once Main actions.
The named REAPER process was already running; no agent desktop control or
direct modification of the installed payload was performed. The configured
feed was the public root, manual installation, with global `autoinstall=0`
and `prereleases=0`. Identity material is excluded from the payload.

Fresh source checks passed: 13 offline Help groups, 14 STS preparation groups,
fixed hotkey regression and unchanged manual screenshot checks. The payload
verifier passed 61 Lua syntax/content/dependency checks, exact manual path and
hash, payload exclusions, all unchanged-file comparisons, binary/notice pins,
package-local matching 7-Zip 26.03 pair, 198 metadata rows and action counts.
`reapack-index --check --strict --warnings .` passed one package, zero failures.
The owner helper passed Lua syntax checking and five mocked cases: wrong
resource path, wrong executable path, manual candidate setup, installed marker
readback, and visible repository-setup failure. No live settings were changed.

Candidate index: `qualification/Neurocast_Tools_0.1.6_candidate.xml`, generated
with `reapack-index --scan a786551778352ec71cb4f9c78589b9a2765c3fd9 --no-amend
--strict --warnings --no-commit` and the separate output path. All 198 new
source URLs pin that frozen payload commit. The verifier passed all six
historical version records unchanged, each path/platform/role, and current
payload bytes against that commit. Root index bytes are unchanged. Promotion must copy the qualified candidate
verbatim to root `index.xml` after owner acceptance and installed readback.

Candidate SHA-256:
`e589e2de158a7f13d5bd1292abf13dd040efe03db6179759f0fffbb1fc9945ac`.

The official REAPER API reference and changelog were checked on 2026-09-29
(generated/current version 7.81); the helper retains the previously qualified
ReaPack setup calls and executable/resource path guards.

## Owner action now required

1. In only `C:\extra_Reapers\Reaper_Empty_01\reaper.exe`, load/run
   `qualification/Neurocast_Tools_0_1_6_candidate_and_smoke.lua` from this
   repository. It refuses any other executable or resource path.
2. Wait for synchronization, apply only the Neurocast Tools `0.1.5 -> 0.1.6`
   update, then run the helper again. Its markers are a preliminary presence
   check; independent byte/receipt verification follows your report.
3. Open installed `elevenlabs_tool.lua` from Actions. Confirm `v2.1.4` starts
   without an error; click Help and confirm the Russian manual opens from this
   installation's `manuals` folder and the header remains on one row. Close the
   tool normally. No login or processing request is needed.
4. Report pass/failure. The agent will verify installed bytes, ownership and
   action registrations before publication. Public-feed restoration follows
   publication using the existing restore helper.

This minimal gate does not repeat authenticated workflows, paid processing,
bad-network cases, clean install/uninstall or Mac testing. Existing MVSEP
telemetry and Script Aligner ambiguous-create retry limitations remain. No
backend contract change, native rebuild, identity creation, GitHub Release,
tag or direct-era ZIP is part of this routine.
