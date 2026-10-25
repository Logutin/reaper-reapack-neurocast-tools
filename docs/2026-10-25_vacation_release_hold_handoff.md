# Vacation release hold — 2026-10-25

> **Source snapshot warning:** this handoff records the owner's decision and
> repository state on 2026-10-25. Recheck current sources and authorization
> before future release work; historical qualification is not a new acceptance.

The owner postponed the new Neurocast Tools release and backend rollout during
vacation. Continue using published **0.1.9 / ElevenLabs v2.1.7** and the existing
production backend. No resume date or successor version has been assigned.
Resume only on explicit owner instruction, not automatically after vacation.

This repository was clean on `main` at
`4e0465c14d62fdb9672f56e45461784da0a2ed15`, matching the remote, before this
documentation pass. `index.xml`, `Neurocast_Tools/index.lua`, the manifest and
source lock all retain 0.1.9. Lua inputs are pinned to
`auphonic-mt` commit `1f5ca2a87e0fc36e5cd621f1c86934fa85fd6a15`.
The newer ElevenLabs v2.1.8 source in `auphonic-mt` is not this released payload.

During the hold, do not copy new runtime/manual payloads, bump versions,
assemble or qualify candidates, regenerate/promote the feed, publish releases,
or trigger backend deployment. Do not roll back source or reopen the frozen
direct-era release line. Existing native binaries and package contents remain
unchanged. Documentation edits do not authorize a repository About/index refresh.

The cross-repository continuation record is
`auphonic-mt/docs/2026-10-25_vacation_release_hold_handoff.md`; the backend has
its own dated handoff. Existing production identity/version was not probed in
this pass. After the owner resumes, recheck backend deployment/API evidence,
client live REAPER acceptance and the disposable-installation authorization
before any separately authorized package execution. Production rollout remains
Nikita-owned. The [release plan](release_plan_neurocast_backend.md) and
[0.1.9 release record](2026-10-09_package_implementation_0.1.9.md) retain their
historical evidence and scope limits.

This pass changes documentation only: no payload, source lock, index, binary,
runtime, installed client or production change. The owner subsequently authorized
committing and pushing these documentation changes; the release hold stays active.
