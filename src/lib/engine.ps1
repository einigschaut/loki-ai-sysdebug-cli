# lib/engine.ps1 -- offline engine acquisition + the MSVC runtime it needs (security core, CLAUDE.md section 5, ADR-0012).
# `loki setup` uses this on the machine where the stick is prepared. Unlike a model (data we only ever read), the engine
# archive is CODE the target machine will execute, so the bar is higher:
#   * the archive is verified against the pinned SHA256 BEFORE it is expanded -- an unverified archive is never opened.
#   * every entry name is validated BEFORE anything is written (zip-slip / traversal / ADS / drive-qualified) and a
#     single bad entry aborts the whole expansion -- we never half-extract and then notice.
#   * the verified archive is KEPT next to the expanded files: it is the chain back to the pinned hash, so the harness
#     slice can re-verify at load time instead of trusting whatever is on the stick (ADR-0012).
#   * nothing here executes the engine. Starting llama-server is the harness slice's job.
# The MSVC runtime (VCRUNTIME140/_1, MSVCP140) is NOT part of Windows and NOT in the archive. Loki must not ship it --
# Microsoft limits distribution of those binaries to licensed Visual Studio users. So staging is an explicit,
# opt-in operator action (`--stage-runtime`) that copies the files from the operator's OWN machine to their OWN stick.
# Contract:
#   Get-LokiEngineManifest -Path <psd1> -> [hashtable]{ Engine; Runtime }  (throws fail-closed on any bad field).
#   Get-LokiEngineLayout -AppRoot <dir> -Engine <manifest.Engine> -> [hashtable]{ Dir; ArchivePath; ServerExePath }
#       (pure; touches no disk).
#   Test-LokiArchiveEntrySafe -EntryName <string> -> [bool]  (pure predicate; the zip-slip gate).
#   ConvertTo-LokiRuntimeVersion -Text <string> -> [version] or $null  (pure; parses '14.51.36247.0' / 'v14.51.36247.00';
#       $null -- never a throw -- on anything unparsable, so callers can fail closed).
#   Get-LokiEngineExpectedSet -EntryNames <string[]> -ArchiveFileName <string> [-PreserveNames <string[]>]
#       -> [HashSet[string]] (OrdinalIgnoreCase) the relative paths that may legitimately live in engine-offline\.
#       Pure. ONE definition, shared by the expand (what to prune) and lib/integrity.ps1 (what is unexpected).
#   Expand-LokiVerifiedArchive -ArchivePath -DestDir -ExpectedSha256 [-PreserveNames <string[]>]
#       -> [hashtable]{ Ok; Reason; [Count]; [Pruned]; [Entry]; [Error] }
#       verifies before opening; reconciles $DestDir against the archive ($PreserveNames survive the prune);
#       on ANY failure $DestDir is left as it was.
#   Get-LokiVcRuntimeStatus -Directory <dir> -Files <string[]> -> [hashtable]{ Present; Found; Missing }
#       PRESENCE only -- it does not judge versions; pair it with Get-LokiVcRuntimeFloorCheck.
#   Get-LokiVcRuntimeFloorCheck -Found <entries> -MinVersion <string> -> [hashtable]{ Ok; Reason; [Version]; [File] }
#       the MinVersion floor, in one place, used by BOTH the staging and the reporting path.
#   Copy-LokiVcRuntimeAppLocal -SourceDir -DestDir -Files -MinVersion -> [hashtable]{ Ok; Reason; [Staged]; [Version]; [Missing]; [File] }
#       fail-closed + rolled back: on any failure nothing is staged.
# ASCII-only file -> no BOM (CLAUDE.md section 1).
Set-StrictMode -Version Latest

$script:LokiEngineRequiredKeys = @('Id', 'Version', 'Platform', 'License', 'Url', 'FileName', 'Sha256', 'SizeBytes', 'ServerExe')
$script:LokiEngineRuntimeKeys = @('Files', 'MinVersion', 'RegistryKey')

