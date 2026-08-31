# Neurocast Tools 0.1.1 future release plan

> **Source snapshot warning:** This human-facing planning document reflects the
> runtime and distribution repositories as of 2026-08-31. It is planning
> support, not a release manifest or source lock; re-check current source and
> all release inputs before implementation.

## Status boundary

`Neurocast Tools 0.1.1` is an approved future limited-internal release target.
It is not assembled, indexed, qualified, published, tagged, or released.

The current published package remains the immutable `0.1.0-pre1`
limited-internal snapshot. This planning milestone does not modify
`release-manifest.yml`, `release-source-lock.yml`, `Neurocast_Tools/`, or
`index.xml`, and it does not rebind any historical `0.1.0-pre1` source URL.

The dependency projection originated from `auphonic-mt` runtime commit
`c046a69a6f48a81dfab18bb34d6db8182cc63bee` and was rechecked on 2026-08-31
against the source-preparation working tree containing the new Utility copies.
Neither state is the approved `0.1.1` source lock. A later release execution
must select and verify one clean pushed source commit.

## Release audience and authorization boundary

Every Neurocast Tools release is currently a **limited-internal release** for
selected team members. A plain version such as `0.1.1` is deliberate; absence
of a `-pre` suffix does not claim broad production qualification or public
readiness. Faster internal cycles are intended to produce real-world evidence.

All release operations are blocked until the owner:

1. prepares a disposable, isolated REAPER installation;
2. provides its exact path; and
3. explicitly authorizes the agent to operate that installation.

Preparatory source and documentation work may proceed before that gate. Release
assembly, manifest/source-lock creation, indexing, qualification, publication,
and any REAPER operation may not. After authorization, the agent must use only
the named disposable installation. It may still recommend owner-run tests when
a check benefits from the owner's workflow judgment.

## Package terminology

Neurocast Tools contains Tools and Utilities. Tools may additionally expose
Tool Actions for shortcuts.

| Concept | Meaning | Naming |
| --- | --- | --- |
| **Tool** | Substantial user-facing workflow/application, normally with its own GUI and state | `*_tool.lua` |
| **Utility** | Standalone, focused, one-shot REAPER operation | `utility_neurocast_*.lua` |
| **Tool Action** | Thin shortcut into functionality owned by a Tool | `action_neurocast_tools_*.lua` |

The four maintained wrappers under `actions-neurocast/` are Tool Actions. They
are not independent Utilities.

## Planned package shape

`0.1.1` remains one additive `Neurocast_Tools` metapackage. It preserves every
current Main action and targets exactly 13 Main actions: five Tools, four Tool
Actions, and four Utilities.

| # | Planned Main action | Type | Change from `0.1.0-pre1` | Release evidence boundary |
| ---: | --- | --- | --- | --- |
| 1 | `elevenlabs_tool.lua` | Tool | Refresh existing action | Normal local-backend Voice Library path is live-confirmed; difficult network and fresh production gates remain. |
| 2 | `elevenlabs_manager_tool.lua` | Tool | Retain and refresh existing action | Local workflow/auth are live-confirmed; fresh production-route preflight remains required. |
| 3 | `docx_import_tool.lua` | Tool | Add | Backend-neutral and headless-verified; its own packaged/tool live smoke is still required. |
| 4 | `neurocast_script_aligner_tool.lua` | Tool | Add | Minimal happy path was owner-confirmed in REAPER on 2026-08-31; broader fault and telemetry-readback evidence remains incomplete. Its backend exception stays fixed to `https://studio.neurocast.tech`. |
| 5 | `mvsep_tool.lua` | Tool | Add | Cancellation scope is live-confirmed; broader workflow and production preflight remain required. |
| 6 | `actions-neurocast/action_neurocast_tools_fast_sts_action.lua` | Tool Action | Retain existing action | Existing fixed ExtState wrapper. |
| 7 | `actions-neurocast/action_neurocast_tools_fast_tts_action.lua` | Tool Action | Retain existing action | Existing fixed ExtState wrapper. |
| 8 | `actions-neurocast/action_neurocast_tools_audio_tags_insert_action.lua` | Tool Action | Retain existing action | Existing fixed ExtState wrapper. |
| 9 | `actions-neurocast/action_neurocast_tools_audio_tags_remove_brackets_action.lua` | Tool Action | Retain existing action | Existing fixed ExtState wrapper. |
| 10 | `utilities-neurocast/utility_neurocast_Search_Text.lua` | Utility | Add | Self-contained; requires REAPER 7.72+ and retains its API capability check. |
| 11 | `utilities-neurocast/utility_neurocast_Merge_selected_items_text_notes.lua` | Utility | Add | Self-contained; copied behavior needs the package-path live smoke. |
| 12 | `utilities-neurocast/utility_neurocast_set_track_for_toggle_track_vol_and_solo.lua` | Utility | Add | Self-contained setter half of the package-isolated ExtState pair. |
| 13 | `utilities-neurocast/utility_neurocast_toggle_track_vol_and_solo.lua` | Utility | Add | Self-contained toggle half of the package-isolated ExtState pair. |

Automix is not planned for `0.1.1` because no isolated `automix_tool.lua`
package sibling exists. Direct API entrypoints and `scr/modules/` remain
excluded.

