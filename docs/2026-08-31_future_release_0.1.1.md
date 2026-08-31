# Neurocast Tools 0.1.1 future release plan

> **Source snapshot warning:** This human-facing planning document reflects the
> runtime and distribution repositories as of 2026-08-31. It is planning
> support, not a release manifest or source lock; re-check current source and
> all release inputs before implementation.

## Status boundary

`Neurocast Tools 0.1.1` is an approved future release target. It is not
assembled, indexed, qualified, published, tagged, or released.

The current published package remains the immutable `0.1.0-pre1` limited
internal snapshot. This planning milestone does not modify
`release-manifest.yml`, `release-source-lock.yml`, `Neurocast_Tools/`, or
`index.xml`, and it does not rebind any historical `0.1.0-pre1` source URL.

The dependency projection below was computed from `auphonic-mt` runtime commit
`c046a69a6f48a81dfab18bb34d6db8182cc63bee`. That commit is planning evidence,
not the approved `0.1.1` source lock. A later implementation must select and
verify one fresh source commit after all entrypoint gates below are satisfied.

## Planned package shape

`0.1.1` remains one additive `Neurocast_Tools` metapackage. It preserves every
current Main action and targets exactly 13 Main actions:

| # | Planned Main action | Change from `0.1.0-pre1` | Release evidence boundary |
| ---: | --- | --- | --- |
| 1 | `elevenlabs_tool.lua` | Refresh existing action | Normal local-backend Voice Library path is live-confirmed; difficult network and fresh production gates remain. |
| 2 | `elevenlabs_manager_tool.lua` | Retain and refresh existing action | Local workflow/auth are live-confirmed; fresh production-route preflight remains required. |
| 3 | `docx_import_tool.lua` | Add | Backend-neutral and headless-verified; its own packaged/tool live smoke is still required. |
| 4 | `neurocast_script_aligner_tool.lua` | Add | Minimal happy path was owner-confirmed in REAPER on 2026-08-31; broader fault and telemetry-readback gates remain. Its backend exception stays fixed to `https://studio.neurocast.tech`. |
| 5 | `mvsep_tool.lua` | Add | Cancellation scope is live-confirmed; broader workflow and production preflight remain required. |
| 6 | `actions-neurocast/action_neurocast_tools_fast_sts_action.lua` | Retain existing action | Existing fixed ExtState wrapper. |
| 7 | `actions-neurocast/action_neurocast_tools_fast_tts_action.lua` | Retain existing action | Existing fixed ExtState wrapper. |
| 8 | `actions-neurocast/action_neurocast_tools_audio_tags_insert_action.lua` | Retain existing action | Existing fixed ExtState wrapper. |
| 9 | `actions-neurocast/action_neurocast_tools_audio_tags_remove_brackets_action.lua` | Retain existing action | Existing fixed ExtState wrapper. |
| 10 | `Search_Text.lua` | Add | Standalone/no module imports; requires REAPER 7.72+ and a package-appropriate title identity before source freeze. |
| 11 | `Merge_selected_items_text_notes.lua` | Add | Standalone/no module imports; package-appropriate title identity is required before source freeze. |
| 12 | `set_track_for_toggle_track_vol_and_solo.lua` | Add | Standalone/no module imports; package-appropriate title identity is required before source freeze. |
| 13 | `toggle_track_vol_and_solo.lua` | Add | Standalone/no module imports; package-appropriate title identity is required before source freeze. |

The four generic helpers keep the same filenames requested for the future
package. Their current source titles display the Direct API toolset version
`v1.9.3`. Resolve that product identity in `auphonic-mt` as an intentional
source change before freezing the release; do not replace it with a fake Lua
`SCRIPT_VERSION` or `TOOLSET_VERSION` bump merely to match the ReaPack package
version.

Automix is not planned for `0.1.1` because no isolated `automix_tool.lua`
package sibling exists. Direct API entrypoints and `scr/modules/` remain
excluded.