function Get-LokiEngineManifest {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Engine manifest not found: $Path" }
    $data = Import-PowerShellDataFile -LiteralPath $Path
    if (($null -eq $data) -or (-not $data.ContainsKey('Engine'))) { throw "Engine manifest malformed: missing 'Engine'." }
    if (-not $data.ContainsKey('Runtime')) { throw "Engine manifest malformed: missing 'Runtime'." }

    $e = $data.Engine
    foreach ($k in $script:LokiEngineRequiredKeys) {
        if (-not $e.ContainsKey($k)) { throw "Engine manifest is missing key '$k'." }
    }
    if ([string]$e.Url -notmatch '^https://') { throw 'Engine: Url must be https.' }
    if ([string]$e.Sha256 -notmatch '^[0-9a-fA-F]{64}$') { throw 'Engine: Sha256 must be 64 hex chars.' }
    if ([long]$e.SizeBytes -le 0) { throw 'Engine: SizeBytes must be a positive integer.' }
    foreach ($nameKey in @('FileName', 'ServerExe')) {
        # Same rule as the model manifest: the value is trusted-but-validated (defense in depth) -- safe charset,
        # no separators, not an all-dots name and not a reserved device name.
        $fn = [string]$e.$nameKey
        # -cnotmatch, not -notmatch: PowerShell's case-INSENSITIVE match folds using the CURRENT CULTURE, and in
        # tr-TR/az 'I' folds to the dotless 'i' (U+0131), which is not in [A-Za-z]. A Turkish-locale machine would
        # reject our own pinned 'VCRUNTIME140.dll' / 'Qwen3-4B-Instruct-...gguf' as unsafe -- reported to the
        # operator as a corrupt manifest on a pristine stick. The classes here are already explicitly cased, so a
        # case-sensitive match is both correct and culture-proof.
        if ($fn -cnotmatch '^[A-Za-z0-9._-]+$') { throw "Engine: $nameKey has unsafe characters." }
        $fnBase = (($fn.ToUpperInvariant()) -split '\.')[0]
        if (($fn -match '^\.+$') -or ($fnBase -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$')) { throw "Engine: $nameKey is a reserved or invalid name." }
    }

    $r = $data.Runtime
    foreach ($k in $script:LokiEngineRuntimeKeys) {
        if (-not $r.ContainsKey($k)) { throw "Engine manifest Runtime is missing key '$k'." }
    }
    $rtFiles = @($r.Files)
    if ($rtFiles.Count -eq 0) { throw 'Engine Runtime: Files must not be empty.' }
    foreach ($f in $rtFiles) {
        # Same tr-TR problem as above ('VCRUNTIME140.dll' has an uppercase I) -- but NOT -cnotmatch here, because
        # unlike the charset-only pattern above this one ends in a case-SPECIFIC literal: a case-sensitive match also
        # starts rejecting 'MSVCP140.DLL', which the check accepted before and which is a perfectly valid spelling.
        # Fixing the locale bug must not quietly tighten an unrelated rule, so keep IgnoreCase and drop the culture.
        if (-not [regex]::IsMatch([string]$f, '^[A-Za-z0-9._-]+\.dll$', 'IgnoreCase,CultureInvariant')) {
            throw "Engine Runtime: '$f' is not a plain dll file name."
        }
    }
    if ($null -eq (ConvertTo-LokiRuntimeVersion -Text ([string]$r.MinVersion))) { throw 'Engine Runtime: MinVersion is not a version.' }

    return $data
}

function Get-LokiEngineLayout {
    # Pure path math -- the engine lives in engine-offline\ on the stick (DESIGN.md section 2.2).
    param([Parameter(Mandatory = $true)][string]$AppRoot, [Parameter(Mandatory = $true)]$Engine)
    $dir = Join-Path $AppRoot 'engine-offline'
    return @{
        Dir           = $dir
        ArchivePath   = (Join-Path $dir ([string]$Engine.FileName))
        ServerExePath = (Join-Path $dir ([string]$Engine.ServerExe))
    }
}

function Test-LokiArchiveEntrySafe {
    # The zip-slip gate: does this archive entry name stay inside the destination directory?
    # Pure + table-tested. Rejects: empty, rooted, traversal, drive-qualified/ADS (':'), wildcards, control chars.
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$EntryName)
    if ([string]::IsNullOrWhiteSpace($EntryName)) { return $false }
    $n = $EntryName -replace '\\', '/'
    if ($n -match '^/') { return $false }                 # rooted / UNC
    if ($n -match '[:*?"<>|]') { return $false }          # drive-qualified, alternate data stream, wildcards
    if ($n -match '[\x00-\x1F]') { return $false }        # control characters
    if ($n -match '(^|/)\.\.(/|$)') { return $false }     # parent traversal
    foreach ($seg in ($n -split '/')) {
        if ([string]::IsNullOrWhiteSpace($seg)) { return $false }          # empty segment ('a//b')
        if ($seg -match '[ .]$') { return $false }                        # trailing dot/space -- Win32 strips these,
        # so two normalizers can disagree about what the name even is
        $base = ($seg.ToUpperInvariant() -split '\.')[0]
        # A device name is not a file: extracting to it hits \\.\NUL and fails mid-tree. Same rule the manifest
        # already applies to FileName/ServerExe -- the entry gate had been missing it.
        if ($base -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') { return $false }
    }
    return $true
}

function ConvertTo-LokiRuntimeVersion {
    # Parses the assorted shapes Windows reports: '14.51.36247.0' (file version), 'v14.51.36247.00' (registry),
    # '14.51.36247.0 built by: ...'. Returns $null when there is no version in the text (caller decides = fail-closed).
    param([Parameter(Mandatory = $true)][AllowEmptyString()][AllowNull()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $m = [regex]::Match([string]$Text, '(\d+)\.(\d+)(?:\.(\d+))?(?:\.(\d+))?')
    if (-not $m.Success) { return $null }
    $parts = New-Object System.Collections.Generic.List[int]
    for ($i = 1; $i -le 4; $i++) {
        if ($m.Groups[$i].Success) {
            # Parse via [long] and range-check: a plain [int] cast THROWS on a component > int.MaxValue, and this
            # function's contract is to return $null on anything unparsable so the caller can fail closed. An
            # exception escaping here would bypass that contract entirely.
            $n = 0L
            if (-not [long]::TryParse($m.Groups[$i].Value, [ref]$n)) { return $null }
            if (($n -lt 0) -or ($n -gt [int]::MaxValue)) { return $null }
            $parts.Add([int]$n)
        }
    }
    while ($parts.Count -lt 2) { $parts.Add(0) }
    return (New-Object System.Version -ArgumentList ($parts.ToArray()))
}

function Get-LokiEngineExpectedSet {
    <#
        The relative paths that may legitimately exist in engine-offline\: everything the pinned archive produces,
        plus the verified archive itself (the chain back to the pin) and the operator-staged Microsoft runtime.

        This is ONE definition on purpose (CLAUDE.md section 2). The expand uses it to decide what to PRUNE and the
        load-time verify uses it to decide what is UNEXPECTED -- the same question asked twice. Were they allowed to
        drift, `loki setup` would delete a file `loki doctor` calls fine, or bless one setup removes.

        Pure and table-tested: it takes entry NAMES, not a live ZipArchive, so the interesting rules (a directory
        entry produces no file; Windows paths compare case-insensitively) are testable without a zip on disk.
    #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$EntryNames,
        [Parameter(Mandatory = $true)][string]$ArchiveFileName,
        [string[]]$PreserveNames = @()
    )
    $set = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    foreach ($n in $EntryNames) {
        if ([string]::IsNullOrWhiteSpace($n)) { continue }
        # A directory entry ('bin/') creates no file, so it must not become an expected FILE path. This mirrors
        # ZipArchiveEntry.Name being empty for exactly those entries.
        if ($n -match '[\\/]$') { continue }
        [void]$set.Add(($n -replace '/', '\'))
    }
    [void]$set.Add($ArchiveFileName)
    foreach ($p in $PreserveNames) {
        if (-not [string]::IsNullOrWhiteSpace([string]$p)) { [void]$set.Add([string]$p) }
    }
    # Leading comma: a HashSet is IEnumerable, so PowerShell would otherwise unroll it into loose strings and the
    # caller would get an object[] with no .Contains(). (return $set is the bug; return , $set is the fix.)
    return , $set
}

function Expand-LokiVerifiedArchive {
    <#
        Expand the pinned archive into $DestDir and RECONCILE $DestDir against it.

        Reconciling is the point, not a bonus. Overwriting only the names the archive happens to contain would leave
        anything else in place: a planted ggml-cpu-<arch>.dll survives the very `loki setup` the operator ran to repair
        a suspect stick, and sits in llama-server.exe's own directory -- first in the Windows DLL search order, and
        exactly where ggml-base.dll picks CPU variants BY NAME. Verifying the archive can never detect that, because the
        planted file is not in the archive. The same hole would otherwise make a pin bump useless: files from the
        previous build (including the very binary the bump removes) would linger and still be loadable.

        $PreserveNames are the files that legitimately live next to the engine but are NOT in the archive -- the
        operator-staged Microsoft runtime. Without them the prune would silently delete the staged runtime.

        The new tree is built COMPLETELY in a sibling directory and swapped in by two directory renames. That is what
        makes "on any failure $DestDir is as it was" a mechanism rather than a promise: an earlier version pruned the
        destination and then moved files in one at a time, so a failure in between left a tree that was both pruned and
        half-populated -- worse than doing nothing. Renaming a directory also fails cleanly and atomically when any
        file inside is locked (llama-server running from the stick), instead of failing halfway.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$DestDir,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256,
        [string[]]$PreserveNames = @()
    )
    # Function-scoped (does not leak to the caller, does not depend on them): Copy-Item / Move-Item / Remove-Item
    # failures are NON-terminating by default, so without this the catch below never fires and this function reports
    # Ok=$true 'expanded' over a tree it never actually wrote. Reproduced by adversarial review, not theoretical.
    $ErrorActionPreference = 'Stop'

    # Never open an archive we have not verified -- the pinned hash is the only reason we trust its contents.
    if (-not (Test-LokiFileHash -Path $ArchivePath -ExpectedSha256 $ExpectedSha256)) {
        return @{ Ok = $false; Reason = 'archive-unverified' }
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    if (-not (Test-Path -LiteralPath $DestDir)) { New-Item -ItemType Directory -Force -Path $DestDir | Out-Null }
    $destFull = (Resolve-Path -LiteralPath $DestDir).ProviderPath
    $suffix = [System.Guid]::NewGuid().ToString('N')
    $staging = $destFull + '.new-' + $suffix       # sibling, same volume -> the swap is a rename, not a copy
    $retired = $destFull + '.old-' + $suffix

    $zip = $null
    $swapped = $false
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)

        # Validate EVERY entry before writing ANYTHING: one hostile name aborts the whole expansion.
        foreach ($entry in $zip.Entries) {
            if (-not (Test-LokiArchiveEntrySafe -EntryName ([string]$entry.FullName))) {
                return @{ Ok = $false; Reason = 'unsafe-entry'; Entry = [string]$entry.FullName }
            }
        }

        New-Item -ItemType Directory -Force -Path $staging | Out-Null

        # What may legitimately end up in $DestDir -- archive contents + the archive itself + the preserved runtime.
        # Shared with the load-time verify so the two can never disagree (Get-LokiEngineExpectedSet).
        $keep = Get-LokiEngineExpectedSet -EntryNames @($zip.Entries | ForEach-Object { [string]$_.FullName }) `
            -ArchiveFileName (Split-Path -Leaf $ArchivePath) -PreserveNames $PreserveNames
        $count = 0
        foreach ($entry in $zip.Entries) {
            $rel = ([string]$entry.FullName) -replace '/', '\'
            $target = Join-Path $staging $rel
            if ([string]::IsNullOrEmpty([string]$entry.Name)) {
                if (-not (Test-Path -LiteralPath $target)) { New-Item -ItemType Directory -Force -Path $target | Out-Null }
                continue
            }
            $parent = Split-Path -Parent $target
            if (-not [string]::IsNullOrEmpty($parent) -and -not (Test-Path -LiteralPath $parent)) {
                New-Item -ItemType Directory -Force -Path $parent | Out-Null
            }
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
            $count++
        }

        # Release the archive BEFORE the swap: we still hold it open, and the rename of a directory containing an
        # open file fails.
        $zip.Dispose()
        $zip = $null

        # Carry over what legitimately lives next to the engine but is NOT in the archive: the verified archive itself
        # (it is the chain back to the pin) and the caller's preserved names (the operator-staged Microsoft runtime).
        # Copy, never move: until the swap succeeds, $DestDir must remain exactly as it was. ($keep already contains
        # these names -- Get-LokiEngineExpectedSet put them there; this list is only what to physically carry over.)
        $carry = New-Object System.Collections.Generic.List[string]
        $carry.Add((Split-Path -Leaf $ArchivePath))
        foreach ($n in $PreserveNames) {
            if (-not [string]::IsNullOrWhiteSpace([string]$n)) { $carry.Add([string]$n) }
        }
        foreach ($n in $carry) {
            $from = Join-Path $destFull $n
            if (Test-Path -LiteralPath $from) { Copy-Item -LiteralPath $from -Destination (Join-Path $staging $n) -Force }
        }

        # Anything in the old tree the pinned archive does not account for is dropped by the swap -- count it so the
        # operator is told rather than left guessing.
        $pruned = 0
        foreach ($f in @(Get-ChildItem -LiteralPath $destFull -Recurse -Force -File)) {
            $rel = $f.FullName.Substring($destFull.Length).TrimStart('\')
            if (-not $keep.Contains($rel)) { $pruned++ }
        }

        # The swap. Between these two renames $DestDir does not exist; the restore in the catch puts it back.
        Move-Item -LiteralPath $destFull -Destination $retired -Force
        $swapped = $true
        Move-Item -LiteralPath $staging -Destination $destFull -Force
        $swapped = $false

        Remove-Item -LiteralPath $retired -Recurse -Force -ErrorAction SilentlyContinue
        return @{ Ok = $true; Reason = 'expanded'; Count = $count; Pruned = $pruned }
    }
    catch {
        # Put the original tree back if we died between the two renames.
        if ($swapped -and (Test-Path -LiteralPath $retired) -and -not (Test-Path -LiteralPath $destFull)) {
            Move-Item -LiteralPath $retired -Destination $destFull -Force -ErrorAction SilentlyContinue
        }
        return @{ Ok = $false; Reason = 'expand-failed'; Error = $_.Exception.Message }
    }
    finally {
        if ($null -ne $zip) { $zip.Dispose() }
        foreach ($leftover in @($staging, $retired)) {
            if (Test-Path -LiteralPath $leftover) { Remove-Item -LiteralPath $leftover -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
}

function Get-LokiVcRuntimeStatus {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string[]]$Files
    )
    $found = New-Object System.Collections.Generic.List[object]
    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($f in $Files) {
        $p = Join-Path $Directory $f
        if (Test-Path -LiteralPath $p) {
            $ver = $null
            try { $ver = [string](Get-Item -LiteralPath $p).VersionInfo.FileVersion } catch { $ver = $null }
            $found.Add([pscustomobject]@{ File = [string]$f; Path = $p; Version = $ver })
        }
        else {
            $missing.Add([string]$f)
        }
    }
    # No leading comma here: a hashtable value is not pipeline-unwrapped, so ", $x" would nest the array inside
    # another array (@(@(...))) and every caller's .Count / -Contains would silently read the wrong thing.
    return @{
        Present = ($missing.Count -eq 0)
        Found   = $found.ToArray()
        Missing = $missing.ToArray()
    }
}

function Get-LokiVcRuntimeFloorCheck {
    <#
        The MinVersion floor, in ONE place. Both the staging path (Copy-LokiVcRuntimeAppLocal) and the reporting path
        (`loki setup` without --stage-runtime) must apply the identical rule -- otherwise setup refuses a 14.0 runtime
        when asked to stage it, but reports the same 14.0 runtime already sitting on the stick as fine, which is the
        cryptic target-side loader failure the floor exists to prevent.
        The WEAKEST file decides: a set where one dll is ancient is exactly the silent failure we refuse.
    #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()]$Found,
        [Parameter(Mandatory = $true)][string]$MinVersion
    )
    $min = ConvertTo-LokiRuntimeVersion -Text $MinVersion
    if ($null -eq $min) { return @{ Ok = $false; Reason = 'min-version-invalid' } }

    $lowest = $null
    foreach ($f in @($Found)) {
        $v = ConvertTo-LokiRuntimeVersion -Text ([string]$f.Version)
        if ($null -eq $v) { return @{ Ok = $false; Reason = 'version-unreadable'; File = [string]$f.File } }
        if (($null -eq $lowest) -or ($v -lt $lowest)) { $lowest = $v }
    }
    if ($null -eq $lowest) { return @{ Ok = $false; Reason = 'no-files' } }
    if ($lowest -lt $min) {
        return @{ Ok = $false; Reason = 'too-old'; Version = $lowest.ToString(); MinVersion = $min.ToString() }
    }
    return @{ Ok = $true; Reason = 'ok'; Version = $lowest.ToString() }
}

function Copy-LokiVcRuntimeAppLocal {
    <#
        Stage the Microsoft C/C++ runtime app-local next to the engine. Loki does not ship these files: the operator
        copies them from their own machine (SourceDir is System32, chosen by the caller -- never user input) onto their
        own stick. Fail-closed in this order: a file missing at the source, an unreadable version, or a version below
        MinVersion all abort WITHOUT copying anything. Rationale for the floor: Microsoft guarantees the redistributable
        is binary compatible back to 2015 going forward, so a newer runtime is always safe -- an older one can be
        missing exports the engine imports, which would surface as an unexplainable loader failure on the target.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$SourceDir,
        [Parameter(Mandatory = $true)][string]$DestDir,
        [Parameter(Mandatory = $true)][string[]]$Files,
        [Parameter(Mandatory = $true)][string]$MinVersion
    )
    # Function-scoped: without it Copy-Item / Move-Item failures are non-terminating, the catch blocks never fire, and
    # this returns Ok=$true 'staged' over files it never wrote (reproduced by adversarial review).
    $ErrorActionPreference = 'Stop'

    $status = Get-LokiVcRuntimeStatus -Directory $SourceDir -Files $Files
    if (-not $status.Present) {
        return @{ Ok = $false; Reason = 'source-missing'; Missing = @($status.Missing) }
    }

    $floor = Get-LokiVcRuntimeFloorCheck -Found $status.Found -MinVersion $MinVersion
    if (-not $floor.Ok) { return $floor }

    if (-not (Test-Path -LiteralPath $DestDir)) { New-Item -ItemType Directory -Force -Path $DestDir | Out-Null }

    # Pre-flight: an existing target that cannot be opened for writing (classic case: llama-server.exe is running from
    # the stick, so the loaded dll is locked) must abort BEFORE the first copy, not halfway through.
    foreach ($f in $status.Found) {
        $target = Join-Path $DestDir ([string]$f.File)
        if (Test-Path -LiteralPath $target) {
            try {
                $probe = [System.IO.File]::Open($target, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                $probe.Close()
            }
            catch {
                return @{ Ok = $false; Reason = 'dest-locked'; File = [string]$f.File }
            }
        }
    }

    # Copy every file to a .staging name FIRST, then move them all into place. A failure partway through must leave the
    # destination as it was -- a half-staged runtime (new VCRUNTIME140, stale MSVCP140) is the mixed set we refuse.
    $pending = New-Object System.Collections.Generic.List[object]
    try {
        foreach ($f in $status.Found) {
            $target = Join-Path $DestDir ([string]$f.File)
            $tmp = $target + '.staging'
            Copy-Item -LiteralPath ([string]$f.Path) -Destination $tmp -Force
            $pending.Add([pscustomobject]@{ Tmp = $tmp; Target = $target; File = [string]$f.File })
        }
    }
    catch {
        foreach ($p in $pending) { Remove-Item -LiteralPath $p.Tmp -Force -ErrorAction SilentlyContinue }
        return @{ Ok = $false; Reason = 'copy-failed'; Error = $_.Exception.Message }
    }

    # Move each staged copy into place, remembering what it displaced. A failure partway through must UN-DO the moves
    # that already landed -- otherwise the destination holds a new VCRUNTIME140 next to a stale MSVCP140, which is
    # exactly the mixed set this function exists to refuse. (The pre-flight above makes this rare, not impossible: it
    # is a check, not a lock.)
    $staged = New-Object System.Collections.Generic.List[string]
    $done = New-Object System.Collections.Generic.List[object]
    foreach ($p in $pending) {
        $backup = $null
        try {
            if (Test-Path -LiteralPath $p.Target) {
                $backup = $p.Target + '.bak'
                Move-Item -LiteralPath $p.Target -Destination $backup -Force
            }
            Move-Item -LiteralPath $p.Tmp -Destination $p.Target -Force
            $done.Add([pscustomobject]@{ Target = $p.Target; Backup = $backup })
            $staged.Add([string]$p.File)
        }
        catch {
            # Roll back: restore this file, then every file we had already replaced.
            if (($null -ne $backup) -and (Test-Path -LiteralPath $backup)) {
                Move-Item -LiteralPath $backup -Destination $p.Target -Force -ErrorAction SilentlyContinue
            }
            foreach ($d in $done) {
                if ($null -ne $d.Backup) { Move-Item -LiteralPath $d.Backup -Destination $d.Target -Force -ErrorAction SilentlyContinue }
                else { Remove-Item -LiteralPath $d.Target -Force -ErrorAction SilentlyContinue }
            }
            foreach ($q in $pending) { Remove-Item -LiteralPath $q.Tmp -Force -ErrorAction SilentlyContinue }
            return @{ Ok = $false; Reason = 'copy-failed'; File = [string]$p.File; Error = $_.Exception.Message }
        }
    }
    # Committed -- drop the displaced originals.
    foreach ($d in $done) {
        if ($null -ne $d.Backup) { Remove-Item -LiteralPath $d.Backup -Force -ErrorAction SilentlyContinue }
    }
    return @{ Ok = $true; Reason = 'staged'; Staged = $staged.ToArray(); Version = [string]$floor.Version }
}
