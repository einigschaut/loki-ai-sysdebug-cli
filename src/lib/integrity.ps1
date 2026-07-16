# lib/integrity.ps1 -- load-time verification of the offline engine and its models (security core, CLAUDE.md
# section 5; DESIGN.md section 2.2 names `integrity` as its own lib; ADR-0012 requires this slice by name).
#
# WHY THIS EXISTS. ADR-0011/0012 verify the model and the engine archive at DOWNLOAD time, on the operator's own
# machine. That chain ends the moment `loki setup` finishes. Everything afterwards -- the stick in a drawer, in a
# pocket, plugged into the very machine we are there to diagnose because something is wrong with it -- is unverified.
# The engine is CODE the target executes, so trusting whatever currently sits on the stick is exactly the assumption
# an integrity check exists to remove.
#
# THE CHAIN, and why checking the archive is not enough. The manifest pins the ARCHIVE's hash, not the individual
# files, so `archive matches the pin` says nothing whatsoever about the llama-server.exe sitting next to it -- an
# attacker replaces the exe, not the zip nobody runs. The archive is only the ROOT of the chain: it is verified
# against the manifest, and then every expanded file is verified against ITS OWN entry inside that verified archive.
# That is what ties the bytes Windows will actually load back to the pinned hash.
#
# And the chain still has a hole the hashes cannot see: a file the archive does not contain. A planted
# ggml-cpu-<arch>.dll is never `mismatched` -- there is nothing to compare it against -- yet it sits in
# llama-server.exe's own directory, first in the Windows DLL search order, exactly where ggml-base.dll picks CPU
# variants BY NAME. So verification RECONCILES, the same way the expand does (ADR-0012 section 2b), and against the
# same one definition of what may be there (Get-LokiEngineExpectedSet).
#
# Contract:
#   Get-LokiZipEntryHash -Entry <ZipArchiveEntry> -> [string] SHA256 hex (uppercase), computed from the entry stream.
#   Test-LokiEngineIntegrity -Layout <layout> -Engine <manifest entry> [-PreserveNames <string[]>]
#       -> [hashtable]{ Ok; Reason; ... } Reason is a stable machine token, never localized (same convention as
#       lib/allowlist.ps1): engine-not-installed | archive-missing | archive-mismatch | archive-unreadable |
#       unsafe-entry | file-mismatch | unexpected-file | file-unreadable | file-missing | nothing-verified |
#       verify-failed | verified.
#       On the 'verified'/'file-*'/'unexpected-file' paths it also carries
#       Checked/Mismatched/Unexpected/Missing/Unreadable.
#       The *-unreadable tokens are NOT a flavour of mismatch: they say we could not read the bytes, which on a USB
#       stick usually means the medium is failing, not that anyone touched it. They can never report as OK.
#   Get-LokiVcRuntimeHostStatus -RegistryKey <string> -MinVersion <string> -> [hashtable]{ Ok; Reason; [Version] }
#       Is the MSVC runtime installed on the TARGET, system-wide, at or above the floor? Never throws.
#   Resolve-LokiVcRuntimeAvailability -Directory -Files -MinVersion -RegistryKey -> [hashtable]{ Ok; Reason; Source }
#       The one answer to `will llama-server find a good enough runtime here`, app-local and host in ONE place.
#   Test-LokiModelIntegrity -Entry <manifest entry> -ModelsDir <dir> -> [hashtable]{ Ok; Reason; Id; [Path] }
#       not-installed | mismatch | unreadable | verified.
#   Get-LokiEngineReport -AppRoot -Engine -Runtime -Models -> [hashtable] the impure gatherer (probes disk+registry).
#   ConvertTo-LokiIntegrityChecks -Report -> [object[]] doctor check objects (PURE; same shape as lib/posture.ps1).
#
# ASCII-only file -> no BOM (CLAUDE.md section 1).
Set-StrictMode -Version Latest

function Get-LokiZipEntryHash {
    param([Parameter(Mandatory = $true)]$Entry)
    $sha = $null
    $stream = $null
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $stream = $Entry.Open()
        $bytes = $sha.ComputeHash($stream)
        return ([System.BitConverter]::ToString($bytes) -replace '-', '')
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if ($null -ne $sha) { $sha.Dispose() }
    }
}

