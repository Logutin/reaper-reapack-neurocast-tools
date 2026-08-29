# Runtime inventory for Neurocast Tools 0.1.0-pre1

> Source snapshot: 2026-08-29. Lua inventory is pinned to `auphonic-mt` commit
> `238097e631e0cbf6e9c687dab09184649864fc6a`. The named local binaries and
> pinned notice/native inputs were reverified during assembly. This is the
> immutable source record for the package now published for limited internal
> testing; Windows x64 is qualified, macOS remains unqualified, and this is not
> a current backend-contract review.

## Inventory result

The exact Lua inventory contains **27 files**: six Main actions and 21 support
modules. The two full tool Main actions are module-loading entrypoints. The four
fixed maintained wrapper Main actions are dependency-free action roots. No file
in this inventory uses `dofile(...)` or `loadfile(...)`, and no runtime source
is loaded through a module-directory glob.

The assembled payload also contains three Windows command-line binary inputs,
three mutually exclusive native-extension variants, and four applicable
third-party notice inputs. That is **37 unique assembled payload entries**: six
Main actions, 25 support files (the 21 Lua modules plus four notice files),
three binaries, and three mutually exclusive extension variants.

The manifest-derived applicable totals are:

| Platform | Applicable entries | Main actions | Support files | Windows binaries | Extension |
| --- | ---: | ---: | ---: | ---: | ---: |
| `win64` | 35 | 6 | 25 | 3 | 1 |
| `darwin64` | 29 | 6 | 22 | 0 | 1 |
| `darwin-arm64` | 29 | 6 | 22 | 0 | 1 |

The macOS support count is the 21 Lua support modules plus the platform-shared
Unicode notice. The three Windows-specific notices bring the Windows support
count to 25.

## Fixed maintained wrapper action roots

The approved source contains these four fixed, maintained one-line actions.
Each calls `reaper.SetExtState` in section `nc_dDeSm_Acr33`, writes a fresh
`reaper.time_precise()` timestamp without persistence, and has no module
dependencies:

| Source | Exact ExtState action ID |
| --- | --- |
| `scr/actions-neurocast/action_neurocast_tools_fast_sts_action.lua` | `fast_STS_flow_action_for_hotkey_trigger` |
| `scr/actions-neurocast/action_neurocast_tools_fast_tts_action.lua` | `fast_TTS_flow_action_for_hotkey_trigger` |
| `scr/actions-neurocast/action_neurocast_tools_audio_tags_insert_action.lua` | `audio_tags_insert_selected_notes_action_for_hotkey_trigger` |
| `scr/actions-neurocast/action_neurocast_tools_audio_tags_remove_brackets_action.lua` | `audio_tags_remove_brackets_selected_notes_action_for_hotkey_trigger` |

They remain in `actions-neurocast/` because the main tool resolves those exact
fixed relative paths. They are copied byte-for-byte as Main actions, not
support files.

## Literal imports of the two full tool entrypoints

`scr/elevenlabs_tool.lua` uses `pcall(require, ...)` for these literal project
modules:

```text
modules-neurocast.elevenlabs_tool_languages
modules-neurocast.json
modules-neurocast.Util
modules-neurocast.Files
modules-neurocast.elevenlabs_voice_catalog
modules-neurocast.elevenlabs_shared_voices_api
modules-neurocast.elevenlabs_voice_library_state
modules-neurocast.elevenlabs_voice_library_taxonomy
modules-neurocast.elevenlabs_voice_library_ui_state
modules-neurocast.elevenlabs_voice_preview
modules-neurocast.elevenlabs_api_via_neurocast
modules-neurocast.Curl
modules-neurocast.neurocast_auth
modules-neurocast.Jobs
modules-neurocast.Cleanup
modules-neurocast.prompts
modules-neurocast.Telemetry
```

It separately calls `require("imgui")("0.10")` through a protected function
after switching `package.path` to ReaImGui's built-in Lua path.

