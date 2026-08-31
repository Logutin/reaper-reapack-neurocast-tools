# Neurocast-backend ReaPack release plan

> Source snapshot: 2026-08-29, based on `auphonic-mt` commit
> `238097e631e0cbf6e9c687dab09184649864fc6a`. The package source tree is
> assembled, its Windows x64 local qualification passed, and its limited
> internal GitHub publication plus real-feed Windows clean-install check passed
> on 2026-08-29. macOS remains unqualified. This document is not a live backend
> contract; recheck source and release inputs before future work.

> **Future planning note:** `Neurocast Tools 0.1.1` is now the approved future
> limited-internal additive target with 13 planned Main actions: five Tools,
> four Tool Actions, and four Utilities. Package minimum is REAPER 7.72+. It is
> not assembled or released, and release execution is blocked until the owner
> provides and explicitly authorizes a disposable isolated REAPER installation.
> See
> [`2026-08-31_future_release_0.1.1.md`](2026-08-31_future_release_0.1.1.md).
> All `0.1.0-pre1` inventory, source, qualification, and publication statements
> below remain historical/current-release facts and must not be rebound.

## Scope and ownership

The package display name is **Neurocast Tools**, the repository/package
directory slug is `Neurocast_Tools`, and the approved first pre-release version
is `0.1.0-pre1`.

Every Neurocast Tools release is currently limited internal for selected team
members. Future releases may use plain semantic versions such as `0.1.1`; the
lack of a `-pre` suffix does not claim broad production qualification. A
broader release would require a separate policy decision and evidence plan.

The repositories have deliberately separate responsibilities:

- `Logutin/auphonic-mt` owns the maintained Neurocast-backed Lua entrypoints,
  their isolated `modules-neurocast` runtime tree, source tests, and the
  Neurocast-backend release policy and documentation.
- `Logutin/reaper_cyr_essentials` owns the native preview extension source,
  native builds, and build evidence.
- `Logutin/reaper-reapack-neurocast-tools` is distribution-only. It owns the
  assembled ReaPack package metadata, explicitly selected payload copies, and
  version-specific source lock. Its generated repository index is now published
  for limited internal testing; tags and GitHub releases remain later-milestone
  work.

The existing Google Drive ZIP workflow in `auphonic-mt` remains the **Direct API release track**. It is not renamed, edited, or replaced by this plan. The
new **Neurocast-backend release track** is likewise owned and documented in
`auphonic-mt`; this repository serves only as that track's ReaPack distribution
repository.

## One-package architecture

There is one assembled ReaPack metapackage and no split feature packages. Its
first candidate exposes exactly six Main actions:

1. `Neurocast_Tools/elevenlabs_tool.lua`
2. `Neurocast_Tools/elevenlabs_manager_tool.lua`
3. `Neurocast_Tools/actions-neurocast/action_neurocast_tools_fast_sts_action.lua`
4. `Neurocast_Tools/actions-neurocast/action_neurocast_tools_fast_tts_action.lua`
5. `Neurocast_Tools/actions-neurocast/action_neurocast_tools_audio_tags_insert_action.lua`
6. `Neurocast_Tools/actions-neurocast/action_neurocast_tools_audio_tags_remove_brackets_action.lua`

The intended installed layout represented by the assembled source tree is:

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
support modules. The unique assembled payload inventory is 37 entries: six Main
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

For future `0.1.1`, the new Utility copies intentionally carry
`TOOLSET_VERSION = "v0.1.1"` as their source-level Neurocast package identity.
That identity reset happens in the runtime source repository before source
freeze; the distribution repository still copies exact frozen blobs and does
not rewrite version constants during packaging.

## Future script taxonomy

- **Tool:** substantial user-facing workflow/application, named `*_tool.lua`.
- **Utility:** standalone focused one-shot operation, named
  `utility_neurocast_*.lua` and installed under `utilities-neurocast/`.
- **Tool Action:** thin shortcut into a Tool, named
  `action_neurocast_tools_*.lua` and installed under `actions-neurocast/`.

The four existing ElevenLabs wrappers are Tool Actions, not Utilities. The
future four Utilities are module-free; the setter/toggle pair shares an
isolated persistent ExtState namespace but does not load code from another
file. See the dated `0.1.1` plan for the exact filenames.

## REAPER authorization gate for future releases

Preparatory source and documentation work may proceed, but no future release
assembly, indexing, qualification, publication, or REAPER operation may begin
until the owner prepares a disposable isolated REAPER installation, provides
its exact path, and explicitly authorizes the agent to use it. Once authorized,
the agent may operate only that named installation and may recommend specific
owner-run checks when human workflow judgment is preferable.

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
- strict ReaPack validation and semantic review of the generated repository
  `index.xml` pass with one package, one version, and all 93 version sources
  pinned to package commit
  `3960757e8a9a0452c8aac1a36248f26a4a9274fe`.

### Windows internal install/update/uninstall gate

On Windows x64, an internal qualification pass must exercise a clean install,
an update from the immediately preceding internal build, and uninstall. It must
verify that the two full tool entrypoints launch correctly, each of the four
fixed wrapper Main actions is registered exactly once and fires its exact
ExtState trigger, the support modules load, the pinned curl version is used,
7-Zip resolves its release-local DLL, the native extension API is present, and
every package-owned file is removed without removing runtime/user-created
data.

The `0.1.0-pre1` clean-install/live-test/uninstall pass completed successfully
on 2026-08-29 against package commit
`3960757e8a9a0452c8aac1a36248f26a4a9274fe`; see the
[Windows qualification record](2026-08-29_windows_local_qualification_0.1.0-pre1.md).
Prior-version update behavior was not exercised because no earlier Neurocast
Tools ReaPack version exists. That deferred case must not be inferred from the
fresh-install result.

The real GitHub delivery-path check also passed on 2026-08-29 using the
disposable Windows REAPER instance. ReaPack synchronized the public raw-GitHub
index, clean-installed 35 package-owned Windows files, registered six Main
actions, and loaded both native preview APIs after restart. All installed files
matched the qualified package commit. This delivery check does not qualify
prior-version update, legacy-install migration, or another user or machine.

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

Both macOS architecture passes are deliberately deferred by owner decision and
remain unqualified.

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

1. **Implementation — assembled:** the source lock, package metadata, required
   component notices, and copied payloads are present. No reusable assembly
   tooling was added. Static and isolated ReaPack checks are the gate for this
   milestone.
2. **Package qualification — Windows local pass recorded:** the Windows x64
   fresh-install, live-test, and uninstall gates passed. Prior-version update,
   legacy-wrapper migration, other-machine testing, both macOS architecture
   passes, and signing/notarization remain unqualified.
3. **Limited internal publication — completed:** the generated root
   `index.xml` is published at the real raw-GitHub repository URL for 1–2
   trusted internal testers, and the Windows delivery path passed from that
   feed. This did not change the qualified package payload or version and does
   not imply a broadly qualified public production release.
4. **Broader release — outside current policy:** every current release remains
   limited internal. Any future move beyond selected internal testers requires
   an explicit policy decision plus the relevant platform, update, migration,
   and another-user or another-machine evidence. A tag or GitHub release was
   not required for the limited-internal milestone and has not been created.

The package is now `installable: true` for limited internal testing through the
root `index.xml`. Windows x64 is qualified. macOS x86_64 and ARM64,
prior-version update, legacy-install migration, and another-user or
another-machine testing remain unqualified or pending. No tag, GitHub release,
GitHub Actions workflow, signing, or notarization was added.
