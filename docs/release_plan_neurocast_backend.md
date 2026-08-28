# Neurocast-backend ReaPack release plan

> Planning snapshot: 2026-08-28, based on `auphonic-mt` commit
> `238097e631e0cbf6e9c687dab09184649864fc6a`. This document is not a live
> backend contract. Recheck source and release inputs before implementation.

## Scope and ownership

The package display name is **Neurocast Tools**, the repository/package
directory slug is `Neurocast_Tools`, and the approved first pre-release version
is `0.1.0-pre1`.

The repositories have deliberately separate responsibilities:

- `Logutin/auphonic-mt` owns the maintained Neurocast-backed Lua entrypoints,
  their isolated `modules-neurocast` runtime tree, source tests, and the
  Neurocast-backend release policy and documentation.
- `Logutin/reaper_cyr_essentials` owns the native preview extension source,
  native builds, and build evidence.
- `Logutin/reaper-reapack-neurocast-tools` is distribution-only. It will own
  ReaPack package metadata, explicitly selected payload copies, the generated
  ReaPack index, and release history after later milestones approve them.

The existing Google Drive ZIP workflow in `auphonic-mt` remains the **Direct API release track**. It is not renamed, edited, or replaced by this plan. The
new **Neurocast-backend release track** is likewise owned and documented in
`auphonic-mt`; this repository serves only as that track's ReaPack distribution
repository.

## One-package architecture

There will be one ReaPack metapackage and no split feature packages. Its first
version exposes exactly six Main actions:

1. `Neurocast_Tools/elevenlabs_tool.lua`
2. `Neurocast_Tools/elevenlabs_manager_tool.lua`
3. `Neurocast_Tools/actions-neurocast/action_neurocast_tools_fast_sts_action.lua`
4. `Neurocast_Tools/actions-neurocast/action_neurocast_tools_fast_tts_action.lua`
5. `Neurocast_Tools/actions-neurocast/action_neurocast_tools_audio_tags_insert_action.lua`
6. `Neurocast_Tools/actions-neurocast/action_neurocast_tools_audio_tags_remove_brackets_action.lua`

The intended installed layout is:

```text
Neurocast_Tools/
  elevenlabs_tool.lua
  elevenlabs_manager_tool.lua
  actions-neurocast/
    action_neurocast_tools_fast_sts_action.lua
    action_neurocast_tools_fast_tts_action.lua
    action_neurocast_tools_audio_tags_insert_action.lua
    action_neurocast_tools_audio_tags_remove_brackets_action.lua
  modules-neurocast/
    <explicit Lua runtime closure>
  bin/win/
    curl.exe
    7z.exe
    7z.dll
  licenses/
    <applicable third-party notices>
UserPlugins/
  reaper_cyr_essentials.dll       # win64 only
  reaper_cyr_essentials.dylib     # one matching macOS architecture only
```

All six Lua Main actions and the support modules are platform-independent and
must be identical for `win64`, `darwin64`, and `darwin-arm64`. Windows x64
alone receives the pinned `curl.exe`, `7z.exe`, and `7z.dll`. macOS uses
`/usr/bin/curl`; it does not receive Windows executables. The matching
`reaper_cyr_essentials` binary is installed per architecture:

| ReaPack platform | Host | Native input |
| --- | --- | --- |
| `win64` | Windows x64 | `reaper_cyr_essentials.dll` (PE x86_64) |
| `darwin64` | macOS x86_64 | thin x86_64 `reaper_cyr_essentials.dylib` |
| `darwin-arm64` | macOS ARM64 | thin ARM64 `reaper_cyr_essentials.dylib` |

ReaImGui is an external prerequisite and will not be vendored. The native
extension supplies `reaper.cyr_essentials_Preview_PlayFile` and
`reaper.cyr_essentials_Preview_Stop`; the main tool can otherwise start without
those APIs, but native preview is unavailable.

7-Zip is a deliberate shared package input for upcoming managed-entrypoint
parity. None of the six Main actions currently loads or invokes it.
Keeping `7z.exe` and its matching `7z.dll` together prevents a later parity
release from accidentally depending on a developer machine's global 7-Zip.

The manifest-derived Lua inventory is 27 files: six Main actions and 21
support modules. The unique planned payload inventory is 37 entries: six Main
actions, 25 support files (the 21 modules plus four notice files), three
binaries, and three mutually exclusive extension variants. The applicable
per-platform totals are 35 for `win64` (6 Main actions, 25 support files, 3
binaries, 1 extension), 29 for `darwin64` (6 Main actions, 22 support files, no
Windows binaries, 1 extension), and 29 for `darwin-arm64` with the same role
breakdown as `darwin64`.