`scr/elevenlabs_manager_tool.lua` passes these literal names to its local
`require_module(name)` helper, which calls `pcall(require, name)` and aborts on
failure:

```text
modules-neurocast.Util
modules-neurocast.Files
modules-neurocast.Curl
modules-neurocast.Jobs
modules-neurocast.neurocast_auth
modules-neurocast.reaper_manager_elevenlabs_api
modules-neurocast.Telemetry
modules-neurocast.Utf8Tools
```

It also calls `require("imgui")("0.10")` through a protected function.

## Nested module dependencies

All literal module-to-module edges in the closure are:

| Module | Literal dependencies |
| --- | --- |
| `Cleanup.lua` | `modules-neurocast.Util`, `modules-neurocast.Files` |
| `Curl.lua` | `modules-neurocast.Util`, `modules-neurocast.Files`, `modules-neurocast.Cleanup`, `modules-neurocast.json` |
| `elevenlabs_api_via_neurocast.lua` | `modules-neurocast.Util` via `pcall(require, ...)`, hard-required after validation |
| `elevenlabs_shared_voices_api.lua` | `modules-neurocast.json` |
| `elevenlabs_voice_catalog.lua` | `modules-neurocast.elevenlabs_voice_library_taxonomy` |
| `Files.lua` | `modules-neurocast.Util` |
| `Jobs.lua` | `modules-neurocast.Util`, `modules-neurocast.Curl`, `modules-neurocast.Cleanup` |
| `neurocast_auth.lua` | `modules-neurocast.json`, `modules-neurocast.base64_encode_decode`, `modules-neurocast.Curl`, `modules-neurocast.Util`; each uses `pcall(require, ...)` but is hard-required after validation |
| `reaper_manager_elevenlabs_api.lua` | `modules-neurocast.Util`, `modules-neurocast.json` |
| `Telemetry.lua` | `modules-neurocast.json`, `modules-neurocast.Util`, `modules-neurocast.Files`, `modules-neurocast.Curl` |
| `Utf8Tools.lua` | `modules-neurocast.Utf8SimpleLowerData` |
| `Util.lua` | lazy `pcall(require, "modules-neurocast.json")` for table stringification; optional at that call site |

The remaining closure modules have no literal project-module imports:
`base64_encode_decode.lua`, `elevenlabs_tool_languages.lua`,
`elevenlabs_voice_library_state.lua`,
`elevenlabs_voice_library_taxonomy.lua`,
`elevenlabs_voice_library_ui_state.lua`, `elevenlabs_voice_preview.lua`,
`json.lua`, `prompts.lua`, and `Utf8SimpleLowerData.lua`.

## Included file map

`all` below means `win64`, `darwin64`, and `darwin-arm64`. Destinations are
logical paths relative to the REAPER resource/package layout, not local-machine
paths.

