# AMD NR diagnostics

A portable, offline diagnostic collector for Windows PowerShell 5.1. It collects bounded copies of selected AMD NR / OptiScaler logs and INI files, basic Windows/GPU driver information, and version/hash metadata for known runtime DLL names.

This is an independent troubleshooting tool. It does not install or modify a mod, repair a game, load a runtime DLL, or prove that neural rendering is working. No third-party binaries or private diagnostic reports are included in this repository.

## Run

Keep `Collect-AmdNrDiagnostics.ps1` and `Start-Diagnostics.cmd` in the same directory. Run `Start-Diagnostics.cmd` and enter the absolute local game directory, up to eight optional extra log directories, and a separate output directory. Alternatively, from Windows PowerShell:

```powershell
& '.\Collect-AmdNrDiagnostics.ps1' -GamePath 'D:\Games\Forza Horizon 6\Content' -OutputDirectory 'D:\AMDNR-Reports'
$LASTEXITCODE
```

The paths above are examples. The collector does not search for a game installation. Omitting the game directory still collects available system/HIP information and produces a partial report.

It does not require administrator rights, change execution policy, use a bypass flag, install dependencies, or access the network. Existing Windows script restrictions still apply.

## Output and limits

Each run creates a unique report directory and a ZIP beside it. The directory contains `summary.txt`, `manifest.json`, `issues.csv`, and numbered UTF-8 copies of selected texts. Exit codes: `0` complete, `2` partial, `1` failed.

Text reads are limited to 2 MiB per file and 20 MiB total, with separate output limits. Oversized logs retain their tail. Enumeration is limited to two subdirectory levels, 1,000 text candidates and 10,000 entries; caches, saves, models and reparse points are excluded. Binary files are not copied or executed; hashing is bounded to 128 MiB per file and 256 MiB total. HIP probing checks only six named environment values and a documented HIP 7.2 location.

The collector masks common profile paths, the current username, email addresses and common secret-key values. **Redaction is best-effort: inspect every report before sharing it.** IP addresses, machine names, unusual credentials and other identifying content can remain. The collector never uploads a report.

Read the [full Polish operating guide](README.pl.md) for exact file names, fields, limits, failure behavior and rollback. See [validation notes](TESTING.md) for the tested scope and its limitations.

## Upstream projects

- [TheAutomatic/dlss-5-amd-project](https://github.com/TheAutomatic/dlss-5-amd-project)
- [3zwr1/AMD-NR---OptiScaler](https://github.com/3zwr1/AMD-NR---OptiScaler)
- [danielblnc/DLSS-NR-on-AMD](https://github.com/danielblnc/DLSS-NR-on-AMD)

These are references, not downloaded dependencies. This collector is not an official release of those projects.
