[CmdletBinding(DefaultParameterSetName = 'Paths')]
param(
    [Parameter(ParameterSetName = 'Paths')][string]$GamePath,
    [Parameter(ParameterSetName = 'Paths')][string[]]$AdditionalLogPaths = @(),
    [Parameter(ParameterSetName = 'Paths')][string]$OutputDirectory,
    [Parameter(Mandatory = $true, ParameterSetName = 'Interactive')][switch]$Interactive
)

# AMD NR diagnostics v1.0.0. Offline, read-only sources. Windows PowerShell 5.1.
# Dot-source this file to test functions without starting collection.
Set-StrictMode -Version 2.0
$script:AmdVersion = '1.0.0'
$script:AmdUtf8 = New-Object System.Text.UTF8Encoding($false)
$script:AmdHome = [Environment]::GetFolderPath('UserProfile')
$script:AmdLogin = [Environment]::UserName

function Protect-AmdText {
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return $null }
    $s = $Text
    if ($script:AmdHome) {
        foreach ($h in @($script:AmdHome, $script:AmdHome.Replace('\','/'), $script:AmdHome.Replace('\','\\'))) {
            $s = [regex]::Replace($s, [regex]::Escape($h), '[HOME]', 'IgnoreCase')
        }
    }
    $s = [regex]::Replace($s, '(?i)[a-z]:[\\/]+Users[\\/]+[^\\/\s"''<>:]+', '[PROFILE]')
    if ($script:AmdLogin) {
        $s = [regex]::Replace($s, '(?<![\p{L}\p{N}_])' + [regex]::Escape($script:AmdLogin) + '(?![\p{L}\p{N}_])', '[USER]', 'IgnoreCase')
    }
    $s = [regex]::Replace($s, '(?i)[a-z0-9.!#$%&''*+/=?^_`{|}~-]+@[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\.[a-z]{2,}', '[EMAIL]')
    $keys = 'token|access_token|refresh_token|password|passwd|authorization|api_key|apikey|secret'
    # Quoted JSON/INI values first, including JSON escapes; preserve surrounding syntax.
    $s = [regex]::Replace($s, '(?i)((?:"(?:' + $keys + ')"|\b(?:' + $keys + ')\b)\s*[:=]\s*")(?:\\.|[^"\\])*"', '$1[REDACTED]"')
    $s = [regex]::Replace($s, "(?i)((?:'(?:" + $keys + ")'|\b(?:" + $keys + ")\b)\s*[:=]\s*')[^']*'", "`$1[REDACTED]'")
    $s = [regex]::Replace($s, '(?im)(\bauthorization\b\s*:\s*)(?!["''])([^\r\n]+)', '$1[REDACTED]')
    # Conservatively consume the full INI/URL value line: & and # may be part of a secret.
    $s = [regex]::Replace($s, '(?i)(\b(?:' + $keys + ')\b\s*=\s*)(?!["''])([^\r\n]+)', '$1[REDACTED]')
    $s = [regex]::Replace($s, '(?i)("(?:' + $keys + ')"\s*:\s*)(?!["''])([^,}\r\n]+)', '$1"[REDACTED]"')
    $s = [regex]::Replace($s, '(?i)(\b(?:' + $keys + ')\b\s*:\s*)(?!["''])([^\s,}\r\n]+)', '$1[REDACTED]')
    return $s
}

function Protect-AmdObject {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) { return (Protect-AmdText $Value) }
    if ($Value -is [System.Collections.IDictionary]) {
        $copy = [ordered]@{}
        foreach ($key in $Value.Keys) { $copy[(Protect-AmdText ([string]$key))] = Protect-AmdObject $Value[$key] }
        return $copy
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $copy = New-Object System.Collections.Generic.List[object]
        foreach ($item in $Value) { $copy.Add((Protect-AmdObject $item)) }
        return ,($copy.ToArray())
    }
    if ($Value -is [pscustomobject]) {
        $copy = [ordered]@{}
        foreach ($p in $Value.PSObject.Properties) { $copy[(Protect-AmdText $p.Name)] = Protect-AmdObject $p.Value }
        return $copy
    }
    if ($Value -is [ValueType]) { return $Value }
    return (Protect-AmdText ([string]$Value))
}