| Source or logical input | Intended destination | Role | Platform | Purpose |
| --- | --- | --- | --- | --- |
| `auphonic-mt:scr/elevenlabs_tool.lua` | `Neurocast_Tools/elevenlabs_tool.lua` | Main action | all | Main Studio Neurocast ElevenLabs workflow |
| `auphonic-mt:scr/elevenlabs_manager_tool.lua` | `Neurocast_Tools/elevenlabs_manager_tool.lua` | Main action | all | Studio Neurocast user/account assignment manager |
| `auphonic-mt:scr/actions-neurocast/action_neurocast_tools_fast_sts_action.lua` | `Neurocast_Tools/actions-neurocast/action_neurocast_tools_fast_sts_action.lua` | Main action | all | Fixed ExtState trigger for fast speech-to-speech |
| `auphonic-mt:scr/actions-neurocast/action_neurocast_tools_fast_tts_action.lua` | `Neurocast_Tools/actions-neurocast/action_neurocast_tools_fast_tts_action.lua` | Main action | all | Fixed ExtState trigger for fast text-to-speech |
| `auphonic-mt:scr/actions-neurocast/action_neurocast_tools_audio_tags_insert_action.lua` | `Neurocast_Tools/actions-neurocast/action_neurocast_tools_audio_tags_insert_action.lua` | Main action | all | Fixed ExtState trigger for selected-note audio-tag insertion |
| `auphonic-mt:scr/actions-neurocast/action_neurocast_tools_audio_tags_remove_brackets_action.lua` | `Neurocast_Tools/actions-neurocast/action_neurocast_tools_audio_tags_remove_brackets_action.lua` | Main action | all | Fixed ExtState trigger for selected-note bracket removal |
| `auphonic-mt:scr/modules-neurocast/base64_encode_decode.lua` | `Neurocast_Tools/modules-neurocast/base64_encode_decode.lua` | support file | all | JWT URL-safe base64 decoding for auth |
| `auphonic-mt:scr/modules-neurocast/Cleanup.lua` | `Neurocast_Tools/modules-neurocast/Cleanup.lua` | support file | all | Deferred cleanup queue |
| `auphonic-mt:scr/modules-neurocast/Curl.lua` | `Neurocast_Tools/modules-neurocast/Curl.lua` | support file | all | Asynchronous curl transport |
| `auphonic-mt:scr/modules-neurocast/elevenlabs_api_via_neurocast.lua` | `Neurocast_Tools/modules-neurocast/elevenlabs_api_via_neurocast.lua` | support file | all | Studio backend request builders |
| `auphonic-mt:scr/modules-neurocast/elevenlabs_shared_voices_api.lua` | `Neurocast_Tools/modules-neurocast/elevenlabs_shared_voices_api.lua` | support file | all | Voice Library query/response normalization |
| `auphonic-mt:scr/modules-neurocast/elevenlabs_tool_languages.lua` | `Neurocast_Tools/modules-neurocast/elevenlabs_tool_languages.lua` | support file | all | Generated runtime localization table |
| `auphonic-mt:scr/modules-neurocast/elevenlabs_voice_catalog.lua` | `Neurocast_Tools/modules-neurocast/elevenlabs_voice_catalog.lua` | support file | all | Account voice catalog normalization/filtering |
| `auphonic-mt:scr/modules-neurocast/elevenlabs_voice_library_state.lua` | `Neurocast_Tools/modules-neurocast/elevenlabs_voice_library_state.lua` | support file | all | Voice Library page/cache state |
| `auphonic-mt:scr/modules-neurocast/elevenlabs_voice_library_taxonomy.lua` | `Neurocast_Tools/modules-neurocast/elevenlabs_voice_library_taxonomy.lua` | support file | all | Voice Library filter taxonomy |
| `auphonic-mt:scr/modules-neurocast/elevenlabs_voice_library_ui_state.lua` | `Neurocast_Tools/modules-neurocast/elevenlabs_voice_library_ui_state.lua` | support file | all | Voice Library UI preference/state helpers |
| `auphonic-mt:scr/modules-neurocast/elevenlabs_voice_preview.lua` | `Neurocast_Tools/modules-neurocast/elevenlabs_voice_preview.lua` | support file | all | Download/cache/native-preview controller |
| `auphonic-mt:scr/modules-neurocast/Files.lua` | `Neurocast_Tools/modules-neurocast/Files.lua` | support file | all | Safe file/path/project-media operations |
| `auphonic-mt:scr/modules-neurocast/Jobs.lua` | `Neurocast_Tools/modules-neurocast/Jobs.lua` | support file | all | Job scheduling, progress, and retry state |
| `auphonic-mt:scr/modules-neurocast/json.lua` | `Neurocast_Tools/modules-neurocast/json.lua` | support file | all | JSON encode/decode |
| `auphonic-mt:scr/modules-neurocast/neurocast_auth.lua` | `Neurocast_Tools/modules-neurocast/neurocast_auth.lua` | support file | all | Studio login, refresh, JWT timing, and persistence |
| `auphonic-mt:scr/modules-neurocast/prompts.lua` | `Neurocast_Tools/modules-neurocast/prompts.lua` | support file | all | Maintained OpenAI rewrite prompt text |
| `auphonic-mt:scr/modules-neurocast/reaper_manager_elevenlabs_api.lua` | `Neurocast_Tools/modules-neurocast/reaper_manager_elevenlabs_api.lua` | support file | all | Manager route/request/response helpers |
| `auphonic-mt:scr/modules-neurocast/Telemetry.lua` | `Neurocast_Tools/modules-neurocast/Telemetry.lua` | support file | all | Identity validation, event queues, and flushes |
| `auphonic-mt:scr/modules-neurocast/Utf8SimpleLowerData.lua` | `Neurocast_Tools/modules-neurocast/Utf8SimpleLowerData.lua` | support file | all | Generated Unicode simple-lowercase data |
| `auphonic-mt:scr/modules-neurocast/Utf8Tools.lua` | `Neurocast_Tools/modules-neurocast/Utf8Tools.lua` | support file | all | UTF-8 case-insensitive manager sorting/search helpers |
| `auphonic-mt:scr/modules-neurocast/Util.lua` | `Neurocast_Tools/modules-neurocast/Util.lua` | support file | all | Shared platform, path, ExtState, and diagnostics utilities |
| `windows-curl-8.13.0-x64` | `Neurocast_Tools/bin/win/curl.exe` | binary | `win64` | Pinned Windows curl transport |
| `windows-7zip-26.00-x64-console` | `Neurocast_Tools/bin/win/7z.exe` | binary | `win64` | Deliberate shared archive-tool input for upcoming parity |
| `windows-7zip-26.00-x64-library` | `Neurocast_Tools/bin/win/7z.dll` | binary | `win64` | Required matching runtime library for `7z.exe` |
| `reaper-cyr-essentials-windows-x64-build-30766075451` | `UserPlugins/reaper_cyr_essentials.dll` | extension | `win64` | Native preview API |
| `reaper-cyr-essentials-macos-x86_64-build-30765082450` | `UserPlugins/reaper_cyr_essentials.dylib` | extension | `darwin64` | Thin x86_64 native preview API |
| `reaper-cyr-essentials-macos-arm64-build-30765082450` | `UserPlugins/reaper_cyr_essentials.dylib` | extension | `darwin-arm64` | Thin ARM64 native preview API |
| `reapack-reference:Slava-Testing/licenses/curl-COPYING.license` | `Neurocast_Tools/licenses/curl-COPYING.txt` | support file | `win64` | curl license notice |
| `reapack-reference:Slava-Testing/licenses/zlib-LICENSE.license` | `Neurocast_Tools/licenses/zlib-LICENSE.txt` | support file | `win64` | Notice for curl's reported zlib component |
| `reapack-reference:Slava-Testing/licenses/7-Zip-License.license` | `Neurocast_Tools/licenses/7-Zip-License.txt` | support file | `win64` | 7-Zip LGPL/BSD/unRAR notices |
| `reapack-reference:Slava-Testing/licenses/Unicode-License.license` | `Neurocast_Tools/licenses/Unicode-License.txt` | support file | all | Unicode data license for `Utf8SimpleLowerData.lua` |