## Projected Lua closure

The current `0.1.0-pre1` baseline has six Main actions and 21 support modules.
The planned seven added Main actions consist of three full tools and four
dependency-free helpers. The three full tools add these 19 support modules to
the existing closure:

DOCX Import adds eight:

- `docx_dialogue_parser.lua`
- `docx_import_tool_languages.lua`
- `docx_telemetry_summary.lua`
- `docx_xml_extractor.lua`
- `docx_xml_parser.lua`
- `Parse.lua`
- `ReaperX_import_Dialogue.lua`
- `track_colors.lua`

Script Aligner adds five:

- `neurocast_script_aligner_helper.lua`
- `neurocast_script_aligner_reaper.lua`
- `neurocast_script_aligner_result.lua`
- `neurocast_script_aligner_settings.lua`
- `neurocast_script_aligner_tool_languages.lua`

MVSEP adds six:

- `mvsep_api.lua`
- `mvsep_api_via_neurocast.lua`
- `mvsep_model_options.lua`
- `mvsep_reaper.lua`
- `mvsep_tool_languages.lua`
- `ReaperX_render_settings_helper.lua`

The projected current-source inventory is therefore 53 Lua files: 13 Main
actions plus 40 support modules. No new binary or native-extension input is
currently anticipated: Windows already carries the pinned curl and matching
7-Zip pair, macOS uses its system curl/unzip paths, and the existing native
preview extension remains the ElevenLabs preview dependency.

If the existing four notice files and platform policy remain unchanged, the
provisional applicable totals are 61 package-owned files for `win64` and 55
for each macOS architecture, producing 171 platform-scoped `@provides` rows.
These are planning projections, not approved manifest facts; recompute them
from the frozen source before assembly.

## Gates before assembly

1. Obtain fresh API documentation/preflight evidence for the Studio-dependent
   entrypoints and identify the exact backend snapshots. Preserve the Script
   Aligner `studio.neurocast.tech` exception.
2. Complete the DOCX tool's own live REAPER smoke test.
3. Complete the remaining MVSEP broad workflow and production-backend gates.
4. Resolve the four helper title/version identities in `auphonic-mt`, then run
   their smallest live actions. Keep the Search action's REAPER 7.72+
   requirement explicit.
5. Finish the remaining Script Aligner fault, persistence, and telemetry
   checks; retain the ambiguous-create duplicate risk as known technical debt.
6. Select one clean, pushed `auphonic-mt` source commit and recompute the exact
   five-entrypoint module closure. Do not mix runtime files from multiple
   unrecorded snapshots.
7. Decide the supported platform/qualification claim. A non-prerelease version
   number does not waive macOS, signing/notarization, another-machine, backend,
   or reliability gates.

## Future release execution

Only after a separate implementation command:

1. Create new `0.1.1` manifest and source-lock state while preserving all
   historical `0.1.0-pre1` sources immutably.
2. Copy exact source blobs into the distribution payload; do not edit runtime
   Lua in this repository.
3. Update the metapackage metadata and explicit per-platform `@provides` rows,
   then regenerate `index.xml` with `reapack-index`; never edit generated XML
   manually.
4. Run fail-closed dependency, byte, hash, architecture, exclusion, and strict
   ReaPack checks.
5. Qualify both an update from `0.1.0-pre1` and a clean install/uninstall in the
   disposable Windows REAPER. Verify exactly 13 registered Main actions,
   preserved user/runtime data, the five full-tool startup/workflow gates, all
   eight small actions, release-local curl/7-Zip behavior, native
   preview APIs, and complete package-owned cleanup.
6. Verify the real raw-GitHub feed before broadening availability. Record
   macOS, migration, another-user/machine, signing, backend, and difficult
   network evidence independently rather than inferring it from Windows.

Until those steps are explicitly authorized and completed, `0.1.1` remains a
future plan and `0.1.0-pre1` remains the only published package version.
