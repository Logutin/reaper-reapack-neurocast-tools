# Neurocast-backend ReaPack release plan

> Planning snapshot: 2026-08-28, based on `auphonic-mt` commit
> `6a277016a15a25148300120c317fbcc195f640ec`. This document is not a live
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
version exposes exactly two Main actions:

1. `Neurocast_Tools/elevenlabs_tool.lua`
2. `Neurocast_Tools/elevenlabs_manager_tool.lua`

The intended installed layout is:

```text
Neurocast_Tools/
  elevenlabs_tool.lua
  elevenlabs_manager_tool.lua
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

The Lua entrypoints and modules are platform-independent and must be identical
for `win64`, `darwin64`, and `darwin-arm64`. Windows x64 alone receives the
pinned `curl.exe`, `7z.exe`, and `7z.dll`. macOS uses `/usr/bin/curl`; it does
not receive Windows executables. The matching `reaper_cyr_essentials` binary is
installed per architecture:

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
parity. Neither of the first two Main actions currently loads or invokes it.
Keeping `7z.exe` and its matching `7z.dll` together prevents a later parity
release from accidentally depending on a developer machine's global 7-Zip.

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
- exactly two sources are declared as Main actions;
- platform-independent Lua bytes are shared across all three targets;
- binary sizes and SHA-256 hashes equal the approved logical inputs;
- each native artifact has the expected PE/Mach-O architecture and exported
  REAPER plugin entry point;
- Windows contains the matching curl and 7-Zip input set, while macOS contains
  none of those Windows binaries;
- no source is unscoped or Linux-scoped;
- excluded development, test, secret, cache, log, manual-localization-source,
  and generated-wrapper files are absent;
- strict ReaPack validation and a semantic index review pass when package
  metadata and `index.xml` exist in a later milestone.

### Windows internal install/update/uninstall gate

On Windows x64, an internal qualification pass must exercise a clean install,
an update from the immediately preceding internal build, and uninstall. It must
verify both Main actions, support modules, the pinned curl version, 7-Zip's
release-local DLL resolution, the native extension API presence, and removal
of every package-owned file without removing runtime/user-created data.

### macOS internal install/native-preview gate

Separate internal passes are required on macOS x86_64 and macOS ARM64. Each
must verify installation of only its thin native binary, successful REAPER
extension loading, both native preview API functions, audible play/stop and
replacement with a real local audio file, both Main-action launches, use of
`/usr/bin/curl`, and clean uninstall. Signing, notarization, quarantine, and
Gatekeeper acceptance remain unresolved qualification work; build evidence
alone is not native runtime evidence.

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