## Optional and external runtime inputs

- `modules-neurocast.elevenlabs_tool_languages` is the only optional
  entrypoint project import. Failure keeps the source-text English UI. It is
  still included so the supported generated localization is present.
- `Util.lua` treats its lazy JSON import as optional only for diagnostic table
  stringification. JSON is independently hard-required elsewhere in both
  full-tool entrypoint closures.
- ReaImGui's built-in `imgui` Lua module is externally required. Both
  full-tool entrypoints abort cleanly if it cannot load; ReaImGui is not
  shipped here.
- On Windows, both full-tool entrypoints prefer the bundled curl only when its
  version output contains `curl 8.13.0 (Windows)` and otherwise fall back to
  `curl` on `PATH`. On macOS they use `/usr/bin/curl`.
- `reaper_cyr_essentials` is optional for general startup but required for the
  unified native preview channel. The package deliberately plans to install
  the matching variant so preview is self-contained after qualification.
- `CirilicaTools_telemetry_identity.json` is a required per-installation file
  in the REAPER resource-path root. It contains installation identity material
  and must be provisioned separately, never shipped in the public package.

## Runtime file reads and generated artifacts

There are no runtime `dofile` or `loadfile` references. REAPER executes the six
Main actions directly; the two full-tool actions load their 21-module support
closure through Lua `require`, while the four fixed wrapper actions have no
module dependencies.