function Test-LokiEngineIntegrity {
    <#
        Verify engine-offline\ against the pinned archive: archive -> pin, every expanded file -> its archive entry,
        and nothing present that the archive does not account for.

        Read-only by construction: it opens the zip for reading and hashes files. It never repairs -- repairing is
        `loki setup` (which reconciles). A checker that also writes cannot be run on a stick you distrust.
    #>
    param(
        [Parameter(Mandatory = $true)]$Layout,
        [Parameter(Mandatory = $true)]$Engine,
        [string[]]$PreserveNames = @()
    )
    # Function-scoped (CLAUDE.md/ADR-0012 section 4b): Get-ChildItem/Get-Item failures are non-terminating by default,
    # so without this the catch below never fires and a directory we could not even ENUMERATE would be reported as
    # having no unexpected files -- a fail-open in the one function whose whole job is to fail closed.
    $ErrorActionPreference = 'Stop'

    if (-not (Test-Path -LiteralPath $Layout.Dir)) { return @{ Ok = $false; Reason = 'engine-not-installed' } }
    if (-not (Test-Path -LiteralPath $Layout.ArchivePath -PathType Leaf)) { return @{ Ok = $false; Reason = 'archive-missing' } }
    # The root of the chain. Everything below is only as trustworthy as this line -- which is exactly why it must not
    # say more than it knows: a bool here reported an archive we could not READ as an archive that did not MATCH, i.e.
    # a failing USB stick was told its engine had been tampered with. Absent / unreadable / different are three
    # different answers and the operator needs the right one.
    $archiveState = Get-LokiFileHashState -Path $Layout.ArchivePath -ExpectedSha256 ([string]$Engine.Sha256)
    if ($archiveState -eq 'unreadable') { return @{ Ok = $false; Reason = 'archive-unreadable' } }
    # Deleted between the Test-Path above and this line. Vanishingly rare, but it is 'gone', not 'wrong'.
    if ($archiveState -eq 'missing') { return @{ Ok = $false; Reason = 'archive-missing' } }
    if ($archiveState -ne 'match') { return @{ Ok = $false; Reason = 'archive-mismatch' } }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = $null
    try {
        $dirFull = (Resolve-Path -LiteralPath $Layout.Dir).ProviderPath
        $zip = [System.IO.Compression.ZipFile]::OpenRead($Layout.ArchivePath)

        # Same gate as the expand, for the same reason: a hash-verified archive can still carry a hostile entry name,
        # and we are about to Join-Path those names onto a real directory. Verified != safe to interpret.
        foreach ($entry in $zip.Entries) {
            if (-not (Test-LokiArchiveEntrySafe -EntryName ([string]$entry.FullName))) {
                return @{ Ok = $false; Reason = 'unsafe-entry'; Entry = [string]$entry.FullName }
            }
        }

        $expected = Get-LokiEngineExpectedSet -EntryNames @($zip.Entries | ForEach-Object { [string]$_.FullName }) `
            -ArchiveFileName (Split-Path -Leaf $Layout.ArchivePath) -PreserveNames $PreserveNames

        $checked = 0
        $missing = New-Object System.Collections.Generic.List[string]
        $mismatched = New-Object System.Collections.Generic.List[string]
        $unreadable = New-Object System.Collections.Generic.List[string]
        foreach ($entry in $zip.Entries) {
            if ([string]::IsNullOrEmpty([string]$entry.Name)) { continue }   # directory entry -- produces no file
            $rel = ([string]$entry.FullName) -replace '/', '\'
            $onDisk = Join-Path $dirFull $rel
            # Compare the bytes on disk against the bytes INSIDE the verified archive -- not against each other.
            # $checked counts only PROVEN files: an unreadable one must never be able to satisfy the "we actually
            # verified something" floor below.
            $state = Get-LokiFileHashState -Path $onDisk -ExpectedSha256 (Get-LokiZipEntryHash -Entry $entry)
            if ($state -eq 'missing') { $missing.Add($rel); continue }
            if ($state -eq 'unreadable') { $unreadable.Add($rel); continue }
            if ($state -ne 'match') { $mismatched.Add($rel); continue }
            $checked++
        }
        $zip.Dispose()
        $zip = $null

        # The reconcile: anything the pinned archive does not account for. This is the check the hashes structurally
        # cannot do, and the one that catches a planted DLL.
        $unexpected = New-Object System.Collections.Generic.List[string]
        foreach ($f in @(Get-ChildItem -LiteralPath $dirFull -Recurse -Force)) {
            $rel = $f.FullName.Substring($dirFull.Length).TrimStart('\')
            if ($f.PSIsContainer) {
                # A DIRECTORY reparse point (junction or directory symlink, neither needing admin to create) is where
                # this enumeration STOPS: Get-ChildItem -Recurse does not descend into one under PS 5.1, so anything
                # behind it is invisible and would be silently reported as `verified`. The pinned archive never
                # produces a reparse point, so its mere presence is unambiguous -- report the link itself rather than
                # pretend to analyse where it points. Plain directories are skipped: a directory holds no loadable
                # code by itself and its files are enumerated on their own.
                if (($f.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq [System.IO.FileAttributes]::ReparsePoint) {
                    $unexpected.Add($rel)
                }
                continue
            }
            # NOTE: a FILE reparse point is deliberately NOT flagged here. Hashing follows the link, which is exactly
            # what loading does, so a swapped target is caught as file-mismatch -- and flagging every file reparse
            # point would false-alarm on a tree under OneDrive Files On-Demand, whose placeholders are reparse points.
            if (-not $expected.Contains($rel)) { $unexpected.Add($rel) }
        }

        # No leading commas in a hashtable literal: values are not pipeline-unwrapped there, so ", $x" would nest the
        # array (@(@(...))) and every caller's .Count would read 1.
        $detail = @{
            Checked    = $checked
            Mismatched = $mismatched.ToArray()
            Unexpected = $unexpected.ToArray()
            Missing    = $missing.ToArray()
            Unreadable = $unreadable.ToArray()
        }
        # Most alarming first: altered bytes, then a planted file, then what we could not read, then a merely broken
        # install. The order is a safety property, not a preference -- 'unreadable' is the only reason here that means
        # "unknown", and it is the ONE thing an attacker could aim for: making a file unreadable turns a would-be
        # file-mismatch(1) into an unknown(5). It must therefore never be able to mask a POSITIVE finding, so both
        # findings that indict the stick are tested before it. What it may outrank is file-missing, which is merely
        # the other half of the same broken-install answer.
        if ($mismatched.Count -gt 0) { return ($detail + @{ Ok = $false; Reason = 'file-mismatch' }) }
        if ($unexpected.Count -gt 0) { return ($detail + @{ Ok = $false; Reason = 'unexpected-file' }) }
        if ($unreadable.Count -gt 0) { return ($detail + @{ Ok = $false; Reason = 'file-unreadable' }) }
        if ($missing.Count -gt 0) { return ($detail + @{ Ok = $false; Reason = 'file-missing' }) }
        # A pinned archive cannot really be empty -- but "we verified nothing and therefore found nothing wrong" is
        # the shape of every vacuous pass, so it is refused explicitly rather than left to the pin to prevent.
        if ($checked -eq 0) { return @{ Ok = $false; Reason = 'nothing-verified' } }
        return ($detail + @{ Ok = $true; Reason = 'verified' })
    }
    catch {
        return @{ Ok = $false; Reason = 'verify-failed'; Error = $_.Exception.Message }
    }
    finally {
        if ($null -ne $zip) { $zip.Dispose() }
    }
}

function Get-LokiVcRuntimeHostStatus {
    <#
        Does the TARGET have the MSVC runtime installed system-wide, at or above the floor?

        WOW64, again (ADR-0012 section 3b, now in the registry): from a 32-bit process HKLM:\SOFTWARE\... is silently
        redirected to HKLM:\SOFTWARE\Wow6432Node\..., where the x64 runtime does NOT register. A 32-bit PowerShell
        would therefore report a perfectly good x64 runtime as absent. Get-ItemProperty cannot express a view, so the
        64-bit view is opened explicitly through the .NET API.

        Never throws: a probe that cannot read fails CLOSED (Ok=$false), it does not take the caller down with it.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$RegistryKey,
        [Parameter(Mandatory = $true)][string]$MinVersion
    )
    # Only the one hive we document. Anything else is a manifest error, not something to go hunting for.
    if ($RegistryKey -notmatch '^HKLM:\\(.+)$') { return @{ Ok = $false; Reason = 'registry-key-invalid' } }
    $subKey = $Matches[1]

    $base = $null
    $key = $null
    $version = $null
    $installed = $null
    try {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,
            [Microsoft.Win32.RegistryView]::Registry64)
        $key = $base.OpenSubKey($subKey)
        if ($null -eq $key) { return @{ Ok = $false; Reason = 'not-installed' } }
        $installed = $key.GetValue('Installed')
        $version = [string]$key.GetValue('Version')
    }
    catch {
        return @{ Ok = $false; Reason = 'registry-unreadable' }
    }
    finally {
        if ($null -ne $key) { $key.Dispose() }
        if ($null -ne $base) { $base.Dispose() }
    }

    # The installer writes Installed=1 as a REG_DWORD -- but this key is on a machine we do not control, and a
    # REG_BINARY / REG_MULTI_SZ / REG_SZ 'yes' there would make a bare [int] cast THROW, straight out through this
    # function's own "never throws" contract and up to the dispatcher. TryParse on the string form instead: the same
    # discipline ConvertTo-LokiRuntimeVersion already uses, for exactly this reason.
    $installedNum = 0
    if (($null -eq $installed) -or (-not [int]::TryParse([string]$installed, [ref]$installedNum)) -or ($installedNum -ne 1)) {
        return @{ Ok = $false; Reason = 'not-installed' }
    }

    $v = ConvertTo-LokiRuntimeVersion -Text $version
    if ($null -eq $v) { return @{ Ok = $false; Reason = 'version-unreadable' } }
    $min = ConvertTo-LokiRuntimeVersion -Text $MinVersion
    if ($null -eq $min) { return @{ Ok = $false; Reason = 'min-version-invalid' } }
    if ($v -lt $min) { return @{ Ok = $false; Reason = 'too-old'; Version = $v.ToString() } }
    return @{ Ok = $true; Reason = 'ok'; Version = $v.ToString() }
}

function Test-LokiMicrosoftSignature {
    <#
        Is this file genuinely a Microsoft-signed binary, byte-for-byte as Microsoft signed it?

        This is the ONLY integrity check available for the staged MSVC runtime, and it is needed because those three
        DLLs are the one blind spot in the hash chain: they are not in the pinned archive (nothing to compare them
        against) and -PreserveNames spares them from the reconcile, yet Windows loads them into llama-server from its
        own directory, FIRST in the DLL search order. An adversarial review demonstrated the consequence: 64 patched
        bytes in VCRUNTIME140.dll, engine reported `verified`, exit 0. The version resource -- the only thing that had
        been checked -- is attacker-controlled metadata sitting inside the very file being vetted, and it still read
        14.51 after the patch.

        A signature works here where a hash cannot, and it does NOT re-open ADR-0014's no-cache argument: the trust
        anchor is the TARGET's certificate store, not the stick, so "whoever can plant the DLL can fix the record"
        does not apply.

        Verified on the real files (2026-07-16), not recalled:
          * the three DLLs are EMBEDDED Authenticode signed (SignatureType=Authenticode), not catalog-signed, so the
            signature survives the copy onto the stick -- Status stays Valid on the copy. (kernel32.dll, by contrast,
            is Catalog-signed: it validates via the machine's catalog by hash, which a copy would NOT carry to a
            different target. That is why a catalog-signed source would be a trap, and why this is checked.)
          * a patched byte -> Status=HashMismatch, while VersionInfo.FileVersion still read 14.51.
          * the chain terminates at 'CN=Microsoft Root Certificate Authority 2011, O=Microsoft Corporation'.

        Status='Valid' alone is NOT enough and must not be mistaken for one: it means "signed by someone the machine
        trusts", which any attacker holding a public code-signing certificate also achieves. So the chain ROOT is
        pinned to Microsoft's own PKI.
    #>
    param([Parameter(Mandatory = $true)][string]$Path)
    $ErrorActionPreference = 'Stop'

    $sig = $null
    # -LiteralPath, NOT -FilePath: -FilePath is wildcard-expanding, and '[' / ']' are legal Windows filename
    # characters. A stick in a folder called 'loki [backup]' made this accuse three genuine Microsoft DLLs of being
    # forged -- the check meant to catch a patched runtime firing on an honest one because of a folder name.
    try { $sig = Get-AuthenticodeSignature -LiteralPath $Path }
    catch { return @{ Ok = $false; Reason = 'signature-unreadable' } }
    if ($null -eq $sig) { return @{ Ok = $false; Reason = 'signature-unreadable' } }

    $status = [string]$sig.Status
    if ($status -ne 'Valid') {
        $reason = 'signature-invalid'
        if ($status -eq 'NotSigned') { $reason = 'not-signed' }
        elseif ($status -eq 'HashMismatch') { $reason = 'hash-mismatch' }
        return @{ Ok = $false; Reason = $reason; Status = $status }
    }
    if ($null -eq $sig.SignerCertificate) { return @{ Ok = $false; Reason = 'not-signed' } }

    # Walk to the root ourselves. Revocation is deliberately NOT re-checked here: Get-AuthenticodeSignature's Valid
    # already covers trust, and Loki runs on machines with no network -- a CRL/OCSP fetch would stall the one tool
    # someone is using because the machine is already broken.
    $chain = $null
    try {
        $chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
        $chain.ChainPolicy.RevocationMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
        $null = $chain.Build($sig.SignerCertificate)
        if ($chain.ChainElements.Count -eq 0) { return @{ Ok = $false; Reason = 'not-microsoft-signed' } }
        $root = $chain.ChainElements[$chain.ChainElements.Count - 1].Certificate
        # CultureInvariant: -notmatch folds case by the current culture, and this pattern contains an 'i'. The
        # observed Microsoft roots are mixed-case, so identical casing matches under any culture -- but a DN spelled
        # 'O=MICROSOFT CORPORATION' folds its 'I' to the dotless 'i' under tr-TR and stops matching, which would
        # report a genuine Microsoft binary as not-microsoft-signed. Verified: that exact string fails -match under
        # tr-TR and passes with CultureInvariant. We do not control third-party DN casing, so do not depend on it.
        if (-not [regex]::IsMatch([string]$root.Subject, 'O=Microsoft Corporation', 'IgnoreCase,CultureInvariant')) {
            return @{ Ok = $false; Reason = 'not-microsoft-signed'; Signer = [string]$root.Subject }
        }
    }
    catch { return @{ Ok = $false; Reason = 'signature-unreadable' } }
    finally { if ($null -ne $chain) { $chain.Dispose() } }

    return @{ Ok = $true; Reason = 'ok'; Signer = [string]$sig.SignerCertificate.Subject }
}

function Resolve-LokiVcRuntimeAvailability {
    <#
        Will llama-server find a good enough runtime on this machine? One answer, one place.

        The order is the WINDOWS DLL SEARCH ORDER, not a preference: the exe's own directory is searched before the
        system directories, so a staged app-local runtime SHADOWS the host's. That has a consequence worth stating
        plainly, because it inverts the intuition: an app-local runtime that is too old is a FAILURE even on a host
        whose system-wide runtime is perfectly fine. The good one will never be reached.

        A PARTIALLY staged set is the same trap wearing a disguise: the staged files win, the absent ones fall through
        to the host, and the engine loads exactly the mixed set the floor exists to prevent (ADR-0012 section 3).
        `loki setup --stage-runtime` cannot produce that state -- but an interrupted copy, a half-finished manual
        drag-and-drop, or a deleted file can, so it is diagnosed rather than assumed away.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string[]]$Files,
        [Parameter(Mandatory = $true)][string]$MinVersion,
        [Parameter(Mandatory = $true)][string]$RegistryKey
    )
    $appLocal = Get-LokiVcRuntimeStatus -Directory $Directory -Files $Files

    if ($appLocal.Present) {
        $floor = Get-LokiVcRuntimeFloorCheck -Found $appLocal.Found -MinVersion $MinVersion
        if (-not $floor.Ok) {
            # Deliberately NOT falling back to the host: the app-local files shadow it.
            $r = @{ Ok = $false; Reason = $floor.Reason; Source = 'app-local' }
            if ($floor.ContainsKey('Version')) { $r['Version'] = $floor.Version }
            return $r
        }
        # The floor is a STALENESS check reading the file's own version resource -- attacker-controlled metadata.
        # It says nothing about the bytes. These three DLLs are the only code in engine-offline\ the pinned archive
        # cannot vouch for, and Windows loads them first; their signature is the one thing that can (see
        # Test-LokiMicrosoftSignature). The weakest file decides, exactly as with the floor.
        foreach ($f in @($appLocal.Found)) {
            $sig = Test-LokiMicrosoftSignature -Path ([string]$f.Path)
            if (-not $sig.Ok) {
                return @{ Ok = $false; Reason = $sig.Reason; Source = 'app-local'; File = [string]$f.File }
            }
        }
        return @{ Ok = $true; Reason = 'ok'; Source = 'app-local'; Version = $floor.Version }
    }

    if ($appLocal.Found.Count -gt 0) {
        return @{ Ok = $false; Reason = 'partially-staged'; Source = 'app-local'; Missing = $appLocal.Missing }
    }

    # Nothing staged -> the host decides.
    $hostStatus = Get-LokiVcRuntimeHostStatus -RegistryKey $RegistryKey -MinVersion $MinVersion
    $r = @{ Ok = $hostStatus.Ok; Reason = $hostStatus.Reason; Source = 'host' }
    if ($hostStatus.ContainsKey('Version')) { $r['Version'] = $hostStatus.Version }
    return $r
}

function Test-LokiModelIntegrity {
    <#
        The model is data, not code -- but it is data that steers an agent loop which is allowed to touch the machine,
        so a swapped .gguf is a real attack, not a corruption story. Verified against the SAME pin `loki setup` used.

        'not-installed' is deliberately NOT a failure here: `loki setup` lets the operator pick a subset (ADR-0013),
        so an absent tier is normal. The CALLER decides what an absent model means -- for the harness about to load
        one it is fatal; for a report it is information.

        'unreadable' is not 'mismatch'. A tier is several GB of file on removable media -- the one artifact most
        likely to meet a bad sector -- and "this .gguf does NOT match its pin, do not load it" is an accusation, not
        a diagnosis. It still never reads as fine (Get-LokiIntegrityExitCode).
    #>
    param(
        [Parameter(Mandatory = $true)]$Entry,
        [Parameter(Mandatory = $true)][string]$ModelsDir
    )
    $ErrorActionPreference = 'Stop'
    $id = [string]$Entry.Id
    $path = Join-Path $ModelsDir ([string]$Entry.FileName)
    $state = Get-LokiFileHashState -Path $path -ExpectedSha256 ([string]$Entry.Sha256)
    if ($state -eq 'missing') { return @{ Ok = $false; Reason = 'not-installed'; Id = $id } }
    if ($state -eq 'unreadable') { return @{ Ok = $false; Reason = 'unreadable'; Id = $id; Path = $path } }
    if ($state -ne 'match') { return @{ Ok = $false; Reason = 'mismatch'; Id = $id; Path = $path } }
    return @{ Ok = $true; Reason = 'verified'; Id = $id; Path = $path }
}

function Get-LokiEngineReport {
    # The impure gatherer: probes disk + registry and returns raw facts. All the judgement lives in the pure
    # ConvertTo-LokiIntegrityChecks below -- the same split as lib/hwscan.ps1 (probe vs rule) and lib/posture.ps1.
    param(
        [Parameter(Mandatory = $true)][string]$AppRoot,
        [Parameter(Mandatory = $true)]$Engine,
        [Parameter(Mandatory = $true)]$Runtime,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()]$Models
    )
    $layout = Get-LokiEngineLayout -AppRoot $AppRoot -Engine $Engine
    $runtimeFiles = [string[]]@($Runtime.Files)

    $modelsDir = (Get-LokiModelLayout -AppRoot $AppRoot).Dir
    $modelResults = New-Object System.Collections.Generic.List[object]
    foreach ($m in @($Models)) {
        $modelResults.Add((Test-LokiModelIntegrity -Entry $m -ModelsDir $modelsDir))
    }

    return @{
        # The staged Microsoft runtime is not in the archive and must not be reported as an intruder -- the same
        # exception `loki setup` makes when it prunes.
        Engine        = (Test-LokiEngineIntegrity -Layout $layout -Engine $Engine -PreserveNames $runtimeFiles)
        Runtime       = (Resolve-LokiVcRuntimeAvailability -Directory $layout.Dir -Files $runtimeFiles `
                -MinVersion ([string]$Runtime.MinVersion) -RegistryKey ([string]$Runtime.RegistryKey))
        Models        = $modelResults.ToArray()
        EngineVersion = [string]$Engine.Version
        MinVersion    = [string]$Runtime.MinVersion
    }
}

