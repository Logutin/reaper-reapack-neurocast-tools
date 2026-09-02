# Neurocast Tools 0.1.2 minimal Windows qualification

> **Source snapshot warning:** This evidence records the deliberately narrow
> Windows x64 update/UI smoke performed on 2026-09-02. Re-check the current
> feed, source commits, receipts, and installed bytes before relying on it for
> a later release.

## Verdict

**PASS for the selected limited-internal Windows `0.1.1 -> 0.1.2` update/UI
smoke scope.**

This is not broad Windows, workflow, production, or public qualification.

## Environment

- Disposable installation: `C:\extra_Reapers\Reaper_Empty_01`
- REAPER: 7.79/x64
- ReaPack: 1.2.6
- Installed package: `Neurocast_Tools 0.1.2`
- Runtime source commit:
  `3b5cb2078afbaa5f7f4b2ca15054065faae98416`
- Distribution candidate commit:
  `7586b148dafb68a0b5231167bc17fd2586fe4fa0`
- Package minimum: REAPER 7.72+

## Owner-run live evidence

The owner supplied screenshots and explicitly confirmed all requested live
observations:

- ReaPack listed `Neurocast Tools 0.1.2` as installed and exposed historical
  versions `0.1.1` and `0.1.0-pre1`;
- the packaged MVSEP UI opened with title
  `MVSEP via Neurocast — script v0.2.0 / toolset v0.2.0`;
- the queue presented the selected-track time-selection requirement;
- Free and project-regions controls were absent;
- concurrency and `Add results to` controls were visible.

No remote job was submitted and no track/time-selection mutation was required
for this release gate.

## Headless readback

- ReaPack registry receipt: version `0.1.2`, 61 owned files, 13 Main actions.
- Installed `mvsep_tool.lua` SHA-256:
  `7C891DA8C2ECFB6F020C1DC8020A56285C88B4EE049F82EA084DA11006CE3D99`.
- Installed `modules-neurocast/mvsep_reaper.lua` SHA-256:
  `4E8A8298DF65D75B64B53B5742F83A21CBBE90A09D1EFAA750316648B38A3077`.
- Both hashes exactly matched the frozen distribution candidate.

The qualification helper's initial marker check falsely reported that the
candidate was absent. The cause was confined to the helper: it searched for
`function M.import_downloads(...)`, while the valid packaged adapter declares
`function MVSepReaper.import_downloads(...)`. The marker was corrected after
the installed receipt, file hashes, and owner-observed UI independently
confirmed the candidate.

## Evidence boundary

The gate did not repeat uninstall, clean install, authenticated workflow,
remote MVSEP processing, difficult-network, macOS, legacy migration, or
another-user/machine testing. Signing, notarization, tags, GitHub Releases, and
release CI remain out of scope.