## Utility source identity and dependency check

The new Utility sources live under `auphonic-mt:scr/utilities-neurocast/`. The
four Direct API files in `scr/` remain unchanged.

The Utility copies intentionally reset the visible source identity from Direct
API toolset `v1.9.3` to `Neurocast Tools` with
`TOOLSET_VERSION = "v0.1.1"`. This is an intentional new-source identity, not a
distribution-repository rewrite during packaging.

Static inspection confirms that all four Utilities have:

- no Lua `require`, `dofile`, or `loadfile` dependency;
- no `modules-neurocast` or Direct API module dependency;
- no filesystem or network access;
- no curl, archive, native-extension, or ReaImGui dependency.

The setter and toggle are still a behavioral pair. They coordinate through the
new `neurocast_tools_toggle_track_vol_and_solo` persistent ExtState section,
which avoids colliding with the Direct API pair. This shared REAPER state is
not a Lua module dependency.

## Package minimum

**Package minimum: REAPER 7.72+.**

The Search Utility uses `reaper.AddRegionOrMarker`, checks for it before any
project mutation, and shows a clear unsupported-version message. No separate
minimum-version matrix will be maintained for individual package components.

## Projected Lua closure

The current `0.1.0-pre1` baseline has six Main actions and 21 support modules.
The planned seven added Main actions consist of three full Tools and four
module-free Utilities. The three full Tools add these 19 support modules to the
existing closure:

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

The projected source inventory is therefore 53 Lua files: 13 Main actions plus
40 support modules. No new binary or native-extension input is currently
anticipated: Windows already carries the pinned curl and matching 7-Zip pair,
macOS uses its system curl/unzip paths, and the existing native preview
extension remains the ElevenLabs preview dependency.

If the existing four notice files and platform policy remain unchanged, the
provisional applicable totals are 61 package-owned files for `win64` and 55
for each macOS architecture, producing 171 platform-scoped `@provides` rows.
These are planning projections, not approved manifest facts; recompute them
from the frozen source before assembly.

## Script Aligner duplicate-create release decision

The Script Aligner create POST remains inside the inherited generic retry
surface. If a create succeeds server-side but the response is ambiguous, a
retry may create a duplicate alignment.

This is known technical debt and must be visible in release notes, test
evidence, and operator guidance. It is **not a blocker for the limited-internal
`0.1.1` release**. Operators must not blindly retry an ambiguous create; they
must inspect existing Studio jobs first. Safe create retry must not be claimed
until reconciliation or backend idempotency exists.

## Gates before assembly

1. Satisfy the disposable isolated REAPER path and explicit-authorization gate.
   Until then, all release execution remains blocked.
2. Obtain fresh API documentation/preflight evidence for the Studio-dependent
   entrypoints and identify the exact backend snapshots. Preserve the Script
   Aligner `studio.neurocast.tech` exception.
3. Complete the DOCX Tool's own live REAPER smoke test in the authorized
   disposable installation, or ask the owner to run it if owner judgment is
   preferable.
4. Complete the remaining MVSEP broad workflow and production-backend gates
   selected for this limited-internal cycle.
5. Run the four Utilities' smallest live actions from their new package paths.
   Confirm the Search API guard and the shared toggle pair. Keep the package
   REAPER 7.72+ requirement explicit.
6. Record remaining Script Aligner fault, persistence, and telemetry gaps. The
   duplicate-create debt is an accepted non-blocker under the decision above.
7. Select one clean, pushed `auphonic-mt` source commit and recompute the exact
   five-Tool module closure. Do not mix runtime files from multiple unrecorded
   snapshots.
8. State the exact limited-internal platform/evidence claim. macOS,
   signing/notarization, migration, another-machine, backend, or difficult
   network areas not exercised in this cycle remain explicitly unqualified;
   they are not converted into broad-release claims by the plain version
   number.

## Future release execution

Only after a separate release command and the authorization gate above:

1. Create new `0.1.1` manifest and source-lock state while preserving all
   historical `0.1.0-pre1` sources immutably.
2. Copy exact source blobs into the distribution payload; do not edit runtime
   Lua in this repository.
3. Update the metapackage metadata and explicit per-platform `@provides` rows,
   including `utilities-neurocast/`, then regenerate `index.xml` with
   `reapack-index`; never edit generated XML manually.
4. Run fail-closed dependency, byte, hash, architecture, exclusion, minimum-
   version, and strict ReaPack checks.
5. Qualify both an update from `0.1.0-pre1` and a clean install/uninstall in the
   explicitly authorized disposable Windows REAPER. Verify exactly 13
   registered Main actions, preserved user/runtime data, the five Tool
   startup/workflow gates, all four Tool Actions, all four Utilities,
   release-local curl/7-Zip behavior, native preview APIs, and complete
   package-owned cleanup.
6. Verify the real raw-GitHub feed for the selected internal testers. Record
   every deferred platform, migration, machine, signing, backend, reliability,
   and technical-debt boundary without implying broad production readiness.

Until those steps are explicitly authorized and completed, `0.1.1` remains a
future plan and `0.1.0-pre1` remains the only published package version.