Runtime reads/writes that are not maintained package inputs include:

- REAPER's `reaper-kb.ini`, read to check whether each fixed maintained wrapper
  action is already registered before the existing file is registered through
  `AddRemoveReaScript`;
- `CirilicaTools_telemetry_identity.json`, read from the REAPER resource root;
- `CirilicaTools_telemetry_settings.json`, a local telemetry-policy/settings
  file;
- `CirilicaTools_telemetry/`, containing runtime JSONL queues, diagnostics,
  failed-event retention, and temporary curl payload/header/meta/output files;
- `Neurocast_Tools_tmp/` below the effective project recording path for curl
  job state, upload staging, and preview caches such as
  `voice_library_previews/*.download.part`;
- network result audio written directly to the effective project recording
  path before REAPER import;
- REAPER ExtState values for UI state and obfuscated Studio refresh tokens;
- fixed maintained wrapper action timestamps written to REAPER ExtState under
  the four exact action IDs listed above.

Former Neurocast-generated files matching `Neurocast_Tools__*.lua` are legacy
migration artifacts, not maintained package inputs. Existing tester installs
must inventory those files and their registrations, identify only the four
legacy Neurocast actions bound to the established IDs, record hotkeys,
deliberately unregister and remove the obsolete Neurocast registrations and
files, install or update the package, and then verify exactly-once registration,
hotkeys, and exact trigger behavior for each fixed package-owned wrapper. The
two full tool actions must also be verified. The separate Direct API
runtime-generated wrapper workflow and its files must be preserved. Current
runtime code must not automatically delete, rewrite, migrate, or synthesize
these legacy files.

Legacy Neurocast-generated wrappers, Direct API runtime-generated wrappers,
telemetry/runtime files, downloads, partials, caches, logs, and ExtState data
must never be copied back into the maintained package inventory. This exclusion
does not apply to the four fixed maintained wrapper Main actions under
`scr/actions-neurocast/action_neurocast_tools_*.lua`.

## Inspected binary candidates

The selected Windows inputs were copied only from the local `auphonic-mt`
release-input paths under `scr/bin/win`. The ReaPack test repository was not a
binary source. These ignored local files are path-, size-, and hash-pinned and
are not claimed to be contained in the tracked Lua commit.

| Logical input | Observed version / format | Architecture | Size (bytes) | SHA-256 |
| --- | --- | --- | ---: | --- |
| `windows-curl-8.13.0-x64` | curl/libcurl 8.13.0, Schannel, zlib 1.3.1, WinIDN; PE machine `0x8664` | x86_64 | 711,736 | `3345339164cf384eff527b6c3160fea8d849a4231ec6ca80513e3a739e505168` |
| `windows-7zip-26.00-x64-console` | 7-Zip 26.00; PE machine `0x8664` | x86_64 | 575,488 | `4a41aa37786c7eae7451e81c2c97458d5d1ae5a3a8154637a0d5f77adc05e619` |
| `windows-7zip-26.00-x64-library` | 7-Zip 26.00; PE machine `0x8664` | x86_64 | 1,908,736 | `bbd705e3b58ca7677c1e9e67473f166a6712da034dcb567d571fbb67507a443f` |

