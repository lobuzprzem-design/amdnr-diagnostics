# AMD NR diagnostics

**English** | [Polski](README.pl.md)

A portable, offline diagnostic collector for Windows PowerShell 5.1. It collects bounded copies of selected AMD NR / OptiScaler logs and INI files, basic Windows/GPU driver information, and version/hash metadata for known runtime DLL names.

This is an independent troubleshooting tool. It does not install or modify a mod, repair a game, load a runtime DLL, or prove that neural rendering is working. No third-party binaries or private diagnostic reports are included in this repository.

## Run

Keep `Collect-AmdNrDiagnostics.ps1` and `Start-Diagnostics.cmd` in the same directory. Run `Start-Diagnostics.cmd` and enter the absolute local game directory, up to eight optional extra log directories, and a separate output directory. Do not quote paths entered at the interactive prompts. Press Enter to omit the game directory or finish the extra-directory list.

The v1.0.0 console prompts and some summary labels are in Polish. Both documentation languages are available; the program itself does not yet have a language selector. The interactive prompts mean:

| Console prompt | Meaning |
| --- | --- |
| `Pelna lokalna sciezka katalogu gry (Enter = brak)` | Absolute local game-directory path; Enter means no game source. |
| `Dodatkowy katalog logow …/8 (Enter = koniec)` | Optional additional log directory; Enter finishes the list. |
| `Pelna lokalna sciezka katalogu na raporty (poza zrodlami)` | Absolute output-directory path, separate from all source directories. |

Alternatively, supply the named parameters in Windows PowerShell and skip the interactive prompts:

```powershell
& '.\Collect-AmdNrDiagnostics.ps1' -GamePath 'D:\Games\Forza Horizon 6\Content' -OutputDirectory 'D:\AMDNR-Reports'
$LASTEXITCODE
```

The paths above are examples. The collector does not search for a game installation. Omitting the game directory still collects available system/HIP information and produces a partial report.

To include additional log directories:

```powershell
& '.\Collect-AmdNrDiagnostics.ps1' `
  -GamePath 'D:\Games\Forza Horizon 6\Content' `
  -AdditionalLogPaths @('D:\Logs\OptiScaler', 'D:\Logs\Anywhere') `
  -OutputDirectory 'D:\AMDNR-Reports'