## Version policy

`0.1.0-pre1` is the ReaPack package version. It identifies one reviewed package
inventory and is independent of every Lua `SCRIPT_VERSION` or `TOOLSET_VERSION`
constant. Packaging must not change runtime source constants merely to match a
ReaPack package version.

## Release gates

### Automated verification gate

Before an installable package can be proposed, automation must fail closed
unless all of the following pass:

- the source lock resolves to the approved `auphonic-mt` commit;
- every explicitly listed Lua input exists and the computed literal/transitive
  dependency closure equals the manifest;
- exactly six approved sources are declared as Main actions;
- platform-independent Lua bytes are shared across all three targets;
- binary sizes and SHA-256 hashes equal the approved logical inputs;
- each native artifact has the expected PE/Mach-O architecture and exported
  REAPER plugin entry point;
- Windows contains the matching curl and 7-Zip input set, while macOS contains
  none of those Windows binaries;
- no source is unscoped or Linux-scoped;
- excluded development, test, secret, cache, log, manual-localization-source,
  legacy Neurocast-generated wrapper, and Direct API runtime-generated wrapper
  files are absent, without excluding the four fixed maintained
  `scr/actions-neurocast/action_neurocast_tools_*.lua` Main-action sources;
- strict ReaPack validation and a semantic index review pass when package
  metadata and `index.xml` exist in a later milestone.

### Windows internal install/update/uninstall gate

On Windows x64, an internal qualification pass must exercise a clean install,
an update from the immediately preceding internal build, and uninstall. It must
verify that the two full tool entrypoints launch correctly, each of the four
fixed wrapper Main actions is registered exactly once and fires its exact
ExtState trigger, the support modules load, the pinned curl version is used,
7-Zip resolves its release-local DLL, the native extension API is present, and
every package-owned file is removed without removing runtime/user-created
data.

### macOS internal install/native-preview gate

Separate internal passes are required on macOS x86_64 and macOS ARM64. Each
must verify installation of only its thin native binary, successful REAPER
extension loading, both native preview API functions, audible play/stop and
replacement with a real local audio file, correct launch of the two full tool
entrypoints, exactly-once registration and exact ExtState-trigger behavior for
all four fixed wrapper Main actions, use of `/usr/bin/curl`, and clean
uninstall. Signing, notarization, quarantine, and Gatekeeper acceptance remain
unresolved qualification work; build evidence alone is not native runtime
evidence.

### Existing tester installation migration gate

Files matching `Neurocast_Tools__*.lua` are legacy migration artifacts from the
former Neurocast wrapper-generation behavior. They are not maintained package
inputs. Qualification against an existing tester installation must be a
deliberate, recorded migration:

1. Inventory old Neurocast `Neurocast_Tools__*.lua` files and their REAPER
   action registrations.
2. Identify only the four old Neurocast wrappers associated with these
   established Neurocast ExtState action IDs:
   `fast_STS_flow_action_for_hotkey_trigger`,
   `fast_TTS_flow_action_for_hotkey_trigger`,
   `audio_tags_insert_selected_notes_action_for_hotkey_trigger`, and
   `audio_tags_remove_brackets_selected_notes_action_for_hotkey_trigger`.
3. Record existing hotkey assignments before removing any stale registration.
4. Unregister only those obsolete Neurocast actions and deliberately remove
   their obsolete files.
5. Install or update the ReaPack package.
6. Verify that each of the four fixed package-owned wrapper actions is
   registered exactly once; verify or restore the intended tester hotkey
   assignments as necessary.
7. Execute each wrapper and confirm that it fires its exact ExtState trigger,
   then verify both full tool actions as well.

The separate Direct API runtime-generated wrapper workflow must be preserved;
Direct API wrappers must not be removed. Current runtime code must not
automatically delete, rewrite, migrate, or synthesize the legacy Neurocast
files.

## Follow-on milestones

1. **Implementation:** add a source-lock snapshot, package metadata, controlled
   assembly tooling, required license/notices, and copied payloads only after
   this inventory is approved.
2. **Package qualification:** run the automated gate plus Windows
   install/update/uninstall and both macOS install/native-preview gates. Resolve
   signing/notarization policy and any ReaPack destination details found during
   real installation.
3. **Release:** approve final package metadata, generate and semantically review
   `index.xml`, tag the immutable distribution commit, push, and create the
   public pre-release only after qualification evidence is accepted.

This milestone performs none of those implementation, qualification, or
publication actions.
