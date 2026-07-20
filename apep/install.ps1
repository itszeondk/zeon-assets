# Z-Rotations installer. Run:  irm https://raw.githubusercontent.com/itszeondk/zeon-assets/main/apep/install.ps1 | iex
# Downloads Z-Rotations.enc + UI assets and places them for Apep + WoW.
Set-StrictMode -Version 2.0

$ZRotInstaller_Version = '0.3.0'
$ZRotInstaller_Loaded  = $true

$script:BaseUrl      = 'https://raw.githubusercontent.com/itszeondk/zeon-assets/main/'
$script:SubFolder    = 'apep/'
$script:ManifestPath = 'apep/manifest.txt'
$script:MmapsBuild = '335'
$script:MmapsDescriptorUrl = 'https://raw.githubusercontent.com/itszeondk/zeon-assets/main/apep/mmaps-335.json'
$script:MmapsReceiptName = '.zrot-mmaps-receipt.json'
$script:ZRotInstallInProgress = $false
$script:ZRotSuppressConfigWrites = $false

# --- Task 2: core logic functions ---

function Get-WowDirFromApepJson {
    param([string]$JsonText)
    if ([string]::IsNullOrWhiteSpace($JsonText)) { return $null }
    try { $cfg = $JsonText | ConvertFrom-Json } catch { return $null }
    try {
        if (-not $cfg.Profiles) { return $null }
        $active = $cfg.ActiveProfileName
        $activeProfile = $null
        foreach ($p in $cfg.Profiles) {
            if ($active -and $p.Name -eq $active) { $activeProfile = $p; break }
        }
        if (-not $activeProfile) { $activeProfile = $cfg.Profiles | Select-Object -First 1 }
        # SECURITY: read only the path; never touch AccountName/AccountPassword.
        $wowPath = $activeProfile.WowPath
        if ([string]::IsNullOrWhiteSpace($wowPath)) { return $null }
        return (Split-Path -Parent $wowPath)
    } catch {
        return $null
    }
}

function ConvertFrom-ZRotManifest {
    param([string]$Text)
    $map = @{}
    if ([string]::IsNullOrEmpty($Text)) { return $map }
    foreach ($line in ($Text -split "`r?`n")) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        if ($t -notmatch '^(\S+)\s+([0-9a-fA-F]{10})$') { throw 'Asset manifest contains a malformed line.' }
        $rel = ConvertTo-ZRotSafeRelativePath $matches[1]
        if ($map.ContainsKey($rel)) { throw 'Asset manifest contains a duplicate path.' }
        $map[$rel] = $matches[2].ToLowerInvariant()
    }
    return $map
}

function ConvertTo-ZRotSafeRelativePath {
    param([string]$Rel)
    if ([string]::IsNullOrWhiteSpace($Rel)) { throw 'Asset manifest path is empty.' }
    $normalized = $Rel -replace '\\','/'
    if ($normalized.Length -gt 240 -or $normalized.StartsWith('/') -or
        $normalized.Contains(':') -or $normalized -notmatch '^[A-Za-z0-9._/-]+$') {
        throw 'Asset manifest contains an unsafe path.'
    }
    $segments = @($normalized -split '/')
    if ($segments.Count -eq 0) { throw 'Asset manifest contains an unsafe path.' }
    foreach ($segment in $segments) {
        if ([string]::IsNullOrEmpty($segment) -or $segment -eq '.' -or $segment -eq '..' -or $segment.EndsWith('.')) {
            throw 'Asset manifest contains an unsafe path.'
        }
    }
    $extension = [System.IO.Path]::GetExtension($normalized).ToLowerInvariant()
    if (@('.png', '.tga', '.ttf', '.txt', '.enc') -notcontains $extension) {
        throw 'Asset manifest contains an unsupported file type.'
    }
    return $normalized
}

function Test-ZRotManifestComplete {
    param([hashtable]$Manifest)
    return ($null -ne $Manifest -and $Manifest.Count -gt 0 -and $Manifest.ContainsKey('Z-Rotations.enc'))
}

function Get-ZRotRemoteUrl {
    param([string]$Rel)
    $rel = ConvertTo-ZRotSafeRelativePath $Rel
    return $script:BaseUrl + $script:SubFolder + $rel
}

function Get-ZRotDestination {
    param([string]$Rel, [string]$ApepDir, [string]$WowDir)
    $rel = ConvertTo-ZRotSafeRelativePath $Rel
    $ext = [System.IO.Path]::GetExtension($rel).ToLowerInvariant()
    if ($ext -eq '.tga') {
        $stem = [System.IO.Path]::GetFileNameWithoutExtension($rel)
        return (Join-Path $WowDir ("Interface\ZRotations\{0}.tga" -f $stem))
    }
    if ($ext -eq '.enc') {
        $name = [System.IO.Path]::GetFileName($rel)
        return (Join-Path $ApepDir ("rotations\plugins\{0}" -f $name))
    }
    return (Join-Path $ApepDir ("media\zrotations\{0}" -f ($rel -replace '/','\')))
}

function Get-Sha1Short {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA1).Hash.ToLowerInvariant().Substring(0,10)
}

function Get-ZRotPlan {
    param([hashtable]$Remote, [hashtable]$LocalHashes)
    $install = @(); $update = @(); $current = @()
    foreach ($rel in $Remote.Keys) {
        $have = $null
        if ($LocalHashes.ContainsKey($rel)) { $have = $LocalHashes[$rel] }
        if ([string]::IsNullOrEmpty($have)) { $install += $rel }
        elseif ($have -ne $Remote[$rel]) { $update += $rel }
        else { $current += $rel }
    }
    return [pscustomobject]@{ Install = $install; Update = $update; Current = $current }
}


# --- Task 3: apply engine + validators ---

function Get-ZRotMissingApepItems {
    param([string]$Path)
    $requiredItems = @('Apep.exe', 'Apep.json', 'rotations')
    if ([string]::IsNullOrWhiteSpace($Path)) { return $requiredItems }

    if (-not (Test-Path -LiteralPath (Join-Path $Path 'Apep.exe') -PathType Leaf)) { 'Apep.exe' }
    if (-not (Test-Path -LiteralPath (Join-Path $Path 'Apep.json') -PathType Leaf)) { 'Apep.json' }
    if (-not (Test-Path -LiteralPath (Join-Path $Path 'rotations') -PathType Container)) { 'rotations' }
}

function Test-ApepDir {
    param([string]$Path)
    $missingItems = @(Get-ZRotMissingApepItems $Path)
    return ($missingItems.Count -eq 0)
}

function Test-WowDir {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    return (Test-Path -LiteralPath (Join-Path $Path 'Interface') -PathType Container)
}

function Find-ApepDir {
    $candidates = @(
        (Join-Path $env:USERPROFILE 'Documents\Apep'),
        (Get-Location).Path
    )
    foreach ($c in $candidates) { if (Test-ApepDir $c) { return $c } }
    return $null
}

function Save-ZRotFile {
    param([string]$Url, [string]$Dest, [string]$ExpectedSha1Short)
    $old = $ProgressPreference
    try {
        $dir = Split-Path -Parent $Dest
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $tmp = "$Dest.tmp"
        Enable-ZRotTls12
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $Url -OutFile $tmp -UseBasicParsing | Out-Null
        if ($ExpectedSha1Short -notmatch '^[0-9a-fA-F]{10}$' -or (Get-Sha1Short $tmp) -cne $ExpectedSha1Short.ToLowerInvariant()) {
            throw 'Downloaded asset failed manifest hash verification.'
        }
        Move-Item -LiteralPath $tmp -Destination $Dest -Force
        return $true
    } catch {
        if (Test-Path -LiteralPath "$Dest.tmp") { Remove-Item -LiteralPath "$Dest.tmp" -Force -ErrorAction SilentlyContinue }
        return $false
    } finally {
        $ProgressPreference = $old
    }
}

function Invoke-ZRotApply {
    param([hashtable]$Remote, [string[]]$RelList, [string]$ApepDir, [string]$WowDir, [scriptblock]$OnProgress)
    $ok = 0; $failed = @(); $total = $RelList.Count; $i = 0
    foreach ($rel in $RelList) {
        $i++
        $url = Get-ZRotRemoteUrl $rel
        $dest = Get-ZRotDestination $rel $ApepDir $WowDir
        $good = Save-ZRotFile $url $dest $Remote[$rel]
        if ($good) { $ok++ } else { $failed += $rel }
        if ($OnProgress) { & $OnProgress $i $total $rel $good }
    }
    return @{ Ok = $ok; Failed = $failed }
}

# --- Task 3: config persistence ---

function Get-ZRotConfigPath {
    return (Join-Path $env:LOCALAPPDATA 'ZRotations\installer.json')
}

function Save-ZRotInstallerConfig {
    param([string]$ApepDir, [string]$WowDir)
    if ($env:ZROT_TEST -or $script:ZRotSuppressConfigWrites) { return }
    try {
        $cfgPath = Get-ZRotConfigPath
        $cfgDir = Split-Path -Parent $cfgPath
        if (-not (Test-Path -LiteralPath $cfgDir)) { New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null }
        $obj = [pscustomobject]@{ ApepDir = $ApepDir; WowDir = $WowDir }
        ($obj | ConvertTo-Json) | Set-Content -LiteralPath $cfgPath -Encoding UTF8
    } catch {
        # Non-fatal: failing to persist paths should not block installation.
    }
}

function Read-ZRotInstallerConfig {
    $cfgPath = Get-ZRotConfigPath
    if (-not (Test-Path -LiteralPath $cfgPath)) { return $null }
    try {
        return (Get-Content -Raw -LiteralPath $cfgPath | ConvertFrom-Json)
    } catch {
        return $null
    }
}

# --- Optional MMAPS release installer ---

function ConvertTo-ZRotPositiveInt64 {
    param($Value, [string]$Name, [switch]$AllowZero)
    [long]$number = 0
    if (-not [long]::TryParse([string]$Value, [ref]$number)) {
        throw "MMAPS descriptor field '$Name' must be an integer."
    }
    if (($AllowZero -and $number -lt 0) -or (-not $AllowZero -and $number -le 0)) {
        throw "MMAPS descriptor field '$Name' is outside the allowed range."
    }
    return $number
}

function ConvertFrom-ZRotMmapsDescriptor {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text) -or $Text.Length -gt 65536) {
        throw 'MMAPS descriptor is empty or too large.'
    }
    try {
        $raw = $Text | ConvertFrom-Json
    } catch {
        throw 'MMAPS descriptor is not valid JSON.'
    }

    $required = @(
        'schemaVersion', 'build', 'archiveUrl', 'archiveSha256',
        'archiveBytes', 'payloadBytes', 'mmapCount', 'mmtileCount',
        'mmapFileBytes', 'mmtileHeaderBytes', 'mmtileHeaderHex',
        'detourVersion', 'mmapVersion', 'useLiquids'
    )
    foreach ($name in $required) {
        if ($null -eq $raw.PSObject.Properties[$name]) {
            throw "MMAPS descriptor is missing '$name'."
        }
    }

    $schemaVersion = ConvertTo-ZRotPositiveInt64 $raw.schemaVersion 'schemaVersion'
    if ($schemaVersion -ne 1) { throw 'Unsupported MMAPS descriptor schema.' }
    $build = [string]$raw.build
    if ($build -cne $script:MmapsBuild) { throw 'MMAPS descriptor targets an unexpected game build.' }

    $archiveUrl = [string]$raw.archiveUrl
    try { $archiveUri = New-Object System.Uri($archiveUrl) } catch { throw 'MMAPS archive URL is invalid.' }
    if (-not $archiveUri.IsAbsoluteUri -or $archiveUri.Scheme -cne 'https') {
        throw 'MMAPS archive URL must use HTTPS.'
    }
    if ($archiveUri.Host -ine 'github.com' -or -not $archiveUri.IsDefaultPort -or -not [string]::IsNullOrEmpty($archiveUri.UserInfo) -or
        -not [string]::IsNullOrEmpty($archiveUri.Query) -or -not [string]::IsNullOrEmpty($archiveUri.Fragment)) {
        throw 'MMAPS archive URL must be a credential-free GitHub release URL.'
    }
    if ($archiveUri.AbsolutePath -notmatch '^/itszeondk/zeon-assets/releases/download/[^/]+/mmaps-335\.zip$' -or
        $archiveUri.AbsolutePath -match '/releases/download/latest/') {
        throw 'MMAPS archive URL must pin a specific zeon-assets release.'
    }

    $archiveSha256 = ([string]$raw.archiveSha256).ToLowerInvariant()
    if ($archiveSha256 -notmatch '^[0-9a-f]{64}$') { throw 'MMAPS archive SHA-256 is invalid.' }
    $archiveBytes = ConvertTo-ZRotPositiveInt64 $raw.archiveBytes 'archiveBytes'
    $payloadBytes = ConvertTo-ZRotPositiveInt64 $raw.payloadBytes 'payloadBytes'
    $mmapCount = ConvertTo-ZRotPositiveInt64 $raw.mmapCount 'mmapCount'
    $mmtileCount = ConvertTo-ZRotPositiveInt64 $raw.mmtileCount 'mmtileCount'
    $mmapFileBytes = ConvertTo-ZRotPositiveInt64 $raw.mmapFileBytes 'mmapFileBytes'
    $mmtileHeaderBytes = ConvertTo-ZRotPositiveInt64 $raw.mmtileHeaderBytes 'mmtileHeaderBytes'
    $mmtileHeaderHex = ([string]$raw.mmtileHeaderHex).ToUpperInvariant()
    $detourVersion = ConvertTo-ZRotPositiveInt64 $raw.detourVersion 'detourVersion'
    $mmapVersion = ConvertTo-ZRotPositiveInt64 $raw.mmapVersion 'mmapVersion'

    if ($mmapFileBytes -ne 28) { throw 'MMAPS descriptor has an unexpected .mmap record size.' }
    if ($mmtileHeaderBytes -ne 20) { throw 'MMAPS descriptor has an unexpected .mmtile header size.' }
    if ($mmtileHeaderHex -cne '50414D4D') { throw 'MMAPS descriptor has an unexpected .mmtile header.' }
    if ($detourVersion -ne 7 -or $mmapVersion -ne 15) { throw 'MMAPS descriptor has unexpected navigation format versions.' }
    if (-not ($raw.useLiquids -is [bool]) -or -not [bool]$raw.useLiquids) {
        throw 'MMAPS descriptor must identify a liquid-enabled payload.'
    }
    if ($mmapCount -gt ([long]::MaxValue - $mmtileCount)) { throw 'MMAPS descriptor file counts overflow.' }

    return [pscustomobject]@{
        SchemaVersion = $schemaVersion
        Build = $build
        ArchiveUrl = $archiveUrl
        ArchiveSha256 = $archiveSha256
        ArchiveBytes = $archiveBytes
        PayloadBytes = $payloadBytes
        MmapCount = $mmapCount
        MmtileCount = $mmtileCount
        FileCount = $mmapCount + $mmtileCount
        MmapFileBytes = $mmapFileBytes
        MmtileHeaderBytes = $mmtileHeaderBytes
        MmtileHeaderHex = $mmtileHeaderHex
        DetourVersion = $detourVersion
        MmapVersion = $mmapVersion
        UseLiquids = $true
    }
}