```

All paths must be absolute paths on local drives. The output directory must neither contain a source directory nor be inside one. UNC paths, device paths, non-filesystem providers, drive roots used as sources, and paths containing reparse points are rejected. Junctions and symbolic links encountered during collection are skipped. Do not point the collector at entire drives or another person's report archives.

Reports can be collected while the game is running. A file that changes during collection is marked accordingly; its read is bounded by the size observed when reading begins.

The launcher calls the system `powershell.exe -NoLogo -NoProfile -File … -Interactive`. It does not require administrator rights, change execution policy, use a bypass flag, install dependencies, or access the network. Existing Windows script and organization restrictions still apply. If they prevent execution, PowerShell reports the reason and no collector report is created; the launcher exit code in that case comes from PowerShell.

## Output and limits

Each run creates a unique report directory and a ZIP beside it. The directory contains `summary.txt`, `manifest.json`, `issues.csv`, and numbered UTF-8 copies of selected texts. Exit codes: `0` complete, `2` partial, `1` failed.

Text reads are limited to 2 MiB per file and 20 MiB total, with separate output limits. Oversized logs retain their tail. Enumeration is limited to two subdirectory levels, 1,000 text candidates and 10,000 entries; caches, saves, models and reparse points are excluded. Binary files are not copied or executed; hashing is bounded to 128 MiB per file and 256 MiB total. HIP probing checks only six named environment values and a documented HIP 7.2 location.

The collector masks common profile paths, the current username, email addresses and common secret-key values. **Redaction is best-effort: inspect every report before sharing it.** IP addresses, machine names, unusual credentials and other identifying content can remain. The collector never uploads a report.

See [validation notes](TESTING.md) for the tested scope and its limitations. The detailed English guide continues below; a [Polish guide](README.pl.md) is also available.

## Exactly what is collected

- **Text files:** all `*.log` files, `OptiScaler.ini`, and `dlssnr_on_amd.ini`, matched case-insensitively in the source root and up to two subdirectory levels. Source identifiers remain `game`, `additional-01` through `additional-08`. A duplicate file is read once and retains all source associations.
- **Excluded directories:** `save`, `saves`, `savegame`, `savegames`, `cache`, `caches`, `shadercache`, `gpucache`, `binaries`, `models`, and `weights`. Each exclusion is recorded. Windows Event Logs, WER reports, minidumps, save games, and unrelated locations are not scanned.
- **Enumeration and text budgets:** at most 1,000 text candidates and 10,000 visited entries; 2 MiB per text file and 20 MiB total. Input-byte and written UTF-8 output budgets are separate. If enumeration stops at a limit, the report does not claim that the remaining files were counted.
- **Bounded reads:** small texts are read in full. Oversized texts, including INI files, retain their tail; a partial first line is dropped. Up to four initial bytes are used for BOM detection and count toward the read budget. Trimming after redaction also retains a suffix starting at a line boundary. A file is skipped with an explicit reason if no line fits.
- **Encoding:** UTF-8, UTF-16, and UTF-32 BOMs are checked longest first. Files without a BOM are attempted as UTF-8, with the local Windows code page as a fallback for invalid input. The fallback is recorded in the manifest. Written copies are UTF-8 without a BOM and use technical names such as `files/game/0001.log`.
- **Binary metadata only:** a fixed list of EXE/DLL candidates in the game root is checked. It is not a claim that every installation should contain those files. An absent optional DLL alone is not evidence of a fault. The exact list is below.
- **HIP metadata:** only `HIP_PATH` and `HIP_PATH_7_2` at Process, User, and Machine scope are inspected, for six environment values in total. Local directories are checked for `bin\amdhip64_7.dll`, with an additional check of `C:\Program Files\AMD\ROCm\7.2\bin\amdhip64_7.dll`. The same file is hashed once while preserving all references.
- **Metadata fields:** presence, size, modification time in UTC, FileVersion/ProductVersion, and SHA256 or the reason no hash is available. Hashing is capped at 128 MiB per file and 256 MiB total. A changing file is marked `unstable`. DLLs are never loaded or copied; no EXE files, DLLs, or model weights are included in the report.
- **System fields:** only Caption/Version/BuildNumber from `Win32_OperatingSystem` and Name/DriverVersion from `Win32_VideoController`. Two selective CIM queries use a five-second operation timeout. Serial numbers and full system dumps are not collected.

Binary metadata candidates in the game root:

```text
ForzaHorizon6.exe       OptiScaler.dll          dxgi.dll
d3d11.dll              d3d12.dll               version.dll
winmm.dll              dbghelp.dll             nvngx.dll
nvngx_dlss.dll         nvngx_dlssd.dll         amd_presr.dll
amd_bridge.dll         dlssnr_on_amd.dll       lmxxf_backend.dll
amdhip64.dll           amdhip64_7.dll          winhttp.dll
wininet.dll            nvngx_dlssnr.dll        dlssnr_amd_pass1.dll
dlssnr_amd_pass2.dll    dlssnr_amd_pass3.dll     LmxxfNrRuntime.dll
```

## Interpreting a report

Each run creates a new `amdnr-<UTC>-<GUID>` directory and a ZIP of the same name beside it. Existing reports are neither overwritten nor automatically deleted. The ZIP receives its final name only after the archive has been closed. If ZIP creation fails, the report directory remains and records the issue.

| Status / process exit code | Meaning |
| --- | --- |
| `complete` / `0` | Collection finished within its defined, bounded scope without issues. Expected exclusions and absent optional DLLs may still appear. |
| `partial` / `2` | A report was created, but collection encountered a missing source, access/CIM/ZIP failure, file changes, encoding fallback, truncation, or a limit. |
| `failed` / `1` | Invalid paths/parameters or another error prevented report creation. Do not assume a valid ZIP exists; inspect the error. |

`summary.txt` gives the overview; `issues.csv` records issues and exclusions. `manifest.json` records sources, limits, metadata, counters, statuses, and the written copies. `readRanges` and `contentRange` are **[start byte, exclusive end byte)** offsets from the start of the source file. `contentRange` describes the input to redaction, not a byte-for-byte mapping to the saved copy. `rawBytesRead` and `outputBytes` are separate counts; a copy's SHA256 applies only to that redacted copy. `selection`, `truncationReason`, `outputSuffixTrimmed`, and `changedDuringCollection` explain collection limitations.

The presence, version, or hash of a DLL does not prove it can load, is compatible with the driver, or has performed NR processing. A missing game source still allows other available data to be collected, with a `partial` result. The collector does not start games, stop processes/downloads, or change HIP, drivers, the registry, Game Bar, ACLs, or other settings.

## Privacy and sharing

Raw text is held only in memory. Written text fields and copies use the same redaction function for home/profile paths, the current username, email addresses, and common credential keys: `token`, `access_token`, `refresh_token`, `password`, `passwd`, `authorization`, `api_key`, `apikey`, and `secret`. Typical INI/JSON forms, Authorization headers, and URL parameters are covered. Redaction can also remove harmless text; it is neither a parser for every format nor a guarantee of complete anonymization.

**Review every file before sharing a report.** Unusual secrets, other usernames without a surrounding path, machine names, IP addresses, and other identifying content can remain. The collector does not transmit reports or open web pages. After manually editing a report, its original ZIP and recorded copy hashes no longer describe those edits: do not accidentally share the old ZIP.

## Removal

The collector needs no installation and changes no game configuration. To remove it, delete your local copies of `Collect-AmdNrDiagnostics.ps1` and `Start-Diagnostics.cmd` when you no longer need them. Documentation can be removed separately. Keep or delete your report directories and ZIPs separately; the collector does not delete them for you.

## Upstream projects

- [TheAutomatic/dlss-5-amd-project](https://github.com/TheAutomatic/dlss-5-amd-project)
- [3zwr1/AMD-NR---OptiScaler](https://github.com/3zwr1/AMD-NR---OptiScaler)
- [danielblnc/DLSS-NR-on-AMD](https://github.com/danielblnc/DLSS-NR-on-AMD)

These are references, not downloaded dependencies. This collector is not an official release of those projects.