function Get-LokiIntegrityExitCode {
    <#
        PURE. The split this function encodes is the whole reason it is not just Get-LokiDoctorExitCode:

          1 (GeneralError)         the chain says WRONG, or could not be established AT ALL. Do not trust the stick.
          5 (OfflineEngineMissing) the stick is INCOMPLETE, or something could not be DETERMINED -- nothing suspicious.
          0                        usable.

        The two halves of each line matter. 1 is not only "bytes differ": archive-missing, file-missing, unsafe-entry,
        nothing-verified and verify-failed all land here, because "we could not establish the chain" must never be
        softer than "we established it and it is bad". 5 is not only "absent": a runtime that is too old or half
        staged is staged-but-wrong, and an unreadable signature is undetermined -- neither suggests tampering, and
        neither can reach 0.

        UNREADABLE (archive-unreadable / file-unreadable / a model that could not be read) is 5, and that is the one
        judgement in here worth arguing with, because it sits on the wrong side of the sentence above: we could not
        establish the chain, yet it is not 1. The reasons it is still right:
          * The medium says so first. Loki runs off a USB stick, where "this file cannot be read" is overwhelmingly a
            dying stick, an AV scanner's exclusive handle, or an ACL -- not an adversary. Answering "do not trust this
            stick" to a bad sector cries wolf on the common case, and a guard that cries wolf is a guard that gets
            ignored on the day it is right.
          * The attacker does not gain the thing that matters: unreadable can never reach 0, so nothing loads. All a
            file-locking adversary buys is a different WORD for a stick that already refuses to run.
          * It does not fit "could not establish the chain AT ALL" anyway: verify-failed is an exception we cannot
            characterise, archive-missing is a state setup never leaves behind. Unreadable is a specific, named,
            diagnosable condition -- so it gets a specific, honest answer instead of the loudest available one.
        The residual limit is real and recorded in ADR-0014: an adversary who can hold a handle open (or set a
        deny-read ACE on an NTFS-formatted stick) can push a would-be 1 down to a 5. Never to a 0.

        Collapsing those two into one code would make tampering indistinguishable from a fresh stick, and tampering
        must never look routine. A caller scripting this needs to tell "expected, run loki setup" from "this stick
        has been altered". 1 beats 5: if anything at all does not match its pin, that is the answer.
    #>
    param([Parameter(Mandatory = $true)]$Report)

    # Anything outside these two lists means we compared bytes and they did not match (or we could not compare at all,
    # which we refuse to treat as fine).
    $engineIncomplete = @('engine-not-installed', 'archive-unreadable', 'file-unreadable')
    $engineOk = @('verified')

    $wrong = $false
    $incomplete = $false

    if ($engineIncomplete -contains $Report.Engine.Reason) { $incomplete = $true }
    elseif ($engineOk -notcontains $Report.Engine.Reason) { $wrong = $true }

    # A model that is present but does not match its pin is as much a "do not trust this" as a bad engine file.
    # A model that is simply absent is normal (ADR-0013) and is not counted here at all. One we could not read is
    # undetermined -- same reasoning as the engine above, and equally unable to reach 0.
    foreach ($m in @($Report.Models)) {
        if ($m.Reason -eq 'mismatch') { $wrong = $true }
        elseif ($m.Reason -eq 'unreadable') { $incomplete = $true }
    }

    # The runtime splits across BOTH buckets, so it cannot be a single not-Ok test.
    # A staged DLL whose signature does not hold is loaded code that is not what it claims to be -- the same "do not
    # trust this stick" as a mismatched engine file, and it must not be filed under "just not set up yet".
    # Everything else (absent / too old / half-staged / undeterminable) means the engine cannot start here, but
    # nothing about it suggests the stick was altered: that is 5.
    # 'signature-unreadable' is deliberately NOT here. It means we could not DETERMINE the answer, and reporting
    # "do not trust this stick" for that is the mirror image of the lie section 4 of ADR-0014 forbids: it is not
    # "we verified nothing, so nothing is wrong", it is "we verified nothing, so everything is wrong". It still
    # fails closed -- it can never reach 0 -- it just lands in INCOMPLETE(5) with an honest "could not determine".
    $runtimeWrong = @('hash-mismatch', 'not-signed', 'not-microsoft-signed', 'signature-invalid')
    if (-not $Report.Runtime.Ok) {
        if ($runtimeWrong -contains $Report.Runtime.Reason) { $wrong = $true }
        else { $incomplete = $true }
    }

    if ($wrong) { return (Get-LokiExitCode 'GeneralError') }
    if ($incomplete) { return (Get-LokiExitCode 'OfflineEngineMissing') }
    return (Get-LokiExitCode 'Ok')
}