function Get-ZRotMmapsConfigState {
    param([string]$JsonText)

    $unsafe = [pscustomobject]@{ Safe = $false; HasValue = $false; Value = $null }
    if ([string]::IsNullOrWhiteSpace($JsonText)) { return $unsafe }
    try { $cfg = $JsonText | ConvertFrom-Json } catch { return $unsafe }

    $settingsProperties = @($cfg.PSObject.Properties | Where-Object { $_.Name -ceq 'Settings' })
    if ($settingsProperties.Count -ne 1 -or $null -eq $settingsProperties[0].Value) { return $unsafe }
    $mmapProperties = @($settingsProperties[0].Value.PSObject.Properties | Where-Object { $_.Name -ceq 'mmaps' })
    if ($mmapProperties.Count -ne 1 -or $null -eq $mmapProperties[0].Value -or
        -not ($mmapProperties[0].Value -is [string])) { return $unsafe }

    $pattern = '((?<!\\)"mmaps"\s*:\s*)("(?:\\["\\/bfnrt]|\\u[0-9a-fA-F]{4}|[^"\\\x00-\x1F])*")'
    $matchesFound = [regex]::Matches($JsonText, $pattern)
    if ($matchesFound.Count -ne 1) { return $unsafe }
    try { $decoded = $matchesFound[0].Groups[2].Value | ConvertFrom-Json } catch { return $unsafe }
    if (-not ($decoded -is [string]) -or $decoded -cne [string]$mmapProperties[0].Value) { return $unsafe }

    return [pscustomobject]@{
        Safe = $true
        HasValue = -not [string]::IsNullOrWhiteSpace([string]$decoded)
        Value = [string]$decoded
    }
}

# MMAPS live at the drive root, never inside the Apep folder: Apep/NavSrv hits
# permission errors reading maps below the (typically user-profile) Apep
# directory, which breaks navigation even though the files are present.
function Get-ZRotMmapsDefaultPath {
    $drive = $env:SystemDrive
    if ([string]::IsNullOrWhiteSpace($drive)) { $drive = 'C:' }
    return [System.IO.Path]::GetFullPath(("{0}\mmaps\{1}" -f $drive, $script:MmapsBuild))
}