The native files below are the actual inspected and copied files under the
local native repository's `build` outputs. They were not rebuilt, signed,
notarized, or modified. The named evidence records prove build/binary checks
only, not REAPER runtime behavior on macOS.

The selected macOS jobs in the cited shared workflow run succeeded, although
the aggregate result of that workflow run is failure. This planning snapshot
preserves those selected job artifacts and does not reinterpret the aggregate
run as successful.

| Logical input | Actual filename | Format / architecture | Size (bytes) | SHA-256 | Recorded build evidence |
| --- | --- | --- | ---: | --- | --- |
| `reaper-cyr-essentials-windows-x64-build-30766075451` | `reaper_cyr_essentials.dll` | PE x86_64 | 14,336 | `1df283154fa3183c4437132b621ca9bda908f4a52dbca9051bee5c07410c1527` | run `30766075451`, source `ae71dd8260631bbd490f0206afbabdc8e447f135` |
| `reaper-cyr-essentials-macos-x86_64-build-30765082450` | `reaper_cyr_essentials.dylib` | thin Mach-O x86_64 | 17,856 | `adac7be285d1bb7ee30fcc85f2241d8f797eb152165a9d1d20cf66810e0eb9fa` | run `30765082450`, source `3566e976853bcc5073acd5910c6df7ff6fd45ce9` |
| `reaper-cyr-essentials-macos-arm64-build-30765082450` | `reaper_cyr_essentials.dylib` | thin Mach-O ARM64 | 51,064 | `541c511053b19685f81aa3470a82891c728a8d1ee7597800d51382fb3d9ee72d` | run `30765082450`, source `3566e976853bcc5073acd5910c6df7ff6fd45ce9` |

An additional local Windows build at `build/reaper_cyr_essentials.dll` had the
same size but a different SHA-256
(`01b4657b94e6a704b104275151a7a5d6571c25ff9508c4aab3e856ff10fa89db`).
It is not selected because the architecture-labelled candidate matches the
committed successful build-evidence record.

## Explicit exclusions

The package excludes all Direct API `*_dev_main.lua` entrypoints and the entire
`scr/modules/` tree; unused `modules-neurocast` files; every test and test
fixture; FakeReaper; the Network Fault Lab; repository/development/manual
documentation; the manual localization source
`elevenlabs_tool_languages_manual_edit.lua`; Python helpers; local release
outputs other than the three selected logical Windows candidates; source maps;
build systems; caches; logs; telemetry identities; credentials, tokens, `.env`
files, cookies, private notes; legacy Neurocast-generated
`Neurocast_Tools__*.lua` wrappers; Direct API runtime-generated wrappers;
generated runtime JSON/JSONL/header/meta/body/partial/audio files; package
assembly outputs; and all Linux payloads. The four fixed maintained wrapper
Main actions under `scr/actions-neurocast/action_neurocast_tools_*.lua` are
explicitly included and are not covered by these exclusions.

The sole approved use of
`Logutin/slava-reaper-reapack-test-curl-jobs-imgui` is the four component notice
blobs under `Slava-Testing/licenses/` at commit
`dc1632c0d576a375002cc78c5df7d134764acb40`. No executable, Lua source, native
binary, package metadata, index, or other payload came from that repository.

## Genuinely unresolved items

- The Windows x64 extension-typed source and normal `UserPlugins` destination
  passed both local qualification and a clean install from the real GitHub
  feed. Equivalent macOS clean-install and native-loading behavior remains to
  be proven.
- macOS binaries are unsigned and unnotarized, and no macOS REAPER runtime
  record exists. Signing/notarization/quarantine policy and native preview must
  be resolved by the macOS qualification gate.
- Prior-version update, legacy-install migration, and another-user or
  another-machine testing remain unqualified or pending.
- Project licensing and any consolidated third-party-notices document remain
  unresolved. The four approved component notices are present; no project
  license or consolidated-notices payload is added in this milestone.