function ConvertTo-LokiIntegrityChecks {
    # PURE: hashtable in, ordered check objects out -- @{ Id; Severity; LabelKey; DetailKey; DetailArgs; DetailRaw },
    # the identical shape ConvertTo-LokiDoctorChecks produces, so src/commands/doctor.ps1 renders both with one loop.
    # 'Checks' is the contract name (a list of check results, not one check) and mirrors ConvertTo-LokiDoctorChecks --
    # suppress rather than rename, same as there.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Exact contract name (result is a list of checks, not one check); mirrors ConvertTo-LokiDoctorChecks in lib/posture.ps1.')]
    param([Parameter(Mandatory = $true)]$Report)

    $checks = New-Object System.Collections.Generic.List[object]
    $e = $Report.Engine
    $engineInstalled = ($e.Reason -ne 'engine-not-installed')

    # ---- engine ---------------------------------------------------------------------------------------------------
    # 'unknown' is not a softer 'fail' -- it is a different claim. It renders as a warning and can never count as a
    # clean OK (doctor.ps1), which is what fail-closed requires; what it does not do is tell an operator their stick
    # was altered when all we actually know is that we could not read it.
    $engineMap = @{
        'verified'             = @{ Severity = 'ok'; Key = 'integrity.engine.verified' }
        'engine-not-installed' = @{ Severity = 'warn'; Key = 'integrity.engine.notInstalled' }
        'archive-missing'      = @{ Severity = 'fail'; Key = 'integrity.engine.archiveMissing' }
        'archive-mismatch'     = @{ Severity = 'fail'; Key = 'integrity.engine.archiveMismatch' }
        'archive-unreadable'   = @{ Severity = 'unknown'; Key = 'integrity.engine.archiveUnreadable' }
        'file-mismatch'        = @{ Severity = 'fail'; Key = 'integrity.engine.fileMismatch' }
        'unexpected-file'      = @{ Severity = 'fail'; Key = 'integrity.engine.unexpectedFile' }
        'file-unreadable'      = @{ Severity = 'unknown'; Key = 'integrity.engine.fileUnreadable' }
        'file-missing'         = @{ Severity = 'fail'; Key = 'integrity.engine.fileMissing' }
    }
    if ($engineMap.ContainsKey($e.Reason)) {
        $m = $engineMap[$e.Reason]
        $args_ = @()
        switch ($e.Reason) {
            'verified' { $args_ = @($e.Checked, $Report.EngineVersion) }
            'file-mismatch' { $args_ = @(@($e.Mismatched).Count, (@($e.Mismatched) -join ', ')) }
            'unexpected-file' { $args_ = @(@($e.Unexpected).Count, (@($e.Unexpected) -join ', ')) }
            'file-unreadable' { $args_ = @(@($e.Unreadable).Count, (@($e.Unreadable) -join ', ')) }
            'file-missing' { $args_ = @(@($e.Missing).Count, (@($e.Missing) -join ', ')) }
        }
        $checks.Add(@{ Id = 'engine'; Severity = $m.Severity; LabelKey = 'doctor.check.engine'
                DetailKey = $m.Key; DetailArgs = $args_; DetailRaw = $null
            })
    }
    else {
        # unsafe-entry / nothing-verified / verify-failed: rare, internal, and all mean the same thing to an operator
        # -- we could not establish the chain, so do not pretend we did.
        $checks.Add(@{ Id = 'engine'; Severity = 'fail'; LabelKey = 'doctor.check.engine'
                DetailKey = 'integrity.engine.error'; DetailArgs = @([string]$e.Reason); DetailRaw = $null
            })
    }

    # ---- MSVC runtime ---------------------------------------------------------------------------------------------
    $r = $Report.Runtime
    if ($r.Ok) {
        $checks.Add(@{ Id = 'runtime'; Severity = 'ok'; LabelKey = 'doctor.check.runtime'
                DetailKey = 'integrity.runtime.ok'; DetailArgs = @([string]$r.Source, [string]$r.Version); DetailRaw = $null
            })
    }
    elseif ($r.Reason -eq 'not-installed') {
        # A missing runtime only MATTERS if there is an engine that would need it. On a stick with no engine yet it is
        # a fact, not a fault -- and `loki setup --stage-runtime` is the fix in both cases.
        $checks.Add(@{ Id = 'runtime'; Severity = (& { if ($engineInstalled) { 'fail' } else { 'warn' } })
                LabelKey = 'doctor.check.runtime'; DetailKey = 'integrity.runtime.notInstalled'
                DetailArgs = @(); DetailRaw = $null
            })
    }
    elseif ($r.Reason -eq 'too-old') {
        $checks.Add(@{ Id = 'runtime'; Severity = 'fail'; LabelKey = 'doctor.check.runtime'
                DetailKey = 'integrity.runtime.tooOld'
                DetailArgs = @([string]$r.Version, [string]$Report.MinVersion, [string]$r.Source); DetailRaw = $null
            })
    }
    elseif ($r.Reason -eq 'partially-staged') {
        $checks.Add(@{ Id = 'runtime'; Severity = 'fail'; LabelKey = 'doctor.check.runtime'
                DetailKey = 'integrity.runtime.partiallyStaged'
                DetailArgs = @((@($r.Missing) -join ', ')); DetailRaw = $null
            })
    }
    elseif (@('hash-mismatch', 'not-signed', 'not-microsoft-signed', 'signature-invalid') -contains $r.Reason) {
        # Loaded code that is not what it claims to be. This must never render as a mere "unknown".
        $checks.Add(@{ Id = 'runtime'; Severity = 'fail'; LabelKey = 'doctor.check.runtime'
                DetailKey = 'integrity.runtime.signature'
                DetailArgs = @((& { if ($r.ContainsKey('File')) { [string]$r.File } else { '' } }), [string]$r.Reason)
                DetailRaw = $null
            })
    }
    else {
        # version-unreadable / registry-unreadable / registry-key-invalid / min-version-invalid -- we could not
        # DETERMINE the answer. 'unknown' renders as a warning and is never counted as a clean OK (doctor.ps1).
        $checks.Add(@{ Id = 'runtime'; Severity = 'unknown'; LabelKey = 'doctor.check.runtime'
                DetailKey = 'integrity.runtime.unknown'; DetailArgs = @([string]$r.Reason); DetailRaw = $null
            })
    }

    # ---- model tiers ----------------------------------------------------------------------------------------------
    # Only tiers that are actually PRESENT get a row: `loki setup` deliberately lets the operator download a subset
    # (ADR-0013), so listing every absent tier as a warning would turn a normal stick into a wall of noise. A file
    # that is there but does not match its pin is the opposite of noise.
    $present = @(@($Report.Models) | Where-Object { $_.Reason -ne 'not-installed' })
    if ($present.Count -eq 0) {
        $checks.Add(@{ Id = 'models'; Severity = 'warn'; LabelKey = 'doctor.check.models'
                DetailKey = 'integrity.model.noneInstalled'; DetailArgs = @(); DetailRaw = $null
            })
    }
    else {
        foreach ($m in $present) {
            if ($m.Ok) {
                $checks.Add(@{ Id = ('model:' + $m.Id); Severity = 'ok'; LabelKey = 'doctor.check.models'
                        DetailKey = 'integrity.model.verified'; DetailArgs = @([string]$m.Id); DetailRaw = $null
                    })
            }
            elseif ($m.Reason -eq 'unreadable') {
                $checks.Add(@{ Id = ('model:' + $m.Id); Severity = 'unknown'; LabelKey = 'doctor.check.models'
                        DetailKey = 'integrity.model.unreadable'; DetailArgs = @([string]$m.Id); DetailRaw = $null
                    })
            }
            else {
                $checks.Add(@{ Id = ('model:' + $m.Id); Severity = 'fail'; LabelKey = 'doctor.check.models'
                        DetailKey = 'integrity.model.mismatch'; DetailArgs = @([string]$m.Id); DetailRaw = $null
                    })
            }
        }
    }

    # Leading comma: an [object[]] returned bare is unrolled by the pipeline, and a ONE-check result would reach the
    # caller as a single hashtable whose .Count is the hashtable's key count, not 1.
    return , $checks.ToArray()
}