function Test-AmdAncestors {
    param([string]$Path)
    $p = $Path
    while ($p) {
        # GetAttributes distinguishes missing entries from inaccessible ones; Exists does not.
        try {
            $attributes = [IO.File]::GetAttributes($p)
            if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "reparsePoint: $p" }
        } catch [IO.FileNotFoundException] {
        } catch [IO.DirectoryNotFoundException] {
        }
        $parent = [IO.Path]::GetDirectoryName($p.TrimEnd('\'))
        if (-not $parent -or $parent -eq $p) { break }
        if ($parent -match '^[A-Za-z]:$') { $parent += '\' }
        $p = $parent
    }
}

function Resolve-AmdLocalPath {
    param([string]$Path, [switch]$Source)
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'emptyPath: wymagany bezwzgledny katalog lokalny.' }
    $p = $Path.Trim().Replace('/','\')
    if ($p -notmatch '^[A-Za-z]:\\' -or $p.Substring(2).Contains(':') -or $p -match '[*?\x00-\x1f]') {
        throw "invalidLocalPath: $Path"
    }
    $p = [IO.Path]::GetFullPath($p)
    $root = [IO.Path]::GetPathRoot($p)
    $drive = New-Object IO.DriveInfo($root)
    if ($drive.DriveType -notin @([IO.DriveType]::Fixed, [IO.DriveType]::Removable, [IO.DriveType]::Ram)) { throw "nonLocalDrive: $Path" }
    $p = $p.TrimEnd('\')
    if ($p -match '^[A-Za-z]:$') { $p += '\' }
    if ($Source -and $p.Equals($root, [StringComparison]::OrdinalIgnoreCase)) { throw "sourceDriveRoot: $Path" }
    Test-AmdAncestors $p
    if ([IO.File]::Exists($p)) { throw "directoryRequired: $Path" }
    return $p
}

function Test-AmdNestedPath {
    param([string]$Path, [string]$Parent)
    return ($Path.Equals($Parent, [StringComparison]::OrdinalIgnoreCase) -or $Path.StartsWith($Parent.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase))
}

function New-AmdContext {
    return @{
        issues = (New-Object System.Collections.Generic.List[object]); partial = $false
        limits = [ordered]@{textInputPerFileBytes=2097152; textOutputPerFileBytes=2097152; textInputTotalBytes=20971520; textOutputTotalBytes=20971520; candidates=1000; visitedEntries=10000; depth=2; hashPerFileBytes=134217728; hashTotalBytes=268435456}
        counters = [ordered]@{visitedEntries=0; candidates=0; rawBytesRead=0L; outputBytes=0L; hashBytesRead=0L; copies=0; enumerationComplete=$true; contentCollectionComplete=$true}
    }
}

function Add-AmdIssue {
    param($Context, [string]$Stage, [string]$SourceId, [string]$Code, [string]$Description, [switch]$Expected)
    $Context.issues.Add([ordered]@{stage=$Stage;sourceId=$SourceId;code=$Code;description=(Protect-AmdText $Description);affectsStatus=(-not $Expected)})
    if (-not $Expected) { $Context.partial = $true }
}

function Get-AmdSnapshot {
    param([string]$Path)
    Test-AmdAncestors $Path
    $f = New-Object IO.FileInfo($Path)
    $f.Refresh()
    if (-not $f.Exists) { throw "fileMissing: $Path" }
    return [pscustomobject]@{length=[long]$f.Length;lastWriteTimeUtc=$f.LastWriteTimeUtc.ToString('o')}
}

function Open-AmdRead {
    param([string]$Path)
    Test-AmdAncestors $Path
    return [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
}

function Get-AmdCandidates {
    param($Context, $Sources)
    $map = @{}; $ordered = New-Object System.Collections.Generic.List[object]; $seenRoots = @{}
    $excluded = @('save','saves','savegame','savegames','cache','caches','shadercache','gpucache','binaries','models','weights')
    $stop = $false
    foreach ($source in $Sources) {
        if ($source.status -ne 'available') { continue }
        if ($seenRoots.ContainsKey($source.path)) {
            foreach ($record in $seenRoots[$source.path]) { if (-not $record.sourceIds.Contains($source.id)) { $record.sourceIds.Add($source.id) } }
            continue
        }
        if ($stop) { break }
        $found = New-Object System.Collections.Generic.List[object]
        $seenRoots[$source.path] = $found
        $queue = New-Object System.Collections.Generic.Queue[object]
        $queue.Enqueue(@{path=$source.path;depth=0})
        while ($queue.Count -gt 0 -and -not $stop) {
            $dir = $queue.Dequeue()
            try {
                Test-AmdAncestors $dir.path
                foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($dir.path)) {
                    if ($Context.counters.visitedEntries -ge $Context.limits.visitedEntries) {
                        Add-AmdIssue $Context 'enumeration' $source.id 'entryLimit' 'Przerwano enumeracje przy 10000 wpisow; dalsze wpisy nie zostaly policzone.'
                        $stop = $true; break
                    }
                    $Context.counters.visitedEntries++
                    try {
                        $attr = [IO.File]::GetAttributes($entry)
                        if (($attr -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                            Add-AmdIssue $Context 'enumeration' $source.id 'reparseSkipped' $entry -Expected; continue
                        }
                        if (($attr -band [IO.FileAttributes]::Directory) -ne 0) {
                            $name = [IO.Path]::GetFileName($entry)
                            if ($name -in $excluded) { Add-AmdIssue $Context 'enumeration' $source.id 'excludedDirectory' $entry -Expected }
                            elseif ($dir.depth -ge $Context.limits.depth) { Add-AmdIssue $Context 'enumeration' $source.id 'depthExcluded' $entry -Expected }
                            else { $queue.Enqueue(@{path=$entry;depth=($dir.depth+1)}) }
                            continue
                        }
                        $name = [IO.Path]::GetFileName($entry)
                        if ([IO.Path]::GetExtension($name) -ine '.log' -and $name -inotmatch '^(OptiScaler|dlssnr_on_amd)\.ini$') { continue }
                        if ($map.ContainsKey($entry)) {
                            $record = $map[$entry]
                            if (-not $record.sourceIds.Contains($source.id)) { $record.sourceIds.Add($source.id) }
                            $found.Add($record); continue
                        }
                        if ($Context.counters.candidates -ge $Context.limits.candidates) {
                            Add-AmdIssue $Context 'enumeration' $source.id 'candidateLimit' 'Przerwano enumeracje po 1000 kandydatach; lista dalszych plikow nie jest pelna.'
                            $stop = $true; break
                        }
                        $Context.counters.candidates++
                        $ids = New-Object System.Collections.Generic.List[string]; $ids.Add($source.id)
                        $record = @{path=$entry;sourceIds=$ids;primarySource=$source.id;relativePath=$entry.Substring($source.path.TrimEnd('\').Length+1)}
                        $map[$entry] = $record; $ordered.Add($record); $found.Add($record)
                    } catch { Add-AmdIssue $Context 'enumeration' $source.id 'entryAccessError' $_.Exception.Message }
                }
            } catch { Add-AmdIssue $Context 'enumeration' $source.id 'directoryAccessError' $_.Exception.Message }
        }
    }
    # Duplicate roots still retain source assignment even after a global enumeration stop.
    foreach ($source in $Sources) {
        if ($source.path -and $seenRoots.ContainsKey($source.path)) {
            foreach ($record in $seenRoots[$source.path]) { if (-not $record.sourceIds.Contains($source.id)) { $record.sourceIds.Add($source.id) } }
        }
    }
    if ($stop) { $Context.counters.enumerationComplete=$false }
    return ,($ordered.ToArray())
}

function Read-AmdRange {
    param($Stream, [long]$Start, [int]$Count, $Context, $Record)
    if ($Count -le 0) { return ,([byte[]]@()) }
    $null = $Stream.Seek($Start, [IO.SeekOrigin]::Begin)
    $buffer = New-Object byte[] $Count; $done = 0
    try {
        while ($done -lt $Count) {
            $n = $Stream.Read($buffer, $done, $Count-$done)
            if ($n -eq 0) { break }
            $done += $n; $Record.rawBytesRead += $n; $Context.counters.rawBytesRead += $n
        }
    } finally {
        if ($done -gt 0) { $Record.readRanges.Add(@([long]$Start, [long]($Start+$done))) }
    }
    if ($done -ne $Count) {
        $short = New-Object byte[] $done
        [Array]::Copy($buffer, $short, $done); return ,$short
    }
    return ,$buffer
}

function Get-AmdEncoding {
    param([byte[]]$Head)
    $name='utf-8'; $bom=0; $unit=1; $cp=65001
    if ($Head.Length -ge 4 -and $Head[0]-eq 255 -and $Head[1]-eq 254 -and $Head[2]-eq 0 -and $Head[3]-eq 0) { $name='utf-32le';$bom=4;$unit=4;$cp=12000 }
    elseif ($Head.Length -ge 4 -and $Head[0]-eq 0 -and $Head[1]-eq 0 -and $Head[2]-eq 254 -and $Head[3]-eq 255) { $name='utf-32be';$bom=4;$unit=4;$cp=12001 }
    elseif ($Head.Length -ge 3 -and $Head[0]-eq 239 -and $Head[1]-eq 187 -and $Head[2]-eq 191) { $bom=3 }
    elseif ($Head.Length -ge 2 -and $Head[0]-eq 255 -and $Head[1]-eq 254) { $name='utf-16le';$bom=2;$unit=2;$cp=1200 }
    elseif ($Head.Length -ge 2 -and $Head[0]-eq 254 -and $Head[1]-eq 255) { $name='utf-16be';$bom=2;$unit=2;$cp=1201 }
    $enc = [Text.Encoding]::GetEncoding($cp, [Text.EncoderFallback]::ExceptionFallback, [Text.DecoderFallback]::ExceptionFallback)
    return @{name=$name;bom=$bom;unit=$unit;encoding=$enc}
}

function Convert-AmdBytesToText {
    param([byte[]]$Bytes, [long]$Start, [long]$InitialLength, $Info, [bool]$Tail)
    $lo=0; $hi=$Bytes.Length
    if ($Start -lt $Info.bom) { $lo=[int]($Info.bom-$Start) }
    if ($Info.unit -gt 1) {
        while ($lo -lt $hi -and (($Start+$lo-$Info.bom) % $Info.unit) -ne 0) { $lo++ }
        while ($hi -gt $lo -and (($Start+$hi-$Info.bom) % $Info.unit) -ne 0) { $hi-- }
    }
    if ($Info.unit -eq 2 -and $hi-$lo -ge 2) {
        $be = $Info.name -eq 'utf-16be'
        $first = if ($be) { ($Bytes[$lo]*256)+$Bytes[$lo+1] } else { $Bytes[$lo]+($Bytes[$lo+1]*256) }
        if ($Tail -and $first -ge 0xDC00 -and $first -le 0xDFFF) { $lo+=2 }
        if ($hi-$lo -ge 2) {
            $last = if ($be) { ($Bytes[$hi-2]*256)+$Bytes[$hi-1] } else { $Bytes[$hi-2]+($Bytes[$hi-1]*256) }
            if ($last -ge 0xD800 -and $last -le 0xDBFF) { $hi-=2 }
        }
    }
    if ($Info.name -eq 'utf-8') {
        # Boundary repair only: do not hide invalid interior UTF-8 bytes from fallback.
        if ($Tail) { while ($lo -lt $hi -and ($Bytes[$lo] -band 0xC0) -eq 0x80) { $lo++ } }
        if ($hi -gt $lo) {
            $lead=$hi-1
            while ($lead -gt $lo -and ($Bytes[$lead] -band 0xC0) -eq 0x80 -and $hi-$lead -le 4) { $lead-- }
            $b=[int]$Bytes[$lead]; $need=1
            if ($b -ge 0xC2 -and $b -le 0xDF) { $need=2 }
            elseif ($b -ge 0xE0 -and $b -le 0xEF) { $need=3 }
            elseif ($b -ge 0xF0 -and $b -le 0xF4) { $need=4 }
            if ($need -gt $hi-$lead) { $hi=$lead }
        }
    }
    $fallback=$false; $enc=$Info.encoding; $name=$Info.name
    try { $text = $enc.GetString($Bytes, $lo, [Math]::Max(0,$hi-$lo)) }
    catch {
        $fallback=$true
        if ($Info.bom -eq 0) {
            # Decode the original selected bytes for ANSI fallback (UTF-8 boundary rules do not apply).
            $lo=0; $hi=$Bytes.Length; $enc=[Text.Encoding]::Default; $name='windows-' + $enc.CodePage
        } else { $enc=[Text.Encoding]::GetEncoding($Info.encoding.CodePage) }
        $text=$enc.GetString($Bytes,$lo,[Math]::Max(0,$hi-$lo))
    }
    if ($Tail -and ($Start+$lo) -gt $Info.bom) {
        $line=[regex]::Match($text, '\r\n|\n|\r')
        if (-not $line.Success) { return @{text='';start=($Start+$hi);end=($Start+$hi);encoding=$name;fallback=$fallback;noUsableTail=$true} }
        $cut=$line.Index+$line.Length
        $lo += $enc.GetByteCount($text.Substring(0,$cut))
        $text=$text.Substring($cut)
    }
    return @{text=$text;start=($Start+$lo);end=($Start+$hi);encoding=$name;fallback=$fallback;noUsableTail=($Tail -and $text.Length -eq 0)}
}

function Limit-AmdOutputText {
    param([string]$Text, [int]$Budget)
    if ($script:AmdUtf8.GetByteCount($Text) -le $Budget) { return @{text=$Text;trimmed=$false;usable=$true} }
    # Find a byte-safe suffix by binary search, then advance to a complete line boundary.
    $low=0; $high=$Text.Length
    while ($low -lt $high) {
        $mid=[int][Math]::Floor(($low+$high)/2)
        if ($script:AmdUtf8.GetByteCount($Text.Substring($mid)) -le $Budget) { $high=$mid } else { $low=$mid+1 }
    }
    $start=$low
    if ($start -gt 0 -and $Text[$start-1] -eq "`n") { }
    elseif ($start -gt 0 -and $Text[$start-1] -eq "`r" -and ($start -eq $Text.Length -or $Text[$start] -ne "`n")) { }
    else {
        $line=[regex]::Match($Text.Substring($start), '\r\n|\n|\r')
        if (-not $line.Success) { return @{text='';trimmed=$true;usable=$false} }
        $start += $line.Index+$line.Length
    }
    if ($start -ge $Text.Length) { return @{text='';trimmed=$true;usable=$false} }
    return @{text=$Text.Substring($start);trimmed=$true;usable=$true}
}

function Get-AmdByteHash {
    param([byte[]]$Bytes)
    $sha=[Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','') } finally { $sha.Dispose() }
}

function Collect-AmdTextFile {
    param($Context, $Candidate, [string]$ReportPath, [int]$Number)
    $r=[ordered]@{id=('text-{0:d4}' -f $Number);sourceIds=$Candidate.sourceIds.ToArray();relativePath=$Candidate.relativePath;status='pending';selection='skipped';initialLengthBytes=$null;before=$null;after=$null;changedDuringCollection=$false;encoding=$null;bomLength=0;decodingFallback=$false;readRanges=(New-Object System.Collections.Generic.List[object]);contentRange=$null;rawBytesRead=0L;outputBytes=0L;truncationReason=$null;outputSuffixTrimmed=$false;copyPath=$null;copySha256=$null}
    $stream=$null
    try {
        $r.before=Get-AmdSnapshot $Candidate.path; $r.initialLengthBytes=$r.before.length
        $inBudget=[long][Math]::Min($Context.limits.textInputPerFileBytes, $Context.limits.textInputTotalBytes-$Context.counters.rawBytesRead)
        $outBudget=[long][Math]::Min($Context.limits.textOutputPerFileBytes, $Context.limits.textOutputTotalBytes-$Context.counters.outputBytes)
        $headCount=[int][Math]::Min(4,$r.initialLengthBytes)
        if ($outBudget -le 0 -or $inBudget -lt $headCount -or ($r.initialLengthBytes -gt $headCount -and $inBudget -le $headCount)) {
            $r.status='skipped';$r.truncationReason='budgetExceeded';$Context.counters.contentCollectionComplete=$false
            Add-AmdIssue $Context 'text' $Candidate.primarySource 'budgetExceeded' 'Brak budzetu na rozpoznanie i tresc kolejnego pliku.'
            return $r
        }
        $stream=Open-AmdRead $Candidate.path
        [byte[]]$head=Read-AmdRange $stream 0 $headCount $Context $r
        $info=Get-AmdEncoding $head; $r.bomLength=$info.bom
        $tail=($r.initialLengthBytes -gt $inBudget); $r.selection=if($tail){'tail'}else{'full'}
        if ($tail) {
            $r.truncationReason='inputLimit';$Context.counters.contentCollectionComplete=$false
            Add-AmdIssue $Context 'text' $Candidate.primarySource 'inputTruncated' $Candidate.relativePath
            $count=[int]($inBudget-$r.rawBytesRead); $start=[long]($r.initialLengthBytes-$count)
            [byte[]]$bytes=Read-AmdRange $stream $start $count $Context $r
        } else {
            $start=0L
            [byte[]]$rest=Read-AmdRange $stream $head.Length ([int]($r.initialLengthBytes-$head.Length)) $Context $r
            $bytes=New-Object byte[] ($head.Length+$rest.Length)
            [Array]::Copy($head,0,$bytes,0,$head.Length);[Array]::Copy($rest,0,$bytes,$head.Length,$rest.Length)
        }
        $decoded=Convert-AmdBytesToText $bytes $start $r.initialLengthBytes $info $tail
        $r.encoding=$decoded.encoding;$r.decodingFallback=$decoded.fallback;$r.contentRange=@([long]$decoded.start,[long]$decoded.end)
        if ($decoded.fallback) { Add-AmdIssue $Context 'text' $Candidate.primarySource 'decodingFallback' ($Candidate.relativePath + ': ' + $decoded.encoding) }
        if ($decoded.noUsableTail) {
            $r.status='skipped';$r.truncationReason='noUsableTail'
            Add-AmdIssue $Context 'text' $Candidate.primarySource 'noUsableTail' $Candidate.relativePath
            return $r
        }
        $protected=Protect-AmdText $decoded.text
        $limited=Limit-AmdOutputText $protected ([int]$outBudget);$r.outputSuffixTrimmed=$limited.trimmed
        if ($limited.trimmed) {
            $Context.counters.contentCollectionComplete=$false;$r.truncationReason='outputLimit'
            Add-AmdIssue $Context 'text' $Candidate.primarySource 'outputTruncated' $Candidate.relativePath
        }
        if (-not $limited.usable) {
            $r.status='skipped';$r.truncationReason='outputBudgetNoCompleteLine'
            Add-AmdIssue $Context 'text' $Candidate.primarySource 'outputBudgetNoCompleteLine' $Candidate.relativePath
            return $r
        }
        [byte[]]$output=$script:AmdUtf8.GetBytes($limited.text)
        $extension=[IO.Path]::GetExtension($Candidate.path).ToLowerInvariant()
        $relative='files\' + $Candidate.primarySource + '\' + ('{0:d4}' -f $Number) + $extension
        $destination=Join-Path $ReportPath $relative
        $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination));Test-AmdAncestors $destination
        $out=[IO.File]::Open($destination,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try { $out.Write($output,0,$output.Length) } finally { $out.Dispose() }
        $r.copyPath=$relative.Replace('\','/');$r.copySha256=Get-AmdByteHash $output;$r.outputBytes=$output.Length
        $Context.counters.outputBytes+=$output.Length;$Context.counters.copies++
        $r.status=if($r.truncationReason){'truncated'}else{'collected'}
    } catch {
        $r.status='error';Add-AmdIssue $Context 'text' $Candidate.primarySource 'readOrCopyError' $_.Exception.Message
    } finally {
        if ($stream) { $stream.Dispose() }
        if ($r.before) {
            try {
                $r.after=Get-AmdSnapshot $Candidate.path
                $r.changedDuringCollection=($r.before.length -ne $r.after.length -or $r.before.lastWriteTimeUtc -ne $r.after.lastWriteTimeUtc)
                if ($r.changedDuringCollection) { Add-AmdIssue $Context 'text' $Candidate.primarySource 'changedDuringCollection' $Candidate.relativePath }
            } catch { $r.changedDuringCollection=$true;Add-AmdIssue $Context 'text' $Candidate.primarySource 'postReadError' $_.Exception.Message }
        }
    }
    return $r
}

function Get-AmdCimData {
    param([string]$ClassName, [string[]]$Properties)
    Get-CimInstance -ClassName $ClassName -Property $Properties -OperationTimeoutSec 5 -ErrorAction Stop | Select-Object -Property $Properties
}

function Get-AmdSystem {
    param($Context)
    $data=[ordered]@{operatingSystem=@();videoControllers=@()}
    try { $data.operatingSystem=@(Get-AmdCimData 'Win32_OperatingSystem' @('Caption','Version','BuildNumber')) }
    catch { Add-AmdIssue $Context 'system' 'system' 'cimOperatingSystemError' $_.Exception.Message }
    try { $data.videoControllers=@(Get-AmdCimData 'Win32_VideoController' @('Name','DriverVersion')) }
    catch { Add-AmdIssue $Context 'system' 'system' 'cimVideoControllerError' $_.Exception.Message }
    return $data
}

function Get-AmdEnvironment {
    $values=New-Object System.Collections.Generic.List[object]
    foreach ($name in @('HIP_PATH','HIP_PATH_7_2')) {
        foreach ($scope in @('Process','User','Machine')) {
            $values.Add([ordered]@{name=$name;scope=$scope;value=[Environment]::GetEnvironmentVariable($name,$scope)})
        }
    }
    return ,($values.ToArray())
}

function Collect-AmdBinaryMetadata {
    param($Context, [string]$Path, [string[]]$SourceIds)
    $r=[ordered]@{path=$Path;sourceIds=$SourceIds;presence='unknown';sizeBytes=$null;lastWriteTimeUtc=$null;fileVersion=$null;productVersion=$null;sha256=$null;hashStatus='notAttempted';hashBytesRead=0L;before=$null;after=$null;changedDuringHash=$false}
    $stream=$null;$sha=$null
    try {
        Test-AmdAncestors $Path
        try { $attrs=[IO.File]::GetAttributes($Path) }
        catch [IO.FileNotFoundException] { $r.presence='absent';$r.hashStatus='absent';return $r }
        catch [IO.DirectoryNotFoundException] { $r.presence='absent';$r.hashStatus='absent';return $r }
        if (($attrs -band [IO.FileAttributes]::Directory) -ne 0) { throw "notAFile: $Path" }
        $r.presence='present';$r.before=Get-AmdSnapshot $Path;$r.sizeBytes=$r.before.length;$r.lastWriteTimeUtc=$r.before.lastWriteTimeUtc
        try {
            Test-AmdAncestors $Path
            $version=[Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
            $r.fileVersion=$version.FileVersion;$r.productVersion=$version.ProductVersion
        } catch { Add-AmdIssue $Context 'metadata' $SourceIds[0] 'versionReadError' $_.Exception.Message }
        if ($r.sizeBytes -gt $Context.limits.hashPerFileBytes) {
            $r.hashStatus='fileHashLimit';Add-AmdIssue $Context 'metadata' $SourceIds[0] 'fileHashLimit' $Path;return $r
        }
        if ($r.sizeBytes -gt $Context.limits.hashTotalBytes-$Context.counters.hashBytesRead) {
            $r.hashStatus='totalHashLimit';Add-AmdIssue $Context 'metadata' $SourceIds[0] 'totalHashLimit' $Path;return $r
        }
        $stream=Open-AmdRead $Path;$sha=[Security.Cryptography.SHA256]::Create();$buffer=New-Object byte[] 65536;$remaining=$r.sizeBytes
        while ($remaining -gt 0) {
            $n=$stream.Read($buffer,0,[int][Math]::Min($remaining,$buffer.Length))
            if ($n -eq 0) { break }
            $null=$sha.TransformBlock($buffer,0,$n,$buffer,0)
            $r.hashBytesRead+=$n;$Context.counters.hashBytesRead+=$n;$remaining-=$n
        }
        $null=$sha.TransformFinalBlock((New-Object byte[] 0),0,0)
        $r.sha256=([BitConverter]::ToString($sha.Hash)).Replace('-','');$r.hashStatus='stable'
        if ($remaining -ne 0) { $r.hashStatus='unstable';$r.changedDuringHash=$true;Add-AmdIssue $Context 'metadata' $SourceIds[0] 'shortHashRead' $Path }
    } catch { $r.hashStatus='error';Add-AmdIssue $Context 'metadata' $SourceIds[0] 'metadataError' $_.Exception.Message }
    finally {
        if ($sha) { $sha.Dispose() };if ($stream) { $stream.Dispose() }
        if ($r.before) {
            try {
                $r.after=Get-AmdSnapshot $Path
                if ($r.before.length -ne $r.after.length -or $r.before.lastWriteTimeUtc -ne $r.after.lastWriteTimeUtc) {
                    $r.changedDuringHash=$true;if($r.sha256){$r.hashStatus='unstable'}
                    Add-AmdIssue $Context 'metadata' $SourceIds[0] 'changedDuringHash' $Path
                }
            } catch { $r.changedDuringHash=$true;if($r.sha256){$r.hashStatus='unstable'};Add-AmdIssue $Context 'metadata' $SourceIds[0] 'postHashError' $_.Exception.Message }
        }
    }
    return $r
}

function Get-AmdMetadata {
    param($Context, $Sources, $EnvironmentValues)
    $map=@{};$entries=New-Object System.Collections.Generic.List[object]
    $names=@('ForzaHorizon6.exe','OptiScaler.dll','dxgi.dll','d3d11.dll','d3d12.dll','version.dll','winmm.dll','dbghelp.dll','nvngx.dll','nvngx_dlss.dll','nvngx_dlssd.dll','amd_presr.dll','amd_bridge.dll','dlssnr_on_amd.dll','lmxxf_backend.dll','amdhip64.dll','amdhip64_7.dll','winhttp.dll','wininet.dll','nvngx_dlssnr.dll','dlssnr_amd_pass1.dll','dlssnr_amd_pass2.dll','dlssnr_amd_pass3.dll','LmxxfNrRuntime.dll')
    foreach ($source in $Sources) {
        if ($source.id -eq 'game' -and $source.path) {
            foreach ($name in $names) {
                $p=Join-Path $source.path $name;$ids=New-Object System.Collections.Generic.List[string];$ids.Add('game')
                $item=@{path=$p;ids=$ids};$map[$p]=$item;$entries.Add($item)
            }
        }
    }
    $hips=New-Object System.Collections.Generic.List[object]
    foreach ($v in $EnvironmentValues) { if ($v.value) { $hips.Add(@{path=$v.value;id=($v.name+':'+$v.scope)}) } }
    $hips.Add(@{path='C:\Program Files\AMD\ROCm\7.2';id='standard-rocm-7.2'})
    foreach ($hip in $hips) {
        try {
            $folder=Resolve-AmdLocalPath $hip.path -Source;$p=Join-Path $folder 'bin\amdhip64_7.dll';Test-AmdAncestors $p
            if ($map.ContainsKey($p)) { $map[$p].ids.Add($hip.id) }
            else { $ids=New-Object System.Collections.Generic.List[string];$ids.Add($hip.id);$item=@{path=$p;ids=$ids};$map[$p]=$item;$entries.Add($item) }
        } catch { Add-AmdIssue $Context 'hip' $hip.id 'hipPathRejected' $_.Exception.Message }
    }
    $result=New-Object System.Collections.Generic.List[object]
    foreach ($item in $entries) { $result.Add((Collect-AmdBinaryMetadata $Context $item.path $item.ids.ToArray())) }
    return ,($result.ToArray())
}

function Get-AmdReportContent {
    param($Context, $Manifest)
    $pending=$Manifest.Contains('zipStatus') -and $Manifest.zipStatus -eq 'pending'
    $Manifest.status=if($Context.partial -or $pending){'partial'}else{'complete'}
    $Manifest.exitCode=if($Context.partial -or $pending){2}else{0}
    $Manifest.finishedUtc=[datetime]::UtcNow.ToString('o')
    $Manifest.issues=$Context.issues.ToArray()
    # Sanitize every string property BEFORE JSON escaping. Never regex-rewrite serialized JSON.
    $safe=Protect-AmdObject $Manifest
    $json=ConvertTo-Json -InputObject $safe -Depth 32
    $rows=@($safe.issues | ForEach-Object { [pscustomobject]$_ })
    $csv=if($rows.Count){ ($rows | ConvertTo-Csv -NoTypeInformation) -join "`r`n" }else{ '"stage","sourceId","code","description","affectsStatus"' }
    $lines=@(
        'AMD NR — raport diagnostyczny '+$script:AmdVersion,
        'Raport: '+$Manifest.reportId,
        'Status: '+$Manifest.status+'; kod: '+$Manifest.exitCode,
        'Kopie tekstowe: '+$Context.counters.copies,
        'Bajty odczytu tekstow: '+$Context.counters.rawBytesRead+' / 20971520',
        'Bajty zapisanych kopii UTF-8: '+$Context.counters.outputBytes+' / 20971520',
        'Bajty hashowania: '+$Context.counters.hashBytesRead+' / 268435456',
        'Pelna enumeracja w dozwolonym zakresie: '+$Context.counters.enumerationComplete,
        'Usterki i przewidziane pominiecia: '+$Context.issues.Count,
        '',
        'Logi i INI to zamaskowane kopie UTF-8, nie wierne kopie bajtowe.',
        'Obecnosc, wersja lub hash DLL nie dowodzi jej ladowalnosci ani wykonania NR.',
        'Nie uruchamiano gry. Narzedzie niczego nie wysyla.',
        'Przed udostepnieniem przejrzyj wszystkie pliki. Maskowanie nie gwarantuje pelnej anonimizacji.',
        'Szczegoly zakresow [startByte,endByteExclusive), zrodel i usterek: manifest.json oraz issues.csv.',
        ''
    )
    foreach ($issue in $Context.issues) { $lines += ('['+$issue.stage+'/'+$issue.sourceId+'] '+$issue.code+': '+$issue.description) }
    return [ordered]@{'issues.csv'=($csv+"`r`n");'summary.txt'=(Protect-AmdText ($lines -join "`r`n"));'manifest.json'=$json}
}

function Write-AmdTextAtomic {
    param([string]$Path, [string]$Text)
    $temporary=$Path+'.writing-'+[guid]::NewGuid().ToString('N')
    try {
        Test-AmdAncestors $Path;Test-AmdAncestors $temporary
        [IO.File]::WriteAllText($temporary,$Text,$script:AmdUtf8)
        Test-AmdAncestors $Path
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary,$Path,[NullString]::Value) }
        else { [IO.File]::Move($temporary,$Path) }
    } finally {
        if ([IO.File]::Exists($temporary)) { Test-AmdAncestors $temporary;[IO.File]::Delete($temporary) }
    }
}

function Write-AmdReport {
    param($Context, $Manifest, [string]$ReportPath, $Content=$null)
    if ($null -eq $Content) { $Content=Get-AmdReportContent $Context $Manifest }
    Test-AmdAncestors $ReportPath
    # The authoritative manifest is committed last, after all other report texts.
    foreach ($name in @('issues.csv','summary.txt','manifest.json')) {
        Write-AmdTextAtomic (Join-Path $ReportPath $name) $Content[$name]
    }
}

function Update-AmdZipReport {
    param([string]$TemporaryPath, $Content)
    Test-AmdAncestors $TemporaryPath
    $zip=[IO.Compression.ZipFile]::Open($TemporaryPath,[IO.Compression.ZipArchiveMode]::Update)
    try {
        foreach ($name in @('issues.csv','summary.txt','manifest.json')) {
            $old=$zip.GetEntry($name);if($old){$old.Delete()}
            $entry=$zip.CreateEntry($name,[IO.Compression.CompressionLevel]::Optimal)
            $stream=$entry.Open()
            try { $bytes=$script:AmdUtf8.GetBytes($Content[$name]);$stream.Write($bytes,0,$bytes.Length) }
            finally { $stream.Dispose() }
        }
    } finally { $zip.Dispose() }
}

function New-AmdZip {
    param([string]$ReportPath, [string]$TemporaryPath)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    Test-AmdAncestors $ReportPath;Test-AmdAncestors $TemporaryPath
    [IO.Compression.ZipFile]::CreateFromDirectory($ReportPath,$TemporaryPath,[IO.Compression.CompressionLevel]::Optimal,$false)
}

function Invoke-AmdDiagnostics {
    [CmdletBinding()]
    param([string]$GamePath,[string[]]$AdditionalLogPaths=@(),[string]$OutputDirectory)
    $context=New-AmdContext;$reportPath=$null;$zipPath=$null;$temporaryZip=$null
    try {
        if ($AdditionalLogPaths.Count -gt 8) { throw 'tooManySources: maksymalnie osiem dodatkowych katalogow.' }
        $output=Resolve-AmdLocalPath $OutputDirectory
        $sources=New-Object System.Collections.Generic.List[object]
        $requested=New-Object System.Collections.Generic.List[object]
        $requested.Add(@{id='game';path=$GamePath})
        for($i=0;$i-lt $AdditionalLogPaths.Count;$i++){ $requested.Add(@{id=('additional-{0:d2}' -f ($i+1));path=$AdditionalLogPaths[$i]}) }
        foreach($r in $requested) {
            if ([string]::IsNullOrWhiteSpace($r.path)) {
                $sources.Add([ordered]@{id=$r.id;path=$null;status='notProvided'})
                Add-AmdIssue $context 'source' $r.id 'sourceNotProvided' 'Nie wskazano katalogu zrodlowego.';continue
            }
            $accessError=$null
            try { $path=Resolve-AmdLocalPath $r.path -Source }
            catch [UnauthorizedAccessException] {
                $path=[IO.Path]::GetFullPath($r.path.Trim().Replace('/','\')).TrimEnd('\');$accessError=$_.Exception.Message
            }
            catch [Security.SecurityException] {
                $path=[IO.Path]::GetFullPath($r.path.Trim().Replace('/','\')).TrimEnd('\');$accessError=$_.Exception.Message
            }
            if ((Test-AmdNestedPath $output $path) -or (Test-AmdNestedPath $path $output)) { throw 'sourceOutputOverlap: zrodlo i wyjscie nie moga sie pokrywac ani zawierac wzajemnie.' }
            if ($accessError) {
                $sources.Add([ordered]@{id=$r.id;path=$path;status='inaccessible'})
                Add-AmdIssue $context 'source' $r.id 'sourceAccessError' $accessError
                continue
            }
            $status='available'
            try {
                $attr=[IO.File]::GetAttributes($path)
                if (($attr -band [IO.FileAttributes]::Directory) -eq 0) { throw "directoryRequired: $path" }
            } catch [IO.FileNotFoundException] { $status='missing' }
            catch [IO.DirectoryNotFoundException] { $status='missing' }
            catch { $status='inaccessible';Add-AmdIssue $context 'source' $r.id 'sourceAccessError' $_.Exception.Message }
            $sources.Add([ordered]@{id=$r.id;path=$path;status=$status})
            if ($status -eq 'missing') { Add-AmdIssue $context 'source' $r.id 'sourceMissing' $path }
        }
        $id='amdnr-'+[datetime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')+'-'+[guid]::NewGuid().ToString('N')
        $reportPath=Join-Path $output $id;$zipPath=$reportPath+'.zip';$temporaryZip=$reportPath+'.zip.partial'
        Test-AmdAncestors $output
        if ([IO.Directory]::Exists($reportPath) -or [IO.File]::Exists($zipPath) -or [IO.File]::Exists($temporaryZip)) { throw 'outputCollision' }
        $null=[IO.Directory]::CreateDirectory($reportPath);Test-AmdAncestors $reportPath
        $manifest=[ordered]@{schemaVersion='1.0';collectorVersion=$script:AmdVersion;reportId=$id;startedUtc=[datetime]::UtcNow.ToString('o');finishedUtc=$null;status='pending';exitCode=$null;limits=$context.limits;sources=$sources.ToArray();system=$null;hipEnvironment=@();metadata=@();files=@();counters=$context.counters;issues=@();zipStatus='pending';archiveName=($id+'.zip');rangeConvention='[startByte,endByteExclusive)';copyMeaning='Masked UTF-8; contentRange describes input to masking, not a byte mapping of the saved copy.'}
        $manifest.system=Get-AmdSystem $context
        try { $manifest.hipEnvironment=Get-AmdEnvironment } catch { Add-AmdIssue $context 'hip' 'environment' 'environmentReadError' $_.Exception.Message }
        $candidates=Get-AmdCandidates $context $sources.ToArray();$files=New-Object System.Collections.Generic.List[object];$number=0
        foreach($candidate in $candidates){$number++;$files.Add((Collect-AmdTextFile $context $candidate $reportPath $number))}
        $manifest.files=$files.ToArray()
        $manifest.metadata=Get-AmdMetadata $context $sources.ToArray() $manifest.hipEnvironment
        Write-AmdReport $context $manifest $reportPath
        $phase='zip';$zipCommitted=$false
        try {
            New-AmdZip $reportPath $temporaryZip
            $manifest.zipStatus='complete'
            $finalContent=Get-AmdReportContent $context $manifest
            Update-AmdZipReport $temporaryZip $finalContent
            Test-AmdAncestors $temporaryZip;Test-AmdAncestors $zipPath
            [IO.File]::Move($temporaryZip,$zipPath)
            $zipCommitted=$true;$phase='report'
            Write-AmdReport $context $manifest $reportPath $finalContent
        } catch {
            $failure=$_.Exception.Message
            if ($zipCommitted -and [IO.File]::Exists($zipPath)) {
                Test-AmdAncestors $zipPath;[IO.File]::Delete($zipPath)
            }
            $code=if($phase-eq'report'){'reportWriteError'}else{'zipError'}
            Add-AmdIssue $context $phase 'report' $code $failure
            if ([IO.File]::Exists($temporaryZip)) {
                try { Test-AmdAncestors $temporaryZip;[IO.File]::Delete($temporaryZip) } catch { }
            }
            $zipPath=$null
            $manifest.zipStatus='failed';Write-AmdReport $context $manifest $reportPath
        }
        return [pscustomobject]@{status=$manifest.status;exitCode=$manifest.exitCode;reportPath=$reportPath;zipPath=$zipPath;error=$null}
    } catch {
        return [pscustomobject]@{status='failed';exitCode=1;reportPath=$reportPath;zipPath=$null;error=(Protect-AmdText $_.Exception.Message)}
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    if ($Interactive) {
        $GamePath=Read-Host 'Pelna lokalna sciezka katalogu gry (Enter = brak)'
        $AdditionalLogPaths=@()
        for($i=1;$i-le 8;$i++) {
            $p=Read-Host ('Dodatkowy katalog logow '+$i+'/8 (Enter = koniec)')
            if ([string]::IsNullOrWhiteSpace($p)) { break }
            $AdditionalLogPaths+=$p
        }
        $OutputDirectory=Read-Host 'Pelna lokalna sciezka katalogu na raporty (poza zrodlami)'
    }
    $result=Invoke-AmdDiagnostics -GamePath $GamePath -AdditionalLogPaths $AdditionalLogPaths -OutputDirectory $OutputDirectory
    Write-Host ('Status: '+$result.status+'; kod: '+$result.exitCode)
    if($result.reportPath){Write-Host (Protect-AmdText ('Raport: '+$result.reportPath))}
    if($result.zipPath){Write-Host (Protect-AmdText ('ZIP: '+$result.zipPath))}
    if($result.error){Write-Host $result.error}
    exit $result.exitCode
}
