# Lokalna diagnostyka AMD NR — v1.0.0

[English](README.md) | **Polski**

Przenośny zbieracz raportów dla Windows PowerShell 5.1. Działa offline, na żądanie. Czyta wskazane logi i informacje o systemie oraz bibliotekach, maskuje typowe dane prywatne i tworzy katalog raportu wraz z ZIP. Nie naprawia gry i nie potwierdza, że NR wykonało się poprawnie.

## Uruchomienie

Zachowaj `Collect-AmdNrDiagnostics.ps1` i `Start-Diagnostics.cmd` w jednym katalogu. Uruchom `Start-Diagnostics.cmd` i podaj w konsoli pełne lokalne ścieżki:

1. Katalog główny gry, w którym znajdują się EXE/DLL i logi. Enter oznacza brak źródła i raport `partial`.
2. Opcjonalnie do ośmiu dodatkowych katalogów logów, po jednym na pytanie. Enter kończy listę.
3. Katalog wyjściowy poza wszystkimi źródłami. Katalog wyjściowy także nie może zawierać źródła.

Nie dodawaj cudzysłowów do ścieżek wpisywanych interaktywnie. Program nie szuka instalacji gry. Nie wskazuj cudzych archiwów ani katalogów całych dysków. Raport można zebrać przy uruchomionej grze; zmieniające się pliki zostaną oznaczone, a odczyt zakończy się na rozmiarze ustalonym na początku.

Przykład z Windows PowerShell (zastąp ścieżki swoimi):

```powershell
& 'C:\Narzedzia\amdnr-diagnostics\Collect-AmdNrDiagnostics.ps1' `
  -GamePath 'D:\Gry\Forza Horizon 6\Content' `
  -AdditionalLogPaths @('D:\Logi\OptiScaler', 'D:\Logi\Anywhere') `
  -OutputDirectory 'D:\RaportyAMDNR'