function Test-ZRotPathInsideApep {
    param([string]$Path, [string]$ApepDir)
    $trimChars = [char[]]@('\', '/')
    $apepFull = [System.IO.Path]::GetFullPath($ApepDir).TrimEnd($trimChars)
    $candidate = [System.IO.Path]::GetFullPath($Path).TrimEnd($trimChars)
    return [string]::Equals($candidate, $apepFull, [StringComparison]::OrdinalIgnoreCase) -or
        $candidate.StartsWith($apepFull + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Resolve-ZRotMmapsTarget {
    param([string]$ApepDir)

    $defaultPath = Get-ZRotMmapsDefaultPath
    $configPath = Join-Path $ApepDir 'Apep.json'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        return [pscustomobject]@{ Path = $defaultPath; Source = 'default'; CanConfigure = $false }
    }

    try {
        $state = Get-ZRotMmapsConfigState ([System.IO.File]::ReadAllText($configPath))
    } catch {
        return [pscustomobject]@{ Path = $defaultPath; Source = 'default'; CanConfigure = $false }
    }
    if (-not $state.Safe -or -not $state.HasValue) {
        return [pscustomobject]@{ Path = $defaultPath; Source = 'default'; CanConfigure = $state.Safe }
    }

    try {
        $candidate = [Environment]::ExpandEnvironmentVariables($state.Value)
        if (-not [System.IO.Path]::IsPathRooted($candidate)) { $candidate = Join-Path $ApepDir $candidate }
        $candidate = [System.IO.Path]::GetFullPath($candidate)
        # A configured path inside the Apep folder reproduces the NavSrv
        # permission failure, so it is migrated to the drive-root default
        # (Set-ZRotApepMmapsPath then persists the new location).
        if (Test-ZRotPathInsideApep $candidate $ApepDir) {
            return [pscustomobject]@{ Path = $defaultPath; Source = 'migrated-from-apep-folder'; CanConfigure = $true }
        }
        return [pscustomobject]@{ Path = $candidate; Source = 'Settings.mmaps'; CanConfigure = $true }
    } catch {
        return [pscustomobject]@{ Path = $defaultPath; Source = 'default'; CanConfigure = $state.Safe }
    }
}

function Test-ZRotMmapsTargetSafety {
    param([string]$TargetPath, [string]$ApepDir)

    try {
        $full = [System.IO.Path]::GetFullPath($TargetPath)
        $root = [System.IO.Path]::GetPathRoot($full)
        $apepFull = [System.IO.Path]::GetFullPath($ApepDir)
    } catch {
        return [pscustomobject]@{ Safe = $false; Path = $null; Reason = 'The MMAPS target path is invalid.' }
    }
    $trimChars = [char[]]@('\', '/')
    if ([string]::IsNullOrWhiteSpace($root) -or
        [string]::Equals($full.TrimEnd($trimChars), $root.TrimEnd($trimChars), [StringComparison]::OrdinalIgnoreCase) -or
        [string]::Equals($full.TrimEnd($trimChars), $apepFull.TrimEnd($trimChars), [StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{ Safe = $false; Path = $full; Reason = 'The MMAPS target cannot be a drive root or the Apep root.' }
    }
    $ancestor = Split-Path -Parent $full
    while (-not [string]::IsNullOrWhiteSpace($ancestor)) {
        if (Test-Path -LiteralPath $ancestor) {
            $ancestorItem = Get-Item -LiteralPath $ancestor -Force
            if (($ancestorItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                return [pscustomobject]@{ Safe = $false; Path = $full; Reason = 'The MMAPS target is below a filesystem link or junction.' }
            }
        }
        $nextAncestor = Split-Path -Parent $ancestor
        if ([string]::IsNullOrWhiteSpace($nextAncestor) -or $nextAncestor -eq $ancestor) { break }
        $ancestor = $nextAncestor
    }
    if (Test-Path -LiteralPath $full) {
        $item = Get-Item -LiteralPath $full -Force
        if (-not $item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            return [pscustomobject]@{ Safe = $false; Path = $full; Reason = 'The existing MMAPS target is not a regular directory.' }
        }
        foreach ($child in Get-ChildItem -LiteralPath $full -Force) {
            if ($child.PSIsContainer -or (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
                return [pscustomobject]@{ Safe = $false; Path = $full; Reason = 'The existing MMAPS target contains directories or links.' }
            }
            $extension = $child.Extension.ToLowerInvariant()
            if ($child.Name -cne $script:MmapsReceiptName -and $extension -ne '.mmap' -and $extension -ne '.mmtile') {
                return [pscustomobject]@{ Safe = $false; Path = $full; Reason = 'The existing MMAPS target contains unrelated files.' }
            }
        }
    }
    return [pscustomobject]@{ Safe = $true; Path = $full; Reason = $null }
}

function Get-ZRotAvailableBytes {
    param([string]$Path)
    try {
        $probe = [System.IO.Path]::GetFullPath($Path)
        while (-not (Test-Path -LiteralPath $probe)) {
            $parent = Split-Path -Parent $probe
            if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $probe) { return $null }
            $probe = $parent
        }
        $root = [System.IO.Path]::GetPathRoot($probe)
        return (New-Object System.IO.DriveInfo($root)).AvailableFreeSpace
    } catch {
        return $null
    }
}

function Test-ZRotMmapsDiskSpace {
    param($Descriptor, [string]$TargetPath, [switch]$IncludeArchive, [long]$AvailableBytes = -1)

    [long]$required = $Descriptor.PayloadBytes
    if ($IncludeArchive) {
        if ($required -gt ([long]::MaxValue - $Descriptor.ArchiveBytes)) {
            return [pscustomobject]@{ Known = $true; Enough = $false; RequiredBytes = [long]::MaxValue; AvailableBytes = $AvailableBytes }
        }
        $required += $Descriptor.ArchiveBytes
    }
    [long]$safety = [Math]::Max(67108864L, [long][Math]::Ceiling([double]$Descriptor.PayloadBytes * 0.05))
    if ($required -gt ([long]::MaxValue - $safety)) { $required = [long]::MaxValue } else { $required += $safety }
    if ($AvailableBytes -lt 0) {
        $availableValue = Get-ZRotAvailableBytes $TargetPath
        if ($null -eq $availableValue) {
            return [pscustomobject]@{ Known = $false; Enough = $false; RequiredBytes = $required; AvailableBytes = $null }
        }
        $AvailableBytes = [long]$availableValue
    }
    return [pscustomobject]@{
        Known = $true
        Enough = ($AvailableBytes -ge $required)
        RequiredBytes = $required
        AvailableBytes = $AvailableBytes
    }
}

function Get-ZRotSha256 {
    param([string]$Path, [scriptblock]$OnProgress)

    $item = Get-Item -LiteralPath $Path
    $stream = [System.IO.File]::OpenRead($item.FullName)
    $hasher = [System.Security.Cryptography.SHA256]::Create()
    try {
        $buffer = New-Object byte[] 4194304
        [long]$processed = 0
        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $null = $hasher.TransformBlock($buffer, 0, $read, $buffer, 0)
            $processed += $read
            if ($OnProgress) {
                try { & $OnProgress $processed ([long]$item.Length) } catch { }
            }
        }
        $empty = New-Object byte[] 0
        $null = $hasher.TransformFinalBlock($empty, 0, 0)
        return ([BitConverter]::ToString($hasher.Hash).Replace('-', '')).ToLowerInvariant()
    } finally {
        $hasher.Dispose()
        $stream.Dispose()
    }
}

function Test-ZRotMmapsArchive {
    param([string]$ArchivePath, $Descriptor, [scriptblock]$OnHashProgress)

    if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) { throw 'MMAPS archive is missing.' }
    $archiveItem = Get-Item -LiteralPath $ArchivePath
    if ([long]$archiveItem.Length -ne [long]$Descriptor.ArchiveBytes) { throw 'MMAPS archive byte count does not match its descriptor.' }
    if ((Get-ZRotSha256 $ArchivePath $OnHashProgress) -cne $Descriptor.ArchiveSha256) { throw 'MMAPS archive failed SHA-256 verification.' }

    Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop | Out-Null
    $zip = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        $seen = @{}
        $mapIds = @{}
        $tileMapIds = @{}
        [long]$payloadBytes = 0
        [long]$mmapCount = 0
        [long]$mmtileCount = 0
        foreach ($entry in $zip.Entries) {
            $name = [string]$entry.FullName
            if ([string]::IsNullOrWhiteSpace($name) -or $name -cne [string]$entry.Name -or
                $name.Contains('/') -or $name.Contains('\') -or $name.Contains(':') -or
                $name -eq '.' -or $name -eq '..' -or [System.IO.Path]::IsPathRooted($name)) {
                throw 'MMAPS archive contains a nested or unsafe entry.'
            }
            if ($seen.ContainsKey($name)) { throw 'MMAPS archive contains duplicate filenames.' }
            $seen[$name] = $true
            $extension = [System.IO.Path]::GetExtension($name).ToLowerInvariant()
            if ($extension -eq '.mmap') {
                if ($name -cnotmatch '^[0-9]{3}\.mmap$') { throw 'MMAPS archive contains an invalid .mmap filename.' }
                $mapIds[$name.Substring(0, 3)] = $true
                $mmapCount++
                if ([long]$entry.Length -ne [long]$Descriptor.MmapFileBytes) { throw 'MMAPS archive contains an invalid .mmap record.' }
            } elseif ($extension -eq '.mmtile') {
                if ($name -cnotmatch '^[0-9]{7}\.mmtile$') { throw 'MMAPS archive contains an invalid .mmtile filename.' }
                $tileMapIds[$name.Substring(0, 3)] = $true
                $mmtileCount++
                if ([long]$entry.Length -lt $Descriptor.MmtileHeaderBytes) { throw 'MMAPS archive contains a truncated .mmtile record.' }
            } else {
                throw 'MMAPS archive contains a file that is not .mmap or .mmtile.'
            }
            if ($payloadBytes -gt ([long]::MaxValue - [long]$entry.Length)) { throw 'MMAPS archive payload size overflow.' }
            $payloadBytes += [long]$entry.Length
        }
        if ($mmapCount -ne $Descriptor.MmapCount -or $mmtileCount -ne $Descriptor.MmtileCount -or
            ($mmapCount + $mmtileCount) -ne $Descriptor.FileCount) {
            throw 'MMAPS archive file counts do not match its descriptor.'
        }
        foreach ($mapId in $tileMapIds.Keys) {
            if (-not $mapIds.ContainsKey($mapId)) { throw 'MMAPS archive contains a tile without its map header.' }
        }
        if ($payloadBytes -ne $Descriptor.PayloadBytes) { throw 'MMAPS archive payload bytes do not match its descriptor.' }
        return [pscustomobject]@{ FileCount = $mmapCount + $mmtileCount; PayloadBytes = $payloadBytes }
    } finally {
        $zip.Dispose()
    }
}

function Invoke-ZRotMmapsProgress {
    param([scriptblock]$OnProgress, [int]$Percent, [string]$Status)
    if ($OnProgress) {
        try { & $OnProgress $Percent $Status } catch { }
    }
}

function Invoke-ZRotMmapsLog {
    param([scriptblock]$OnLog, [string]$Message)
    if ($OnLog) {
        try { & $OnLog $Message } catch { }
    }
}

function Expand-ZRotMmapsArchiveStaged {
    param([string]$ArchivePath, [string]$StagePath, $Descriptor, [scriptblock]$OnProgress)

    if (Test-Path -LiteralPath $StagePath) { throw 'MMAPS staging directory already exists.' }
    New-Item -ItemType Directory -Path $StagePath -Force | Out-Null
    $zip = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        $index = 0
        [long]$extractedBytes = 0
        $buffer = New-Object byte[] 1048576
        foreach ($entry in $zip.Entries) {
            $index++
            $destination = Join-Path $StagePath $entry.Name
            $input = $entry.Open()
            $output = $null
            try {
                $output = [System.IO.File]::Open($destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                [long]$entryBytes = 0
                while (($read = $input.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    if ($entryBytes -gt ([long]$entry.Length - $read) -or
                        $extractedBytes -gt ([long]$Descriptor.PayloadBytes - $read)) {
                        throw 'MMAPS archive expanded beyond its declared payload size.'
                    }
                    $output.Write($buffer, 0, $read)
                    $entryBytes += $read
                    $extractedBytes += $read
                }
                if ($entryBytes -ne [long]$entry.Length) { throw 'MMAPS archive entry extracted to an unexpected size.' }
            } finally {
                if ($output) { $output.Dispose() }
                $input.Dispose()
            }
            $percent = 55 + [int][Math]::Floor((35.0 * $index) / [Math]::Max(1, $Descriptor.FileCount))
            Invoke-ZRotMmapsProgress $OnProgress $percent ("Extracting MMAPS ({0}/{1})" -f $index, $Descriptor.FileCount)
        }
        if ($extractedBytes -ne [long]$Descriptor.PayloadBytes) { throw 'MMAPS archive extracted to an unexpected total size.' }
    } catch {
        if (Test-Path -LiteralPath $StagePath) { Remove-Item -LiteralPath $StagePath -Recurse -Force -ErrorAction SilentlyContinue }
        throw
    } finally {
        $zip.Dispose()
    }
}

function Test-ZRotMmapsPayload {
    param([string]$PayloadPath, $Descriptor)

    if (-not (Test-Path -LiteralPath $PayloadPath -PathType Container)) { throw 'MMAPS payload directory is missing.' }
    [long]$payloadBytes = 0
    [long]$mmapCount = 0
    [long]$mmtileCount = 0
    $mapIds = @{}
    $tileMapIds = @{}
    foreach ($item in Get-ChildItem -LiteralPath $PayloadPath -Force) {
        if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw 'MMAPS payload must contain flat, regular files only.'
        }
        if ($item.Name -ceq $script:MmapsReceiptName) { continue }
        $extension = $item.Extension.ToLowerInvariant()
        if ($extension -eq '.mmap') {
            if ($item.Name -cnotmatch '^[0-9]{3}\.mmap$') { throw 'MMAPS payload contains an invalid .mmap filename.' }
            $mapIds[$item.Name.Substring(0, 3)] = $true
            $mmapCount++
            if ([long]$item.Length -ne [long]$Descriptor.MmapFileBytes) { throw 'MMAPS payload contains an invalid .mmap record.' }
        } elseif ($extension -eq '.mmtile') {
            if ($item.Name -cnotmatch '^[0-9]{7}\.mmtile$') { throw 'MMAPS payload contains an invalid .mmtile filename.' }
            $tileMapIds[$item.Name.Substring(0, 3)] = $true
            $mmtileCount++
            if ([long]$item.Length -lt $Descriptor.MmtileHeaderBytes) { throw 'MMAPS payload contains a truncated .mmtile record.' }
            $stream = [System.IO.File]::OpenRead($item.FullName)
            try {
                $header = New-Object byte[] 20
                if ($stream.Read($header, 0, 20) -ne 20 -or
                    ([BitConverter]::ToString($header, 0, 4).Replace('-', '')) -cne $Descriptor.MmtileHeaderHex -or
                    [BitConverter]::ToUInt32($header, 4) -ne $Descriptor.DetourVersion -or
                    [BitConverter]::ToUInt32($header, 8) -ne $Descriptor.MmapVersion -or
                    [BitConverter]::ToUInt32($header, 12) -ne ([long]$item.Length - $Descriptor.MmtileHeaderBytes) -or
                    [BitConverter]::ToUInt32($header, 16) -ne 1) {
                    throw 'MMAPS payload contains a .mmtile with an invalid header.'
                }
            } finally {
                $stream.Dispose()
            }
        } else {
            throw 'MMAPS payload contains an unrelated file.'
        }
        if ($payloadBytes -gt ([long]::MaxValue - [long]$item.Length)) { throw 'MMAPS payload size overflow.' }
        $payloadBytes += [long]$item.Length
    }
    if ($mmapCount -ne $Descriptor.MmapCount -or $mmtileCount -ne $Descriptor.MmtileCount -or
        ($mmapCount + $mmtileCount) -ne $Descriptor.FileCount) {
        throw 'MMAPS payload file counts do not match its descriptor.'
    }
    foreach ($mapId in $tileMapIds.Keys) {
        if (-not $mapIds.ContainsKey($mapId)) { throw 'MMAPS payload contains a tile without its map header.' }
    }
    if ($payloadBytes -ne $Descriptor.PayloadBytes) { throw 'MMAPS payload byte count does not match its descriptor.' }
    return [pscustomobject]@{ FileCount = $mmapCount + $mmtileCount; PayloadBytes = $payloadBytes }
}

function Write-ZRotMmapsReceipt {
    param([string]$StagePath, $Descriptor)
    $receipt = [ordered]@{
        schemaVersion = 1
        build = $Descriptor.Build
        archiveUrl = $Descriptor.ArchiveUrl
        archiveSha256 = $Descriptor.ArchiveSha256
        payloadBytes = $Descriptor.PayloadBytes
        mmapCount = $Descriptor.MmapCount
        mmtileCount = $Descriptor.MmtileCount
        installedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    $receiptPath = Join-Path $StagePath $script:MmapsReceiptName
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($receiptPath, ($receipt | ConvertTo-Json), $encoding)
}

function Test-ZRotMmapsCurrent {
    param([string]$TargetPath, $Descriptor)
    $receiptPath = Join-Path $TargetPath $script:MmapsReceiptName
    if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) { return $false }
    try {
        $receipt = [System.IO.File]::ReadAllText($receiptPath) | ConvertFrom-Json
        if ([string]$receipt.build -cne $Descriptor.Build -or
            ([string]$receipt.archiveSha256).ToLowerInvariant() -cne $Descriptor.ArchiveSha256 -or
            [long]$receipt.payloadBytes -ne $Descriptor.PayloadBytes -or
            [long]$receipt.mmapCount -ne $Descriptor.MmapCount -or
            [long]$receipt.mmtileCount -ne $Descriptor.MmtileCount) { return $false }
        Test-ZRotMmapsPayload $TargetPath $Descriptor | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Publish-ZRotMmapsStage {
    param([string]$StagePath, [string]$TargetPath, [string]$ApepDir)

    $safety = Test-ZRotMmapsTargetSafety $TargetPath $ApepDir
    if (-not $safety.Safe) { throw $safety.Reason }
    $target = $safety.Path
    $parent = Split-Path -Parent $target
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }

    $backup = "$target.zrot-old-$([guid]::NewGuid().ToString('N'))"
    $movedOld = $false
    try {
        if (Test-Path -LiteralPath $target) {
            Move-Item -LiteralPath $target -Destination $backup
            $movedOld = $true
        }
        Move-Item -LiteralPath $StagePath -Destination $target
    } catch {
        if ($movedOld -and -not (Test-Path -LiteralPath $target) -and (Test-Path -LiteralPath $backup)) {
            Move-Item -LiteralPath $backup -Destination $target -ErrorAction SilentlyContinue
        }
        throw
    }

    $leftoverBackup = $null
    if ($movedOld -and (Test-Path -LiteralPath $backup)) {
        try { Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction Stop } catch { $leftoverBackup = $backup }
    }
    return [pscustomobject]@{ TargetPath = $target; LeftoverBackup = $leftoverBackup }
}

function Install-ZRotMmapsArchive {
    param([string]$ArchivePath, $Descriptor, [string]$TargetPath, [string]$ApepDir,
          [scriptblock]$OnProgress, [scriptblock]$OnLog)

    $safety = Test-ZRotMmapsTargetSafety $TargetPath $ApepDir
    if (-not $safety.Safe) { throw $safety.Reason }
    $space = Test-ZRotMmapsDiskSpace $Descriptor $safety.Path
    if (-not $space.Known) { throw 'Unable to determine free disk space for the MMAPS target.' }
    if (-not $space.Enough) {
        throw ("Not enough disk space for MMAPS (need {0:N1} GB free; found {1:N1} GB)." -f
            ($space.RequiredBytes / 1GB), ($space.AvailableBytes / 1GB))
    }

    Invoke-ZRotMmapsLog $OnLog 'Verifying the MMAPS archive size and full SHA-256...'
    Invoke-ZRotMmapsProgress $OnProgress 50 'Verifying MMAPS archive'
    $hashProgress = {
        param($current, $total)
        $percent = 50
        if ($total -gt 0) { $percent = 50 + [int][Math]::Floor((4.0 * $current) / $total) }
        Invoke-ZRotMmapsProgress $OnProgress $percent ("Verifying MMAPS SHA-256 ({0:N1}/{1:N1} GB)" -f ($current / 1GB), ($total / 1GB))
    }.GetNewClosure()
    Test-ZRotMmapsArchive $ArchivePath $Descriptor $hashProgress | Out-Null
    Invoke-ZRotMmapsLog $OnLog 'MMAPS archive SHA-256 and manifest metadata verified.'

    $parent = Split-Path -Parent $safety.Path
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $stage = Join-Path $parent ('.zrot-mmaps-stage-' + [guid]::NewGuid().ToString('N'))
    try {
        Invoke-ZRotMmapsLog $OnLog 'Extracting MMAPS into a staging directory...'
        Expand-ZRotMmapsArchiveStaged $ArchivePath $stage $Descriptor $OnProgress
        Invoke-ZRotMmapsLog $OnLog 'Validating staged MMAPS headers, counts, and bytes...'
        Invoke-ZRotMmapsProgress $OnProgress 92 'Validating extracted MMAPS'
        Test-ZRotMmapsPayload $stage $Descriptor | Out-Null
        Write-ZRotMmapsReceipt $stage $Descriptor
        Invoke-ZRotMmapsLog $OnLog ("Validated {0} MMAPS files ({1:N0} bytes)." -f $Descriptor.FileCount, $Descriptor.PayloadBytes)
        Invoke-ZRotMmapsLog $OnLog 'Publishing the validated MMAPS directory...'
        $published = Publish-ZRotMmapsStage $stage $safety.Path $ApepDir
        Invoke-ZRotMmapsProgress $OnProgress 98 'Publishing MMAPS'
        return $published
    } finally {
        if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Set-ZRotApepMmapsPath {
    param([string]$ApepDir, [string]$TargetPath)

    $configPath = Join-Path $ApepDir 'Apep.json'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        return [pscustomobject]@{ Success = $false; Changed = $false; BackupPath = $null; Reason = 'Apep.json was not found.' }
    }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($configPath)
        $hadBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        $text = [System.IO.File]::ReadAllText($configPath)
        $state = Get-ZRotMmapsConfigState $text
        if (-not $state.Safe) {
            return [pscustomobject]@{ Success = $false; Changed = $false; BackupPath = $null; Reason = 'Settings.mmaps was not uniquely and safely editable.' }
        }
        if ($state.Value -ceq $TargetPath) {
            return [pscustomobject]@{ Success = $true; Changed = $false; BackupPath = $null; Reason = $null }
        }

        $pattern = New-Object System.Text.RegularExpressions.Regex('((?<!\\)"mmaps"\s*:\s*)("(?:\\["\\/bfnrt]|\\u[0-9a-fA-F]{4}|[^"\\\x00-\x1F])*")')
        $encoded = ConvertTo-Json -InputObject ([string]$TargetPath) -Compress
        $evaluator = [System.Text.RegularExpressions.MatchEvaluator]{ param($match) $match.Groups[1].Value + $encoded }
        $newText = $pattern.Replace($text, $evaluator, 1)
        $verify = Get-ZRotMmapsConfigState $newText
        if (-not $verify.Safe -or $verify.Value -cne $TargetPath) {
            return [pscustomobject]@{ Success = $false; Changed = $false; BackupPath = $null; Reason = 'Settings.mmaps replacement could not be verified.' }
        }

        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $backupPath = "$configPath.zrot-mmaps-$stamp.bak"
        if (Test-Path -LiteralPath $backupPath) { $backupPath = "$configPath.zrot-mmaps-$stamp-$([guid]::NewGuid().ToString('N')).bak" }
        $tempPath = "$configPath.zrot-mmaps-$([guid]::NewGuid().ToString('N')).tmp"
        Copy-Item -LiteralPath $configPath -Destination $backupPath -ErrorAction Stop
        try {
            $encoding = New-Object System.Text.UTF8Encoding($hadBom)
            [System.IO.File]::WriteAllText($tempPath, $newText, $encoding)
            Move-Item -LiteralPath $tempPath -Destination $configPath -Force
        } finally {
            if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue }
        }
        return [pscustomobject]@{ Success = $true; Changed = $true; BackupPath = $backupPath; Reason = $null }
    } catch {
        return [pscustomobject]@{ Success = $false; Changed = $false; BackupPath = $null; Reason = 'Apep.json could not be updated safely.' }
    }
}

function Enable-ZRotTls12 {
    try {
        $null = [System.Net.ServicePointManager]::SecurityProtocol =
            [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
    } catch {
        # A current Windows TLS default may already be in effect.
    }
}

function Get-ZRotMmapsDescriptorText {
    Enable-ZRotTls12
    $request = [System.Net.HttpWebRequest]::Create($script:MmapsDescriptorUrl)
    $request.Method = 'GET'
    $request.UserAgent = 'Z-Rotations-Installer'
    $request.AllowAutoRedirect = $true
    $request.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
    $request.UseDefaultCredentials = $false
    $request.PreAuthenticate = $false
    $request.Timeout = 60000
    $response = $null
    $reader = $null
    try {
        $response = $request.GetResponse()
        if ($response.ContentLength -gt 65536) { throw 'MMAPS descriptor is too large.' }
        $reader = New-Object System.IO.StreamReader($response.GetResponseStream(), [Text.Encoding]::UTF8, $true)
        $builder = New-Object System.Text.StringBuilder
        $buffer = New-Object char[] 4096
        while (($read = $reader.Read($buffer, 0, $buffer.Length)) -gt 0) {
            if ($builder.Length -gt (65536 - $read)) { throw 'MMAPS descriptor is too large.' }
            $null = $builder.Append($buffer, 0, $read)
        }
        return $builder.ToString()
    } finally {
        if ($reader) { $reader.Dispose() }
        if ($response) { $response.Dispose() }
    }
}

function Save-ZRotMmapsDownload {
    param([string]$Url, [string]$Destination, [long]$ExpectedBytes, [scriptblock]$OnProgress)

    Enable-ZRotTls12
    $request = [System.Net.HttpWebRequest]::Create($Url)
    $request.Method = 'GET'
    $request.UserAgent = 'Z-Rotations-Installer'
    $request.AllowAutoRedirect = $true
    $request.UseDefaultCredentials = $false
    $request.PreAuthenticate = $false
    $request.Timeout = 60000
    $request.ReadWriteTimeout = 600000
    $response = $null
    $input = $null
    $output = $null
    try {
        $response = $request.GetResponse()
        if ($response.ContentLength -ge 0 -and [long]$response.ContentLength -ne $ExpectedBytes) {
            throw 'MMAPS server response size does not match the descriptor.'
        }
        $input = $response.GetResponseStream()
        $output = [System.IO.File]::Open($Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $buffer = New-Object byte[] 1048576
        [long]$downloaded = 0
        if ($OnProgress) { & $OnProgress 0 $ExpectedBytes }
        while (($read = $input.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $output.Write($buffer, 0, $read)
            $downloaded += $read
            if ($downloaded -gt $ExpectedBytes) { throw 'MMAPS download exceeded its declared size.' }
            if ($OnProgress) { & $OnProgress $downloaded $ExpectedBytes }
        }
        $output.Flush()
        if ($downloaded -ne $ExpectedBytes) { throw 'MMAPS download was incomplete.' }
    } catch {
        if ($output) { $output.Dispose(); $output = $null }
        if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue }
        throw
    } finally {
        if ($output) { $output.Dispose() }
        if ($input) { $input.Dispose() }
        if ($response) { $response.Dispose() }
    }
}

function Invoke-ZRotMmapsInstall {
    param([string]$ApepDir, [scriptblock]$OnProgress, [scriptblock]$OnLog)

    Invoke-ZRotMmapsProgress $OnProgress 0 'Fetching MMAPS descriptor'
    $descriptor = ConvertFrom-ZRotMmapsDescriptor (Get-ZRotMmapsDescriptorText)
    Invoke-ZRotMmapsLog $OnLog ("MMAPS descriptor verified for build {0}." -f $descriptor.Build)
    $resolved = Resolve-ZRotMmapsTarget $ApepDir
    $safety = Test-ZRotMmapsTargetSafety $resolved.Path $ApepDir
    if (-not $safety.Safe) { throw $safety.Reason }
    Invoke-ZRotMmapsLog $OnLog ("MMAPS target: {0} ({1})." -f $safety.Path, $resolved.Source)
    if ($resolved.Source -ceq 'migrated-from-apep-folder') {
        Invoke-ZRotMmapsLog $OnLog 'NOTE: MMAPS inside the Apep folder cause NavSrv permission errors, so the maps now install to the drive root and Apep.json is updated. The old mmaps folder under Apep can be deleted to reclaim disk space.'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $ApepDir 'NavSrv.exe') -PathType Leaf)) {
        Invoke-ZRotMmapsLog $OnLog 'WARNING: NavSrv.exe was not found in the Apep folder; navigation will not work until it is installed.'
    }

    if (Test-ZRotMmapsCurrent $safety.Path $descriptor) {
        Invoke-ZRotMmapsLog $OnLog 'MMAPS are already current; skipping the archive download.'
        $configResult = Set-ZRotApepMmapsPath $ApepDir $safety.Path
        Invoke-ZRotMmapsProgress $OnProgress 100 'MMAPS already current'
        return [pscustomobject]@{ TargetPath = $safety.Path; AlreadyCurrent = $true; ConfigResult = $configResult; LeftoverBackup = $null }
    }

    $space = Test-ZRotMmapsDiskSpace $descriptor $safety.Path -IncludeArchive
    if (-not $space.Known) { throw 'Unable to determine free disk space for the MMAPS target.' }
    if (-not $space.Enough) {
        throw ("Not enough disk space for MMAPS (need {0:N1} GB free; found {1:N1} GB)." -f
            ($space.RequiredBytes / 1GB), ($space.AvailableBytes / 1GB))
    }
    Invoke-ZRotMmapsLog $OnLog ("Disk-space preflight passed ({0:N1} GB required)." -f ($space.RequiredBytes / 1GB))

    $parent = Split-Path -Parent $safety.Path
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $archivePath = Join-Path $parent ('.zrot-mmaps-download-' + [guid]::NewGuid().ToString('N') + '.zip')
    try {
        Invoke-ZRotMmapsLog $OnLog ("Downloading one MMAPS release archive ({0:N1} GB compressed)." -f ($descriptor.ArchiveBytes / 1GB))
        $downloadProgress = {
            param($current, $total)
            $percent = 2
            if ($total -gt 0) { $percent = 2 + [int][Math]::Floor((48.0 * $current) / $total) }
            Invoke-ZRotMmapsProgress $OnProgress $percent ("Downloading MMAPS ({0:N1}/{1:N1} GB)" -f ($current / 1GB), ($total / 1GB))
        }.GetNewClosure()
        Save-ZRotMmapsDownload $descriptor.ArchiveUrl $archivePath $descriptor.ArchiveBytes $downloadProgress
        Invoke-ZRotMmapsLog $OnLog 'MMAPS archive download complete.'
        $published = Install-ZRotMmapsArchive $archivePath $descriptor $safety.Path $ApepDir $OnProgress $OnLog
        $configResult = Set-ZRotApepMmapsPath $ApepDir $published.TargetPath
        Invoke-ZRotMmapsProgress $OnProgress 100 'MMAPS installed'
        return [pscustomobject]@{
            TargetPath = $published.TargetPath
            AlreadyCurrent = $false
            ConfigResult = $configResult
            LeftoverBackup = $published.LeftoverBackup
        }
    } finally {
        if (Test-Path -LiteralPath $archivePath) { Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue }
    }
}

# --- Task 3: themed WPF GUI ---

# Base64 PNG payload for the sidebar logo mark (media/zrotations/icons/zeon-nobg.png).
# Embedded so the installer works standalone via `irm <url> | iex` with no extra fetch.
$script:ZRotLogoBase64 = 'iVBORw0KGgoAAAANSUhEUgAAAtAAAALRCAYAAAByC5Q5AAAZNElEQVR42u3dW4xU933A8d9/ZnbZxeAh9tbUxAY7sXORRZQoclslqZBlKxVKJZRIuDKWHxaowS2OHzZSwGYtGUiIbzEhhtgES43UvuQhechLKzUPrZQ+pFIe0tptbKdyWgc3OLjmtgsG5t+Hnd0ddm5nYbks8/lIaHduZ+b85jD7naOzs2loaHkAAADFlIwAAAAENAAACGgAABDQAAAgoAEAQEADAICANgIAABDQAAAgoAEAQEADAICABgAAAQ0AAALaCAAAQEADAICABgAAAQ0AAAIaAAAENAAACGgjAAAAAQ0AAAIaAAAENAAACGgAABDQAAAgoI0AAAAENAAACGgAABDQAAAgoAEAQEADAICANgIAABDQAAAgoAEAQEADAICABgAAAQ0AAALaCAAAQEADAICABgAAAQ0AAAIaAAAENAAACGgjAAAAAQ0AAAIaAAAENAAACGgAABDQAAAgoI0AAAAENAAACGgAABDQAAAgoAEAQEADAICANgIAABDQAAAgoAEAQEADAICABgAAAQ0AAALaCAAAQEADAICABgAAAQ0AAAIaAAAENAAACGgjAAAAAQ0AAAIaAAAENAAACGgAABDQAAAgoI0AAAAENAAACGgAABDQAAAgoAEAQEADAICANgIAABDQAAAgoAEAQEADAICABgAAAQ0AAALaCAAAQEADAICABgAAAQ0AAAIaAAAENAAACGgjAAAAAQ0AAAIaAAAENAAACGgAABDQAAAgoI0AAAAENAAACGgAABDQAAAgoAEAQEADAICANgIAABDQAAAgoAEAQEADAICABgAAAQ0AAALaCAAAQEADAICABgAAAQ0AAAIaAAAENAAACGgjAAAAAQ0AAAIaAAAENAAACGgAABDQAAAgoI0AAAAENAAACGgAABDQAAAgoAEAQEADAICANgIAABDQAAAgoAEAQEADAMA8UjECLtTaB9blJUuqEydSmvgSkyfT1KmUGr6mFufVr1n/tumySKn5vMllR4rps5qX3W6ZKRofSzQtO6UOj31qvXLD/TQ/5pmXRZ65zNbXn3lZipnLbjGHFvc3ebvzH0u24QI978033og9zz6bTAIBzWX3Fw88EDd/+MMGAcC8Ui6XDYFwCAcAAAhoAAAQ0AAAIKABAEBAAwAAAhoAAAQ0AAAIaAAAENAAACCgAQBAQAMAAAIaAAAENAAACGgAABDQAAAgoAEAQEADAAACGgAABDQAAAhoAAAQ0AAAIKABAEBAAwAAAhoAAAQ0V0SObAgAgIAGAAAENAAACGgAABDQAAAgoAEAQEADAMw/KZkBAhoAAAQ0AAAIaAAAENAAACCgAQAAAQ0AAAIaAAAENAAACGgAABDQAAAgoAEAAAENAAACGgAABDQAAAhoAAAQ0AAAIKABAAABDQAAAhoAAAQ0V72csyEAAAIaAAAQ0AAAIKABAEBAAwCAgAYAAAENAAACGgAAENAAACCgAQBAQAMAgIAGAAABDQAw76SUDAEBDQAAAhoAAAQ0AAAIaAAAENAAAICABgAAAQ0AAAIaAAAENAAACGgAABDQAACAgAYAAAHNlZFzNgQAQEADAAACGgAABDQAAAhoAAAQ0AAAIKABAEBAAwAAAhoAAAQ0AAAIaAAAENAAACCgAQBAQAMAAAIaAAAENAAACGgAABDQAAAgoAEAQEADAFzTcjIDBDQAAAhoAAAQ0AAAIKABAEBAAwAAzSpGwIV69d/+Pd49fNgg5qmUUqSUpr6vf3P+6Xz+6emrtbvdjMsjtbz+5PUavml9vWh3P7nNclvfvv39FFyfLusxeToXXI9Zr0/99v0LFthwAQQ089mO0e0+Bwh6SH//gi5vXM57nzLrNxJd3+BE6zdgqf4OpPAbnEjF3oC1W58ut8+F16Pt+nR+wxZND6zg+uRCz/PmLV+Nu1auvMb3IGT/oRHQAFx6H3xw+qrNIc/O3BjZui1f8/Hsc6AJx0ADAHMUz19Zu9YgQEADAN08NjIinkFAAwBF4/n+dQ8aBAhoAEA8g4AGAMQzCGgA4PLavOVR8QwCGgAoYuPmzfmh4eHeHoLPgUZAAwBFrH94Ux7+y4cNwudAI6ABgG4eGh7OGzZtMggQ0ABAkXjevOVRgwABDQCIZxDQAIB4BgENAIhnENAAgHgGAQ0AiGdAQAOAeAYENAAgnkFAAwDiGQQ0ACCeQUADAOJ5HiqX5Q8CGgDEMyCgAYDW7l/3oHgGAQ0AFI3nx0ZGDAIENAAgnkFAAwDiGQQ0ACCeQUADAFelL69dK55BQAMAReP5a1u3GQQIaABAPIOABgDEMwhoAEA8AwIaAK5KX1qzRjyDgAYAisbzttEnDQIENABQNJ5TSoYBAhoAEM8goAEA8QwCGgC4fL64erV4BgENABSN59EdO8UzCGgAoGg8l0p+BIOABgDEMwhoAEA8AwIaAC6je+69TzyDgAYAisbzU7t3i2cQ0ABA0Xgul8uGAQIaABDP0JsqRgAUNZgjbqtVsknQyn+XzqWTyeYhnkFAA0zF89bxav5Irc8waPKzyuk4MHDcICLiC6tWiWcQ0IB4jnhifEleUfOSQdt4TjWjiC+sWpW/8cyz4hnCMdCAeBbPiOeC8Vyp+L8CYQ800Kuuyym2jVfFM+JZPAMCGigSz9vHqvmW7GUC8SyegXAIByCeuVA/F89T/vhznxfPEPZAAz1uca0Uj49fL55pG8/7xPNUPH/r+W+LZxDQQK/H8+h4Nd+cfYIA4rlIPPf3+1hHENBAz6rWUjwhnhHP4hkQ0ECxeH5yfEm+STwjnsUzEH6JEBDPXLBflMXzpM/efbd4BiLCHmjoaTfUSvHEeFU80zae9w6K58l4fu47e8UzIKCh1+N5+3g1/4F4pkM8nzOK6XhesMAwgIhwCAeIZxDP4hkIe6CBtoZyKZ44Vc1D4pk28fzC4PFkEuIZENBA1I95PlXNQzXxTLNf1vc8m0TEpz79GfEMhEM4QDzHqHimQzzvcdjGVDy/sO9F8QwIaBDP4pnO8XzGKKbieWBg0DAAAQ3iWTwjnsUzIKAB8Yx4Fs+AgAbEM+L58rlr5UrxDAhoEM/imfZeLZ0Rzw3xvGf/fvEMCGgQz+KZ9vH8/OBR8dwQzwsXXmcYgIAG8Sye6RDPPulZPAMCGhDPiGfxDAhoQDwjnufYxz/xSfEMhD/lDeJZPNPW6+Uz8fyAeJ6M570vvSyegbAHGsSzeKZtPD89cEw8N8TzosWLDAMQ0CCexTPt4/mDlMWzeAYENCCeEc/iGRDQgHhGPM+pj9xxp3gGBDSIZ/GMeC7io3d+LL944IB4pqXTp08ZAgIaxDO97s2SeI6GPc/fffnlqFarNgyavHfkSHzzqR0GgYAG8UzPx/OgeJ6M5xcPHBDPtI3nTcPDcei3b/tsGgQ0XMuqtSSe6RrPp8SzeEY8E/6QCjARz+PVPJTFM+K5kxW33yaeEc+EPdAgnmN0vJqXZu9zEc/d4nn/9w+KZ8QzAhrEs3imtbdKZ8XzjHhe8qEbbBiIZwQ0iGfxTOt43j14VDyLZ8QzAhoQzxSN5zHxLJ4RzwhoQDwjnou65dbl4hnxjIAG8SyeEc+F4/mgeEY8I6BBPItn2vgf8dwUzzcODdkwEM8IaBDP4pnW8fxN8SyeEc8IaEA8UzyeT4hn8Yx4RkAD4hnxXNQfLlsmnhHPCGgQz+IZ8Vw0nr938BXxjHhGQIN4Fs+I56LxfNPSpTYMxDMCGsSzeKbZoXROPItnxDMCGhDPFI3nXeJZPCOeEdCAeKZ4PB8v1Xp+FjctXSqeEc8IaBDP4hnxXDSe94tnxDMCGsSzeEY8F4/nm5cts2EgnhHQIJ7FM81+l86KZ/FMAe8ePiyeuSr56Q5zbHGtFKPj14tn2sbzzsGj6XjJLwyKZ7rF819t3CieEdDQC/G8fbyal+ayYdA2no+K57jxxqEQz3SK50c2DMc7h94Rz4RDOKAH4nmZeEY8d4/nVw5m8Yx4RkCDeBbPiOeC8XzLrcttGIhnBDSIZ/GMeBbPiGfCMdCAeOZC/b50LnYOiGfxjHgm7IEGxDPiubglH7pBPCOeEdAgnsUz3eP5PZ/zPBHP3xfPiGcENIhn8Yx4LhzPK26/zYaBeEZAg3gWz4hn8Yx4RkAD4pkLdiSJZ/GMeEZAA+KZwvG8a1A8R0RUq1XxjHhGQIN4Fs90j+ffi+eoVqvx3QMHxDPiGQEN4lk8I56LxvNH77jThoF4RkCDeBbPiGfxjHgGAQ3imQv2fqqJZ/GMeEZAA+IZ8Tw7ixYvEs+IZwQ0iGfxTPd4/l3pnHhevCj2vvSyeEY8I6BBPItnxHPReP74Jz5pw0A8I6BBPItnxLN4RjyDgIbOQZCTeEY8i2fEMxRWMQJ6PZ4fF8+0cSydi12Dx8RzRCxcuFA8I54h7IFGPMfj49V8a837SFrH8zfE81Q879n/PfGMeAYBjXgWz3SO50PieSqe71q50oaBeAYBjXgWz4hn8Yx4BgEN4hnxLJ4RzyCgQTxzqZ2ImniuGxgYFM+IZxDQiGfxTLd4Piqe6/H8wr4XxTPiGQQ04lk80zme3y6L58l4/tSnP2PDQDyDgEY8i2fEs3hGPIOABvGMeBbPiGcQ0CCeudTGIovnuv7+BeIZ8QwCGvEsnukcz7sH3xfP9Xh+7jt7xTPiGQQ04lk80zme3xLPU/H82T+624aBeAYBjXgWz4hn8Yx4BgEN4hnxLJ4RzyCgQTwjni+fvv4+8Yx4hjmgOBDPXLNORS12Dx4Vz/V4/tbz3xbPiGcIe6ARz+KZtvH89OCxEM/T8fwnn/u8DQPxDAIa8SyeaR/Pb5bPJvEsnhHPIKDpeQvFM+JZPCOeQUBD8XjeJp4Rz11VKhXxjHgGAY14nojn28QzLZyOLJ4b4nnXM8+KZ8QzCGjEs3imfTw/M3BUPNftevqZ/KerVhkETd45dCg2b1gvniF8jB3iGfEcr1fE8+SeZ/FM63h+Jx7ZsD7ePXxYPEPYA414RjyLZ/FM13geFs8goBHPiGfxHBFRLpfFM+IZBDTiWTwjnovG81O7d4tnxDMIaMSzeKa1M+K5KZ7vufc+GwbiGcIvESKeDYOW8fzc4LF43adtiGfEM4Q90CCeKRTPr5XPiGfxjHgGAQ3iGfFc8EW7VBLPiGcQ0Ihn8Yx4LhrP23fsFM+IZxDQiGfxTJt4zuJ5Zjz/2erVNgzEMwhoxLN4pnU87xk8Lp7FM10c+u3b4hnCp3AgnhHPsWfwePyy8oF4Fs90iedNw8PpvSNHDAPsgUY8I57Fc0pJPCOeQUAjnsUz4rloPG8dfVI8I55BQCOexTOtnRPPTfH852vW2DAQzyCgEc/imdbxvFc8i2fEMwhomDAgnikQz78Qz+IZ8QwCGibi+evj14tnxHMB4hnxDAIa8RxfH78+31HrMwzEcxcjW7eJZ8QzCGjEs3hGPBeN56+sXWsQiGcQ0Ihn8Yx4Fs+IZxDQIJ65qHjeNyCexTPd/Oat34hnCH/KG/GMeI59A8fjX/vEs3imWzw/smF9Ovr+/xkGhD3QiGfEs3iOiMdGRsQz4hkENOJZPCOei8bz/eseNAjEMwhoxLN4pllNPItnxDMIaBDPFI/nl8WzeEY8g4CGaY+cWiSe6RjP/yKeIyJi85ZHxTPiGQQ0RAzlsiEgngvE80PDwwaBeAYBDSCexTPiGQQ0gHgWz4hnQEADl1oWz+fZsGmTeEY8g4AGaB/PBwdOiOe6h4aH8/qHNxkETf7r178WzxD+lDcgnuPgwIn4577T4rkez5u3PGoQtIznv964IR07dswwIOyBBsSzeBbPiGcQ0ADiWTwjngEBDcwR8Tzt/nUPimfEMwhogPb+ZoF4boznx0ZGDALxDAIaoH08/7TvlHgWz4hnENAA4lk8I54BAQ2IZ/GMeAYENCCer5Qvr10rnhHPgIAG2vvb/pPiuSGev7Z1m0EgngEBDbSP53/oHxfP4pkO3vjVr8QzhD/lDSCexTNF4/nhjenkiZOGAWEPNCCexbN4RjwDAhoQz8V9ac0a8Yx4BgQ0IJ6LxvO20ScNAvEMCGigtR+K56Z4Tsk4EM+AgAbaxPNPxLN4RjwDAhoQz+IZ8QwIaEA8XwJfXL1aPCOeAQENtPej/jHx3BDPozt2imfEMyCggdZ+3D8WP+4fU4sN8VwqeSnkfP/x6qviGQh/iRCIn/SNxY/Es3imazx/dfOmNDY2ZhhA2AMNPR7PP1wgnsUz4hkQ0Fwx2QjE8zx0z733iWfEMyCgAfFcNJ6f2r1bPCOeAQENiOei8Vwulw0D8QyEXyIExHMH1y26Llbcfnv84JWDkevHHuX6NzO/xtSXxoOUcpfbtDk/InKkWd125n01Hi7V7f5mrtt5l8WM9Wtzfy3XYeb9RrS8v1a3bbt+kTsuI1qtQ269TnnmA4pWt23zNXL852uviWdgVtLQ0HJT4ILsGluSV9S8BxPPABAO4QDEMwAgoOGa9/d94+IZAAQ0UDSe/27BSfEMAAIaEM8AIKAB8QwAAhoQzwAgoAHxDAAIaBDPAICABvEMAAhoQDwDgIAGxDMACGjg0vjHingGAAENFI7nHwyIZwAQ0IB4BgABDYhnABDQgHgGAAQ0iGcAQECDeAYABDSIZwBAQAPiGQAENCCeAUBAA5fIP1VOiWcAENBA0Xh+ZeCEeAYAAU2vyEZw0fFshgAgoAHxDAACGhDPAICABvEMAAhoEM8AgIAG8QwACGgQzwCAgAbEMwAIaGB2flY5LZ4BQEADReP5wMBx8QwAAhooGs81owAAAQ2IZwBAQIN4BgAENIhnAEBAg3gGAAQ0iGcAQECDeAYABDQw4efiGQAENFA8nveJZwAQ0IB4BgAENIhnAEBAg3gGAK6kihFAe2+ns/HTvlPxsbN9OUdEjhw5IiLFxNeIyBFp4rKGy+unaxGR0uRlE2qRI0eaus7M5UZuPH/68unrp4iUm5YZ9csab3MmeQ4BQEDDZXRLrsS28Wq3q2WTujhnZowwdx1wt+unWT1Bucvyuj7hqfPyosvjudjH1/32qePy0szHn2OOn4+Y5Tzm9vnodv3Zz7Pb8z3b+0udr5Hm7vF5sZrwXsrx0sBxuxgQ0MD81Rez/Tk21z/3LnJ5871KrrWqUol08b/prCEQjoEGAAABDQAAAhoAAAQ0AAAIaAAAQEADAICABgAAAQ0AAAIaAAAENAAACGgAAEBAAwCAgAYAAAENAAACGgAABDQAAAhoAABAQAMAgIAGAAABDQAAAhoAAAQ0AAAIaOiiFtkQAJh3khEgoAEAQEADAICABgAAAQ0AAAIaAAAQ0AAAIKABAEBAAwCAgAYAAAENAAACGgAAENAAACCgAQBAQAMAgIAGAAABDQAAAhoAABDQAAAgoAEAQEADAFwiyQgQ0AAAIKABAEBAAwCAgAYAAAENAAAIaAAAENAAACCgAQBAQAMAgIAGAAABDQAACGgAABDQAAAgoAEAQEADAICABgAAAQ0AAAhoAAAQ0FwZ2QgAmIeSESCgAQBAQAMAgIAGAAABDQAAAhoAABDQAAAgoAEAQEADAICABgAAAQ0AAAIaAAAQ0AAAIKABAEBAAwCAgAYAAAENAAACGgAAENAAACCgAQBAQDMPZCMAYB5KRoCABgAAAQ0AAAIaAAAENAAACGgAAEBAAwCAgAYAAAENAAACGgAABDQAAAhoAABAQAMAgIAGAAABDQAAAhoAAAQ0AAAIaAAAQEADAMBFqhgBF+qt0tk4k7JBAMw7KXKOmHgFz5Ejpv6lNHFOjlS/dPLf9Ov95HkRaeL8FFOXTl82udzUcFnDUlI0PIbG201fb/r0xP2kFDMe0/n3Ew2PtXG5ExflqcdyImo2AS7uf9DQ0HJTAACAcAgHAAAIaAAAENAAACCgAQBAQAMAgIAGAAAENAAACGgAABDQAAAgoAEAQEADAICABgAABDQAAAhoAAAQ0AAAIKABAEBAAwCAgAYAAAQ0AAAIaAAAENAAACCgAQBAQAMAgIAGAAAENAAACGgAABDQAAAgoAEAQEADAICABgAABDQAAAhoAAAQ0AAAIKABAEBAAwCAgAYAAAQ0AAAIaAAAENAAACCgAQBAQAMAgIAGAAAENAAACGgAABDQAAAgoAEAQEADAICABgAABDQAAAhoAAAQ0AAAIKABAEBAAwCAgAYAAAQ0AAAIaAAAENAAACCgAQBAQAMAgIAGAAAENAAACGgAABDQAAAgoAEAQEADAICABgAABDQAAAhoAAAQ0AAAIKABAEBAAwCAgAYAAAQ0AAAIaAAAENAAACCgAQBAQAMAgIAGAAAENAAACGgAABDQAAAgoAEAQEADAICABgAABDQAAAhoAAAQ0AAAIKABAEBAAwCAgAYAAAQ0AAAIaAAAENAAACCgAQBAQAMAgIAGAAAENAAACGgAABDQAAAgoAEAQEADAICABgAABDQAAAhoAAAQ0AAAIKABAEBAAwCAgAYAAAQ0AAAIaAAAENAAACCgAQBAQAMAgIAGAAAENAAACGgAABDQAAAgoAEAQEADAICABgAABDQAAAhoAAAQ0AAAIKABAEBAAwCAgAYAAAQ0AAAIaAAAENAAACCgAQDg2vP/r8SIUtLqJgwAAAAASUVORK5CYII='

function Get-ZRotInstallerXaml {
    return @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Z-Rotations Installer"
        Width="760" Height="620" MinWidth="680" MinHeight="540"
        WindowStartupLocation="CenterScreen"
        Background="#131519"
        FontFamily="Montserrat, Segoe UI Semibold"
        FontSize="13"
        Foreground="#DCDEE4">
    <Window.Resources>
        <SolidColorBrush x:Key="BrushWindow" Color="#131519"/>
        <SolidColorBrush x:Key="BrushSidebar" Color="#14181E"/>
        <SolidColorBrush x:Key="BrushContent" Color="#111217"/>
        <SolidColorBrush x:Key="BrushCard" Color="#16151C"/>
        <SolidColorBrush x:Key="BrushInput" Color="#0B0C11"/>
        <SolidColorBrush x:Key="BrushAccent" Color="#B70832"/>
        <SolidColorBrush x:Key="BrushAccentHover" Color="#C0264B"/>
        <SolidColorBrush x:Key="BrushText" Color="#DCDEE4"/>
        <SolidColorBrush x:Key="BrushMuted" Color="#737680"/>
        <SolidColorBrush x:Key="BrushSuccess" Color="#4DC778"/>
        <SolidColorBrush x:Key="BrushError" Color="#ED4052"/>
        <SolidColorBrush x:Key="BrushBorder" Color="#202027"/>
        <SolidColorBrush x:Key="BrushStepLine" Color="#202027"/>

        <Style x:Key="SidebarWordmark" TargetType="TextBlock">
            <Setter Property="FontSize" Value="17"/>
            <Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="Foreground" Value="{StaticResource BrushText}"/>
            <Setter Property="HorizontalAlignment" Value="Center"/>
        </Style>

        <Style x:Key="StepLabel" TargetType="TextBlock">
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Foreground" Value="{StaticResource BrushMuted}"/>
            <Setter Property="VerticalAlignment" Value="Center"/>
        </Style>

        <Style x:Key="PathLabel" TargetType="TextBlock">
            <Setter Property="FontSize" Value="11"/>
            <Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="Foreground" Value="{StaticResource BrushMuted}"/>
            <Setter Property="VerticalAlignment" Value="Center"/>
        </Style>

        <Style x:Key="PathBox" TargetType="TextBox">
            <Setter Property="Background" Value="{StaticResource BrushInput}"/>
            <Setter Property="Foreground" Value="{StaticResource BrushText}"/>
            <Setter Property="BorderBrush" Value="{StaticResource BrushBorder}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="FontFamily" Value="Consolas"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="Padding" Value="8,6"/>
            <Setter Property="IsReadOnly" Value="True"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
            <Setter Property="Focusable" Value="True"/>
        </Style>

        <Style x:Key="GlyphText" TargetType="TextBlock">
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="HorizontalAlignment" Value="Center"/>
            <Setter Property="VerticalAlignment" Value="Center"/>
            <Setter Property="Foreground" Value="{StaticResource BrushMuted}"/>
        </Style>

        <Style x:Key="SecondaryButton" TargetType="Button">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="{StaticResource BrushText}"/>
            <Setter Property="BorderBrush" Value="{StaticResource BrushBorder}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="10,6"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="Bd" Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="2">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="BorderBrush" Value="{StaticResource BrushAccent}"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Foreground" Value="{StaticResource BrushMuted}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="AccentButton" TargetType="Button">
            <Setter Property="Background" Value="{StaticResource BrushAccent}"/>
            <Setter Property="Foreground" Value="{StaticResource BrushText}"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="18,10"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="3">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="{StaticResource BrushAccentHover}"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="Bd" Property="Background" Value="{StaticResource BrushBorder}"/>
                                <Setter Property="Foreground" Value="{StaticResource BrushMuted}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="AccentProgressBar" TargetType="ProgressBar">
            <Setter Property="Background" Value="{StaticResource BrushInput}"/>
            <Setter Property="Foreground" Value="{StaticResource BrushAccent}"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Height" Value="4"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ProgressBar">
                        <Grid>
                            <Border Background="{TemplateBinding Background}" CornerRadius="2"/>
                            <Grid ClipToBounds="True">
                                <Border x:Name="PART_Indicator" Background="{TemplateBinding Foreground}"
                                        CornerRadius="2" HorizontalAlignment="Left"/>
                            </Grid>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="LogBoxStyle" TargetType="TextBox">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="{StaticResource BrushMuted}"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="FontFamily" Value="Consolas"/>
            <Setter Property="FontSize" Value="11"/>
            <Setter Property="IsReadOnly" Value="True"/>
            <Setter Property="TextWrapping" Value="Wrap"/>
            <Setter Property="AcceptsReturn" Value="True"/>
            <Setter Property="VerticalScrollBarVisibility" Value="Auto"/>
        </Style>

        <Style x:Key="OptionalCheckBox" TargetType="CheckBox">
            <Setter Property="Foreground" Value="{StaticResource BrushText}"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="CheckBox">
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="20"/>
                                <ColumnDefinition Width="*"/>
                            </Grid.ColumnDefinitions>
                            <Border x:Name="Box" Width="14" Height="14" CornerRadius="2"
                                    Background="{StaticResource BrushInput}"
                                    BorderBrush="{StaticResource BrushMuted}" BorderThickness="1">
                                <TextBlock x:Name="Mark" Text="&#x2713;" FontSize="11" FontWeight="Bold"
                                           Foreground="{StaticResource BrushText}" HorizontalAlignment="Center"
                                           VerticalAlignment="Center" Visibility="Collapsed"/>
                            </Border>
                            <ContentPresenter Grid.Column="1" Margin="6,0,0,0" VerticalAlignment="Center"/>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="Box" Property="Background" Value="{StaticResource BrushAccent}"/>
                                <Setter TargetName="Box" Property="BorderBrush" Value="{StaticResource BrushAccent}"/>
                                <Setter TargetName="Mark" Property="Visibility" Value="Visible"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Box" Property="BorderBrush" Value="{StaticResource BrushAccent}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>

    <Grid>
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="216"/>
            <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>

        <!-- Sidebar -->
        <Border Grid.Column="0" Background="{StaticResource BrushSidebar}">
            <Grid Margin="0,28,0,20">
                <Grid.RowDefinitions>
                    <RowDefinition Height="*"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>

                <StackPanel Grid.Row="0" Margin="24,0,24,0">
                    <Image x:Name="LogoImage" Width="52" Height="52" HorizontalAlignment="Center"/>
                    <TextBlock Text="Z-ROTATIONS" Style="{StaticResource SidebarWordmark}" Margin="0,14,0,2"/>
                    <TextBlock Text="INSTALLER" FontSize="10" Foreground="{StaticResource BrushMuted}"
                               HorizontalAlignment="Center" Margin="0,0,0,36"/>

                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="20"/>
                            <ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="32"/>
                            <RowDefinition Height="32"/>
                            <RowDefinition Height="32"/>
                        </Grid.RowDefinitions>

                        <Border Grid.Column="0" Grid.Row="0" Grid.RowSpan="3" Width="2"
                                Background="{StaticResource BrushStepLine}" Margin="0,6,0,6"/>

                        <Ellipse x:Name="StepDotDetect" Grid.Column="0" Grid.Row="0" Width="10" Height="10"
                                 Fill="{StaticResource BrushAccent}" HorizontalAlignment="Center"/>
                        <TextBlock x:Name="StepLabelDetect" Grid.Column="1" Grid.Row="0" Text="Detect"
                                   Style="{StaticResource StepLabel}" Foreground="{StaticResource BrushAccent}" Margin="10,0,0,0"/>

                        <Ellipse x:Name="StepDotInstall" Grid.Column="0" Grid.Row="1" Width="10" Height="10"
                                 Fill="{StaticResource BrushMuted}" HorizontalAlignment="Center"/>
                        <TextBlock x:Name="StepLabelInstall" Grid.Column="1" Grid.Row="1" Text="Install"
                                   Style="{StaticResource StepLabel}" Margin="10,0,0,0"/>

                        <Ellipse x:Name="StepDotDone" Grid.Column="0" Grid.Row="2" Width="10" Height="10"
                                 Fill="{StaticResource BrushMuted}" HorizontalAlignment="Center"/>
                        <TextBlock x:Name="StepLabelDone" Grid.Column="1" Grid.Row="2" Text="Done"
                                   Style="{StaticResource StepLabel}" Margin="10,0,0,0"/>
                    </Grid>
                </StackPanel>

                <TextBlock x:Name="VersionText" Grid.Row="1" Text="" FontSize="10"
                           Foreground="{StaticResource BrushMuted}" HorizontalAlignment="Center"/>
            </Grid>
        </Border>

        <!-- Content -->
        <Grid Grid.Column="1" Background="{StaticResource BrushContent}" Margin="28,26,28,24">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
            </Grid.RowDefinitions>

            <StackPanel Grid.Row="0" Margin="0,0,0,18">
                <TextBlock Text="Set up Z-Rotations" FontSize="20" FontWeight="Bold" Foreground="{StaticResource BrushText}"/>
                <TextBlock Text="Detects your Apep and WoW folders, then installs the rotation plugin and UI assets."
                           FontSize="12" Foreground="{StaticResource BrushMuted}" Margin="0,6,0,0" TextWrapping="Wrap"/>
            </StackPanel>

            <Border Grid.Row="1" Background="{StaticResource BrushCard}" BorderBrush="{StaticResource BrushBorder}"
                    BorderThickness="1" CornerRadius="3" Padding="18">
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="60"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="84"/>
                        <ColumnDefinition Width="26"/>
                    </Grid.ColumnDefinitions>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="14"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>

                    <TextBlock Grid.Row="0" Grid.Column="0" Text="APEP" Style="{StaticResource PathLabel}"/>
                    <TextBox x:Name="ApepPathBox" Grid.Row="0" Grid.Column="1" Style="{StaticResource PathBox}" Margin="0,0,10,0" Text=""/>
                    <Button x:Name="BrowseApepButton" Grid.Row="0" Grid.Column="2" Content="Browse" Style="{StaticResource SecondaryButton}"/>
                    <TextBlock x:Name="ApepGlyph" Grid.Row="0" Grid.Column="3" Style="{StaticResource GlyphText}" Text="?"/>

                    <TextBlock Grid.Row="2" Grid.Column="0" Text="WOW" Style="{StaticResource PathLabel}"/>
                    <TextBox x:Name="WowPathBox" Grid.Row="2" Grid.Column="1" Style="{StaticResource PathBox}" Margin="0,0,10,0" Text=""/>
                    <Button x:Name="BrowseWowButton" Grid.Row="2" Grid.Column="2" Content="Browse" Style="{StaticResource SecondaryButton}"/>
                    <TextBlock x:Name="WowGlyph" Grid.Row="2" Grid.Column="3" Style="{StaticResource GlyphText}" Text="?"/>
                </Grid>
            </Border>

            <Border Grid.Row="2" Background="{StaticResource BrushCard}" BorderBrush="{StaticResource BrushBorder}"
                    BorderThickness="1" CornerRadius="3" Padding="14,11" Margin="0,14,0,0">
                <StackPanel>
                    <CheckBox x:Name="InstallMmapsCheckBox" IsChecked="False" Style="{StaticResource OptionalCheckBox}"
                              Content="Download MMAPS navigation data (optional)"/>
                    <TextBlock Text="Large download for build 335. Installs verified pathfinding maps and configures Apep."
                               FontSize="10" Foreground="{StaticResource BrushMuted}" Margin="20,5,0,0" TextWrapping="Wrap"/>
                </StackPanel>
            </Border>

            <Button x:Name="InstallButton" Grid.Row="3" Content="Install" Style="{StaticResource AccentButton}"
                    HorizontalAlignment="Right" Margin="0,18,0,0" MinWidth="180"/>

            <ProgressBar x:Name="InstallProgress" Grid.Row="4" Style="{StaticResource AccentProgressBar}"
                         Minimum="0" Maximum="100" Value="0" Margin="0,14,0,0"/>

            <Border Grid.Row="5" Background="{StaticResource BrushInput}" BorderBrush="{StaticResource BrushBorder}"
                    BorderThickness="1" CornerRadius="3" Padding="10" Margin="0,14,0,0">
                <ScrollViewer VerticalScrollBarVisibility="Auto">
                    <TextBox x:Name="LogBox" Style="{StaticResource LogBoxStyle}"/>
                </ScrollViewer>
            </Border>
        </Grid>
    </Grid>
</Window>
'@
}

# GUI helper functions live at SCRIPT scope (not nested in Start-ZRotInstaller):
# WPF event-handler script blocks run in a scope that cannot resolve nested
# functions, so under `irm | iex` a Browse/Install click would fail with
# "term is not recognized". They read the WPF controls through $script:z*
# references that Start-ZRotInstaller populates before showing the window.
function Write-ZRotLog {
    param([string]$Message)
    $stamp = Get-Date -Format 'HH:mm:ss'
    $script:zLogBox.AppendText("[$stamp] $Message`r`n")
    $script:zLogBox.ScrollToEnd()
}

function Set-ZRotStep {
    param([string]$Stage)
    if ($Stage -eq 'install' -or $Stage -eq 'done') {
        $script:zStepDotInstall.Fill = $script:zAccentBrush
        $script:zStepLabelInstall.Foreground = $script:zAccentBrush
    }
    if ($Stage -eq 'done') {
        $script:zStepDotDone.Fill = $script:zAccentBrush
        $script:zStepLabelDone.Foreground = $script:zAccentBrush
    }
}

function Update-ApepStatus {
    param([string]$Path)
    $script:zApepPathBox.Text = $Path
    if (Test-ApepDir $Path) {
        $script:zApepGlyph.Text = $script:zCheckGlyph
        $script:zApepGlyph.Foreground = $script:zSuccessBrush
        return $true
    } else {
        $script:zApepGlyph.Text = $script:zCrossGlyph
        $script:zApepGlyph.Foreground = $script:zErrorBrush
        return $false
    }
}

function Update-WowStatus {
    param([string]$Path)
    $script:zWowPathBox.Text = $Path
    if (Test-WowDir $Path) {
        $script:zWowGlyph.Text = $script:zCheckGlyph
        $script:zWowGlyph.Foreground = $script:zSuccessBrush
        return $true
    } else {
        $script:zWowGlyph.Text = $script:zCrossGlyph
        $script:zWowGlyph.Foreground = $script:zErrorBrush
        return $false
    }
}

function Update-InstallEnabled {
    $apepValid = Test-ApepDir $script:ZRotApepDir
    $wowValid = Test-WowDir $script:ZRotWowDir
    $script:zInstallButton.IsEnabled = (-not $script:ZRotInstallInProgress -and $apepValid -and $wowValid)
}

function Set-ZRotInstallBusy {
    param([bool]$Busy)
    $script:ZRotInstallInProgress = $Busy
    $script:zMmapsCheckBox.IsEnabled = -not $Busy
    $script:zBrowseApepButton.IsEnabled = -not $Busy
    $script:zBrowseWowButton.IsEnabled = -not $Busy
    Update-InstallEnabled
}

function Start-ZRotInstaller {
    param([switch]$NoShow)  # $NoShow: build + wire the window but skip ShowDialog (tests)
    $script:ZRotSuppressConfigWrites = [bool]$NoShow
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Xml

    $xamlText = Get-ZRotInstallerXaml
    $stringReader = New-Object System.IO.StringReader($xamlText)
    $xmlReader = [System.Xml.XmlReader]::Create($stringReader)
    $window = [Windows.Markup.XamlReader]::Load($xmlReader)

    $logoImage      = $window.FindName('LogoImage')
    $apepPathBox    = $window.FindName('ApepPathBox')
    $wowPathBox     = $window.FindName('WowPathBox')
    $apepGlyph      = $window.FindName('ApepGlyph')
    $wowGlyph       = $window.FindName('WowGlyph')
    $browseApepBtn  = $window.FindName('BrowseApepButton')
    $browseWowBtn   = $window.FindName('BrowseWowButton')
    $script:zBrowseApepButton = $browseApepBtn
    $script:zBrowseWowButton = $browseWowBtn
    $script:zMmapsCheckBox = $window.FindName('InstallMmapsCheckBox')
    $script:zInstallButton  = $window.FindName('InstallButton')
    $script:zInstallProgress = $window.FindName('InstallProgress')
    $logBox         = $window.FindName('LogBox')
    $versionText    = $window.FindName('VersionText')
    $stepDotInstall = $window.FindName('StepDotInstall')
    $stepLabelInstall = $window.FindName('StepLabelInstall')
    $stepDotDone    = $window.FindName('StepDotDone')
    $stepLabelDone  = $window.FindName('StepLabelDone')

    $versionText.Text = "v$ZRotInstaller_Version"

    if ($script:ZRotLogoBase64) {
        try {
            $logoBytes = [Convert]::FromBase64String($script:ZRotLogoBase64)
            $logoStream = New-Object System.IO.MemoryStream(,$logoBytes)
            $bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
            $bitmap.BeginInit()
            $bitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $bitmap.StreamSource = $logoStream
            $bitmap.EndInit()
            $bitmap.Freeze()
            $logoImage.Source = $bitmap
        } catch {
            # Non-fatal: proceed without the logo image.
        }
    }

    $accentBrush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0xB7,0x08,0x32))
    $successBrush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0x4D,0xC7,0x78))
    $errorBrush  = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0xED,0x40,0x52))
    $checkGlyph  = [string][char]0x2713
    $crossGlyph  = [string][char]0x2717

    # Share the controls/brushes the top-level GUI helpers use into $script:
    # scope so event-handler closures can drive them (see the helper functions
    # defined above Start-ZRotInstaller).
    $script:zLogBox = $logBox
    $script:zApepPathBox = $apepPathBox
    $script:zWowPathBox = $wowPathBox
    $script:zApepGlyph = $apepGlyph
    $script:zWowGlyph = $wowGlyph
    $script:zStepDotInstall = $stepDotInstall
    $script:zStepLabelInstall = $stepLabelInstall
    $script:zStepDotDone = $stepDotDone
    $script:zStepLabelDone = $stepLabelDone
    $script:zAccentBrush = $accentBrush
    $script:zSuccessBrush = $successBrush
    $script:zErrorBrush = $errorBrush
    $script:zCheckGlyph = $checkGlyph
    $script:zCrossGlyph = $crossGlyph

    # --- Initial detection ---
    $script:ZRotApepDir = Find-ApepDir
    $script:ZRotWowDir = $null

    $savedCfg = Read-ZRotInstallerConfig
    if (-not $script:ZRotApepDir -and $savedCfg -and $savedCfg.ApepDir) {
        if (Test-ApepDir $savedCfg.ApepDir) { $script:ZRotApepDir = $savedCfg.ApepDir }
    }
    if (-not $script:ZRotApepDir) { $script:ZRotApepDir = '' }

    $apepOk = Update-ApepStatus $script:ZRotApepDir

    if ($apepOk) {
        $jsonPath = Join-Path $script:ZRotApepDir 'Apep.json'
        if (Test-Path -LiteralPath $jsonPath) {
            try {
                $jsonText = Get-Content -Raw -LiteralPath $jsonPath
                $derivedWow = Get-WowDirFromApepJson $jsonText
                if ($derivedWow -and (Test-WowDir $derivedWow)) { $script:ZRotWowDir = $derivedWow }
            } catch {
                # Non-fatal: fall through to manual Browse.
            }
        }
    }
    if (-not $script:ZRotWowDir -and $savedCfg -and $savedCfg.WowDir) {
        if (Test-WowDir $savedCfg.WowDir) { $script:ZRotWowDir = $savedCfg.WowDir }
    }
    if (-not $script:ZRotWowDir) { $script:ZRotWowDir = '' }

    $wowOk = Update-WowStatus $script:ZRotWowDir

    Update-InstallEnabled

    if ($apepOk) { Write-ZRotLog "Apep folder detected: $script:ZRotApepDir" }
    else { Write-ZRotLog 'Apep folder not found automatically. Use Browse to select it.' }
    if ($wowOk) { Write-ZRotLog "WoW folder detected: $script:ZRotWowDir" }
    else { Write-ZRotLog 'WoW folder not found automatically. Use Browse to select it.' }

    Save-ZRotInstallerConfig $script:ZRotApepDir $script:ZRotWowDir

    # --- Browse handlers ---
    $browseApepBtn.Add_Click({
        if ($script:ZRotInstallInProgress) { return }
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = 'Select your Apep folder'
        if ($script:ZRotApepDir) { $dlg.SelectedPath = $script:ZRotApepDir }
        $result = $dlg.ShowDialog()
        if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
            $script:ZRotApepDir = $dlg.SelectedPath
            $apepOk2 = Update-ApepStatus $script:ZRotApepDir
            Update-InstallEnabled
            if ($apepOk2) { Write-ZRotLog "Apep folder set: $script:ZRotApepDir" }
            else {
                $missingItems = @(Get-ZRotMissingApepItems $script:ZRotApepDir)
                Write-ZRotLog "Selected folder does not look like an Apep install (missing $($missingItems -join ', ')): $script:ZRotApepDir"
            }
            Save-ZRotInstallerConfig $script:ZRotApepDir $script:ZRotWowDir
        }
    })

    $browseWowBtn.Add_Click({
        if ($script:ZRotInstallInProgress) { return }
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = 'Select your World of Warcraft folder'
        if ($script:ZRotWowDir) { $dlg.SelectedPath = $script:ZRotWowDir }
        $result = $dlg.ShowDialog()
        if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
            $script:ZRotWowDir = $dlg.SelectedPath
            $wowOk2 = Update-WowStatus $script:ZRotWowDir
            Update-InstallEnabled
            if ($wowOk2) { Write-ZRotLog "WoW folder set: $script:ZRotWowDir" }
            else { Write-ZRotLog "Selected folder does not look like a WoW install: $script:ZRotWowDir" }
            Save-ZRotInstallerConfig $script:ZRotApepDir $script:ZRotWowDir
        }
    })

    # --- Install / Update handler ---
    $script:zInstallButton.Add_Click({
        if ($script:ZRotInstallInProgress) { return }
        $installApepDir = $script:ZRotApepDir
        $installWowDir = $script:ZRotWowDir
        Set-ZRotInstallBusy $true
        try {
            if (-not (Test-ApepDir $installApepDir)) {
                Write-ZRotLog 'Cannot install: Apep folder is not valid.'
                return
            }
            if (-not (Test-WowDir $installWowDir)) {
                Write-ZRotLog 'Cannot install: WoW folder is not valid.'
                return
            }

            Set-ZRotStep 'install'
            $script:zInstallProgress.Value = 0
            Write-ZRotLog 'Fetching manifest...'

            $manifestUrl = Get-ZRotRemoteUrl 'manifest.txt'
            $manifestText = $null
            $oldProgressPref = $ProgressPreference
            try {
                $ProgressPreference = 'SilentlyContinue'
                $manifestText = (Invoke-WebRequest -Uri $manifestUrl -UseBasicParsing).Content
            } catch {
                Write-ZRotLog "Failed to download manifest: $($_.Exception.Message)"
                return
            } finally {
                $ProgressPreference = $oldProgressPref
            }

            try {
                $remote = ConvertFrom-ZRotManifest $manifestText
            } catch {
                Write-ZRotLog "Failed to validate manifest: $($_.Exception.Message)"
                return
            }
            if (-not (Test-ZRotManifestComplete $remote)) {
                Write-ZRotLog 'Failed to validate manifest: it is empty or missing Z-Rotations.enc.'
                return
            }

            $destinations = @{}
            foreach ($rel in $remote.Keys) {
                $plannedDestination = Get-ZRotDestination $rel $installApepDir $installWowDir
                if ($destinations.ContainsKey($plannedDestination)) {
                    Write-ZRotLog 'Failed to validate manifest: multiple files map to the same destination.'
                    return
                }
                $destinations[$plannedDestination] = $true
            }
            $localHashes = @{}
            foreach ($rel in $remote.Keys) {
                $dest = Get-ZRotDestination $rel $installApepDir $installWowDir
                $hash = Get-Sha1Short $dest
                if ($hash) { $localHashes[$rel] = $hash }
            }
            $plan = Get-ZRotPlan $remote $localHashes
            $relList = @($plan.Install) + @($plan.Update)

            if ($relList.Count -eq 0) {
                Write-ZRotLog 'Z-Rotations is already up to date.'
                $script:zInstallProgress.Maximum = 100
                $script:zInstallProgress.Value = 100
            } else {
                $script:zInstallProgress.Maximum = $relList.Count
                Write-ZRotLog "Installing $($relList.Count) Z-Rotations file(s)..."

                $progressHandler = {
                    param($i, $t, $rel, $ok)
                    $script:zInstallProgress.Value = $i
                    if ($ok) { Write-ZRotLog "  OK   $rel" }
                    else { Write-ZRotLog "  FAIL $rel" }
                    [System.Windows.Forms.Application]::DoEvents()
                }

                $result = Invoke-ZRotApply $remote $relList $installApepDir $installWowDir $progressHandler
                Write-ZRotLog "Z-Rotations files complete. $($result.Ok) succeeded, $($result.Failed.Count) failed."
                if ($result.Failed.Count -gt 0) {
                    foreach ($f in $result.Failed) { Write-ZRotLog "  Failed: $f" }
                    Write-ZRotLog 'Installation stopped because one or more files failed verification.'
                    return
                }
            }

            if ($script:zMmapsCheckBox.IsChecked -eq $true) {
                Write-ZRotLog 'Starting optional MMAPS installation...'
                $script:zInstallProgress.Minimum = 0
                $script:zInstallProgress.Maximum = 100
                $script:zInstallProgress.Value = 0
                $mmapsProgress = {
                    param($percent, $status)
                    $script:zInstallProgress.Value = [Math]::Max(0, [Math]::Min(100, $percent))
                    [System.Windows.Forms.Application]::DoEvents()
                }
                $mmapsLog = {
                    param($message)
                    Write-ZRotLog $message
                    [System.Windows.Forms.Application]::DoEvents()
                }
                try {
                    $mmapsResult = Invoke-ZRotMmapsInstall $installApepDir $mmapsProgress $mmapsLog
                    if ($mmapsResult.ConfigResult.Success) {
                        if ($mmapsResult.ConfigResult.Changed) {
                            Write-ZRotLog "Configured Settings.mmaps; Apep.json backup: $($mmapsResult.ConfigResult.BackupPath)"
                        } else {
                            Write-ZRotLog 'Settings.mmaps already points at the installed maps.'
                        }
                    } else {
                        Write-ZRotLog "WARNING: MMAPS installed, but $($mmapsResult.ConfigResult.Reason) Configure the path in Apep Settings."
                    }
                    if ($mmapsResult.LeftoverBackup) {
                        Write-ZRotLog "WARNING: The previous MMAPS directory could not be removed: $($mmapsResult.LeftoverBackup)"
                    }
                    Write-ZRotLog "MMAPS ready: $($mmapsResult.TargetPath)"
                    Write-ZRotLog 'IMPORTANT: Fully exit and restart Apep/Ascension so NavSrv loads the configured MMAPS path.'
                } catch {
                    Write-ZRotLog "MMAPS installation failed: $($_.Exception.Message)"
                    return
                }
            }

            Update-ApepStatus $installApepDir | Out-Null
            Update-WowStatus $installWowDir | Out-Null
            Update-InstallEnabled
            Save-ZRotInstallerConfig $installApepDir $installWowDir
            Set-ZRotStep 'done'
        } finally {
            Set-ZRotInstallBusy $false
        }
    })

    if ($NoShow) { return $window }
    $window.ShowDialog() | Out-Null
}


# Execution guard: do nothing when dot-sourced (tests) or when ZROT_TEST is set.
if ($MyInvocation.InvocationName -ne '.' -and -not $env:ZROT_TEST) {
    Start-ZRotInstaller
}
