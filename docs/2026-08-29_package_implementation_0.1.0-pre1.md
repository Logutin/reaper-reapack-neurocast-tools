# Neurocast Tools 0.1.0-pre1 package implementation

> **Source snapshot warning:** This human-facing implementation record is true
> to the package inputs as of 2026-08-29. Treat it as explanatory support, not
> as the source of truth; re-check `release-manifest.yml`,
> `release-source-lock.yml`, and current source objects before future work.

## Assembly result

The repository now contains the assembled but unqualified source tree for the
single `Neurocast_Tools` metapackage. It contains 27 Lua payload files (six Main
actions and 21 support modules), three Windows utilities, three mutually
exclusive native-extension variants, four component notices, and one
metadata-only package descriptor. The manifest has 37 unique payload entries,
with applicable totals of 35 for `win64`, 29 for `darwin64`, and 29 for
`darwin-arm64`. `Neurocast_Tools/index.lua` declares exactly 93 explicit
platform-scoped `@provides` rows.

The package source layout is:

```text
Neurocast_Tools/
  index.lua
  elevenlabs_tool.lua
  elevenlabs_manager_tool.lua
  actions-neurocast/       # four fixed Main-action wrappers
  modules-neurocast/       # exact 21-module closure
  bin/win/                 # curl.exe, 7z.exe, 7z.dll
  native/                  # win64, darwin64, darwin-arm64 variants
  licenses/                # four component notice files
```

ReaPack installs the Lua, utility, and notice paths below `Neurocast_Tools/`.
The three architecture-specific sources use ReaPack's extension source type so
the selected `reaper_cyr_essentials.dll` or `.dylib` is installed under
`UserPlugins/` with its normal basename. ReaImGui remains external.

## Pinned inputs

All 27 Lua inputs are exact blobs from `auphonic-mt` commit
`238097e631e0cbf6e9c687dab09184649864fc6a`. The Windows inputs are local,
gitignored release inputs at `scr/bin/win/curl.exe`, `scr/bin/win/7z.exe`, and
`scr/bin/win/7z.dll`; they are hash-pinned and are not claimed to exist in that
commit. Copied runtime files must never be edited here: future runtime changes
must originate in `auphonic-mt` and require a new source pin.

The four notice texts are exact committed blobs at
`Slava-Testing/licenses/{curl-COPYING,zlib-LICENSE,7-Zip-License,Unicode-License}.license`
from `Logutin/slava-reaper-reapack-test-curl-jobs-imgui` commit
`dc1632c0d576a375002cc78c5df7d134764acb40`. That repository supplies only
these curated notice texts, never runtime, executables, native files, or
package metadata.

Native inputs are:

- `build/reaper_cyr_essentials-windows-x64/Release/reaper_cyr_essentials.dll`
  (run `30766075451`, source `ae71dd8260631bbd490f0206afbabdc8e447f135`);
- `build/reaper_cyr_essentials-macos-x86_64/reaper_cyr_essentials.dylib` and
  `build/reaper_cyr_essentials-macos-arm64/reaper_cyr_essentials.dylib`
  (run `30765082450`, source `3566e976853bcc5073acd5910c6df7ff6fd45ce9`).

Future native changes must originate in `reaper_cyr_essentials` and carry new
hashes and build evidence.

## Main actions

The six Main actions are the two full tools plus the four fixed files under
`actions-neurocast/` for fast STS, fast TTS, audio-tag insertion, and
audio-tag bracket removal. Every action is declared separately for `win64`,
`darwin64`, and `darwin-arm64`.

## Local validation procedure

Validation parses both YAML records, derives role and platform totals from the
manifest, checks the actual package file set, compares every Lua and notice
byte sequence with its pinned Git blob, checks every binary/native size and
SHA-256, validates PE and thin Mach-O architectures, runs the package copies of
curl and 7-Zip, checks wrapper and module-namespace invariants, and audits all
93 `@provides` rows. The final ReaPack check uses `reapack-index 1.2.6` with
`--no-config --check --strict --warnings`, an external temporary index, and the
same eight explicit ignore paths recorded in `.reapack-index.conf`.

`reapack-index 1.2.6` recognizes `.txt` files below a category directory as
MIDI-note-name package candidates. The four component notices are not
independent packages, so their exact paths are excluded from standalone package
discovery while remaining committed, byte-validated, platform-scoped explicit
metapackage payload. The other four ignores isolate the two copied full-tool
Lua files and the copied action/module directories from standalone discovery.
The expected result is one checked metapackage with zero failures and zero
warnings.

## Qualification boundary

The source tree remains unqualified and unpublished. Project licensing and a
possible consolidated notice remain unresolved and are deliberately not
payload entries. GitHub Actions are postponed. No repository `index.xml`, tag,
release, live REAPER qualification, signing, notarization, or installation has
been created or performed at this milestone.