$LASTEXITCODE
```

Bez źródła gry nadal można zebrać system i HIP, podając tylko `-OutputDirectory`. Do parametrów przyjmowane są wyłącznie bezwzględne ścieżki lokalnych dysków. UNC, ścieżki urządzeń, inne providery, katalog główny dysku jako źródło oraz punkty ponownej analizy na ścieżce są odrzucane. Junction/symlink napotkany podczas zbierania jest pomijany.

Uruchamiacz korzysta z systemowego `powershell.exe -NoLogo -NoProfile -File … -Interactive`. Nie wymaga administratora, nie zmienia zasad wykonywania ani zabezpieczeń i nie stosuje `ExecutionPolicy Bypass`. Jeżeli Windows blokuje skrypt zasadą wykonywania albo zasadą organizacji, zbieranie nie wystartuje. Komunikat PowerShell wskazuje przyczynę; narzędzie nie obchodzi takiej blokady. Kod uruchamiacza w takim przypadku pochodzi z PowerShell, a nie z utworzonego raportu.

## Zawartość i ograniczenia

- Z każdego źródła: wszystkie `*.log`, `OptiScaler.ini`, `dlssnr_on_amd.ini`, bez rozróżniania wielkości liter. Katalog główny i maksymalnie dwa poziomy podkatalogów. Źródła zachowują identyfikatory `game`, `additional-01`…`additional-08`; duplikat pliku jest czytany raz z wieloma przypisaniami.
- Pomijane katalogi: `save`, `saves`, `savegame`, `savegames`, `cache`, `caches`, `shadercache`, `gpucache`, `binaries`, `models`, `weights`. Każde takie pominięcie jest odnotowane. Brak skanowania EventLogs, WER, minidumpów, savegames lub innych lokalizacji.
- Teksty: 2 MiB na plik, 20 MiB łącznie — osobny budżet bajtów wejściowych i zapisanych kopii UTF-8. Maksymalnie 1000 kandydatów i 10 000 odwiedzonych wpisów. Po przerwaniu enumeracji nie ma twierdzenia, że reszta plików została policzona.
- Mały tekst jest czytany w całości. Dla przekroczenia budżetu czytana jest końcówka (również dla INI); odrzucany jest jej pierwszy urwany wiersz. Pierwsze maksymalnie 4 bajty służą rozpoznaniu BOM i liczą się do budżetu. Obcinanie po maskowaniu zachowuje końcowy fragment od początku wiersza. Gdy żaden wiersz się nie mieści, kopia jest pomijana z jawnym powodem.
- BOM UTF-8/UTF-16/UTF-32 jest rozpoznawany od najdłuższego. Bez BOM stosowany jest UTF-8, a przy błędnym kodowaniu lokalna strona kodowa Windows. Informacja o zastępstwie trafia do manifestu. Kopie są zawsze UTF-8 bez BOM i mają techniczne nazwy, np. `files/game/0001.log`.
- Tylko metadane stałej listy EXE/DLL w katalogu głównym gry: ForzaHorizon6.exe, OptiScaler.dll, dxgi.dll, d3d11.dll, d3d12.dll, version.dll, winmm.dll, dbghelp.dll, nvngx.dll, nvngx_dlss.dll, nvngx_dlssd.dll, amd_presr.dll, amd_bridge.dll, dlssnr_on_amd.dll, lmxxf_backend.dll, amdhip64.dll, amdhip64_7.dll, winhttp.dll, wininet.dll, nvngx_dlssnr.dll, dlssnr_amd_pass1.dll, dlssnr_amd_pass2.dll, dlssnr_amd_pass3.dll, LmxxfNrRuntime.dll. To kandydaci, nie założenie o składzie konkretnej instalacji. `absent` opcjonalnej biblioteki samo w sobie nie dowodzi awarii.
- Tylko sześć wartości środowiska: `HIP_PATH` i `HIP_PATH_7_2`, każda Process/User/Machine. Dla lokalnych katalogów sprawdzane jest `bin\amdhip64_7.dll`; dodatkowo standardowa lokalizacja `C:\Program Files\AMD\ROCm\7.2\bin\amdhip64_7.dll`. Ten sam plik jest hashowany raz, z zachowaniem wskazań.
- Metadane obejmują obecność, rozmiar, UTC modyfikacji, FileVersion/ProductVersion i SHA256 lub przyczynę braku hasha. Limit hashowania: 128 MiB na plik, 256 MiB łącznie. Hash zmienianego pliku ma status `unstable`. Biblioteki nie są ładowane ani kopiowane; do raportu nie trafiają EXE, DLL ani wagi modeli.
- System: wyłącznie Caption/Version/BuildNumber z Win32_OperatingSystem i Name/DriverVersion z Win32_VideoController. Dwa selektywne odczyty CIM, z timeoutem operacji 5 sekund. Bez numerów seryjnych i pełnego dumpu systemu.

## Wynik i interpretacja

Każde uruchomienie tworzy nowy katalog `amdnr-<UTC>-<GUID>` oraz ZIP o tej samej nazwie obok niego. Nie ma nadpisywania poprzednich raportów ani automatycznego usuwania. ZIP otrzymuje końcową nazwę dopiero po zamknięciu archiwum. Jeśli tworzenie ZIP zawiedzie, katalog raportu pozostaje i opisuje usterkę.

| Status / kod procesu | Znaczenie |
| --- | --- |
| `complete` / `0` | Zakończono zbieranie w zadanym, ograniczonym zakresie bez usterek. Przewidziane wykluczenia i nieobecne opcjonalne DLL mogą występować. |
| `partial` / `2` | Raport powstał, ale wystąpił np. brak źródła, błąd dostępu/CIM/ZIP, zmiana pliku, zastępstwo kodowania, obcięcie albo limit. |
| `failed` / `1` | Niepoprawne ścieżki/parametry lub błąd uniemożliwiający utworzenie raportu. Nie zakładaj poprawnego ZIP; sprawdź komunikat. |

`summary.txt` daje podsumowanie, `issues.csv` opisuje usterki i pominięcia, a `manifest.json` zawiera źródła, limity, metadane, liczniki, statusy oraz informacje o kopiach. `readRanges` i `contentRange` to zakresy **[początek bajtu, koniec wyłączny)** liczone od początku pliku. `contentRange` opisuje wejście do maskowania, a nie odwzorowanie zapisanej kopii bajt w bajt. `rawBytesRead` i `outputBytes` są odrębne. SHA256 kopii dotyczy tylko zamaskowanej kopii. Pola `selection`, `truncationReason`, `outputSuffixTrimmed` i `changedDuringCollection` wyjaśniają ograniczenia.

Obecność biblioteki, poprawny hash i jej wersja nie dowodzą ładowalności, zgodności sterownika ani wykonania NR. Raport z nieistniejącym katalogiem gry zawiera tylko dostępne inne dane i ma status `partial`. Narzędzie nie uruchamia gry, nie zatrzymuje procesów/pobierania i nie zmienia HIP, sterowników, rejestru, GameBar, ACL ani innych ustawień.

## Prywatność i udostępnianie

Surowe teksty przebywają wyłącznie w pamięci. Wszystkie zapisywane pola tekstowe oraz kopie są maskowane wspólną funkcją: katalog domowy, ścieżki profili Windows, bieżący login, adresy e-mail i wartości kluczy `token`, `access_token`, `refresh_token`, `password`, `passwd`, `authorization`, `api_key`, `apikey`, `secret`. Obsługiwane są typowe zapisy INI/JSON, nagłówki Authorization i parametry URL. Maskowanie może także usunąć nieszkodliwy tekst; nie jest parserem wszystkich formatów ani gwarancją pełnej anonimizacji.

**Przed udostępnieniem samodzielnie przejrzyj wszystkie pliki raportu.** Nietypowe sekrety, inne nazwy użytkowników zapisane bez ścieżki, nazwy maszyn, adresy IP lub inne dane mogą pozostać. Program niczego nie wysyła i nie otwiera stron. Po ręcznej zmianie raportu pierwotny ZIP oraz hashe zapisanych kopii nie opisują tych zmian — nie wysyłaj starego ZIP przez pomyłkę.

Narzędzie nie wymaga instalacji. Żeby je usunąć, usuń własne kopie `Collect-AmdNrDiagnostics.ps1` i `Start-Diagnostics.cmd`, jeśli nie potrzebujesz późniejszych lokalnych zmian. Dokumentację możesz usunąć osobno. Raporty pozostają do osobnej decyzji użytkownika; nie są kasowane przez zbieracz.

## Referencje podane w briefie

- [TheAutomatic — wydanie v1.10.4.1](https://github.com/TheAutomatic/dlss-5-amd-project/releases/tag/v1.10.4.1)
- [3zwr1 — AMD NR / OptiScaler](https://github.com/3zwr1/AMD-NR---OptiScaler/releases)
- [danielblnc — DLSS NR on AMD](https://github.com/danielblnc/DLSS-NR-on-AMD/releases)

To odnośniki informacyjne, nie zależności programu. Zbieracz nie łączy się z GitHubem i nie zastępuje osobnego monitorowania wydań.
