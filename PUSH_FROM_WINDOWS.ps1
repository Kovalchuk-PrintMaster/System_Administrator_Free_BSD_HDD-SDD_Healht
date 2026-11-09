# Run from a modern Windows PC with Git installed and GitHub authentication configured.
# This initializes ONLY the target EMPTY repository; does not touch the FreeBSD server.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Repository = 'https://github.com/Kovalchuk-PrintMaster/System_Administrator_Free_BSD_HDD-SDD_Healht.git'
$SourceDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Snapshot = Join-Path $SourceDir 'disk_health_audit.sh'
$ChecksumFile = Join-Path $SourceDir 'docs/original-script.sha256'

if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'Git not installed. Install Git for Windows.' }
if (-not (Test-Path -LiteralPath $Snapshot)) { throw 'Source file missing.' }
$Expected = ((Get-Content -LiteralPath $ChecksumFile -TotalCount 1) -split '\s+')[0].ToLowerInvariant()
$Actual = (Get-FileHash -LiteralPath $Snapshot -Algorithm SHA256).Hash.ToLowerInvariant()
if ($Expected -ne $Actual) { throw 'SOURCE SHA256 MISMATCH; refusing push.' }

$RemoteHeads = @(git ls-remote --heads $Repository)
if ($LASTEXITCODE -ne 0) { throw 'Could not check the GitHub repository.' }
if ($RemoteHeads.Count -gt 0) { throw 'Remote is not empty. Refusing to overwrite or append automatically.' }

$Target = Join-Path $env:TEMP ('forprint-fbsd-github-' + [Guid]::NewGuid().ToString('N'))
& git clone $Repository $Target
if ($LASTEXITCODE -ne 0) { throw 'git clone failed.' }
try {
    # Copy only the reviewed public backup files, never any local .env, credentials,
    # or unexpected content that might be present in the extracted directory.
    $Allowlist = @(
        '.gitignore', '.gitattributes', 'PUSH_FROM_WINDOWS.ps1', 'README.md',
        'checks/verify_source.sh', 'config/disk-health-audit.env.example',
        'disk_health_audit.sh', 'docs/ASSESSMENT_UA.md', 'docs/RESTORE_UA.md',
        'docs/original-script.sha256', 'docs/source-inventory.txt'
    )
    foreach ($Relative in $Allowlist) {
        $RelativeWin = $Relative.Replace('/', [IO.Path]::DirectorySeparatorChar)
        $From = Join-Path $SourceDir $RelativeWin
        $To = Join-Path $Target $RelativeWin
        if (-not (Test-Path -LiteralPath $From -PathType Leaf)) {
            throw "Missing required file: $Relative"
        }
        $Parent = Split-Path -Parent $To
        if (-not (Test-Path -LiteralPath $Parent)) {
            New-Item -ItemType Directory -Path $Parent -Force | Out-Null
        }
        Copy-Item -LiteralPath $From -Destination $To -Force
    }
    & git -C $Target switch -C main
    if ($LASTEXITCODE -ne 0) { throw 'Could not initialize main branch.' }
    # The fresh clone contains exactly the allowlisted public files.
    & git -C $Target add -A
    if ($LASTEXITCODE -ne 0) { throw 'git add failed.' }

    # Original source is an immutable snapshot. Its line 1086 has a trailing
    # whitespace-only line, so `git diff --check` would reject that unchanged
    # historical source. Verify all other files strictly; verify source by SHA256
    # and by comparing Git's staged blob to the raw (unfiltered) source bytes.
    & git -C $Target diff --cached --check -- . ':(exclude)disk_health_audit.sh'
    if ($LASTEXITCODE -ne 0) { throw 'Whitespace errors in packaging files.' }
    $StagedSource = Join-Path $Target 'disk_health_audit.sh'
    $StagedHash = (Get-FileHash -LiteralPath $StagedSource -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($StagedHash -ne $Expected) { throw 'STAGED SOURCE SHA256 MISMATCH.' }
    $IndexBlob = (& git -C $Target rev-parse ':disk_health_audit.sh').Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Could not get staged Git blob hash.' }
    $RawBlob = (& git -C $Target hash-object --no-filters 'disk_health_audit.sh').Trim()
    if ($LASTEXITCODE -ne 0 -or $IndexBlob -ne $RawBlob) {
        throw 'Git index altered the original script bytes.'
    }
    Write-Host 'SOURCE_SHA256=PASS' -ForegroundColor Green
    Write-Host 'SOURCE_GIT_BLOB_EXACT=PASS' -ForegroundColor Green
    Write-Host 'PACKAGE_WHITESPACE=PASS' -ForegroundColor Green
    $Tracked = @(& git -C $Target ls-files)
    if ($LASTEXITCODE -ne 0) { throw 'Could not inspect staged files.' }
    if ($Tracked.Count -ne $Allowlist.Count) { throw 'Unexpected staged file count.' }
    foreach ($File in $Tracked) {
        if ($Allowlist -cnotcontains $File) { throw "Unexpected staged file: $File" }
    }
    & git -C $Target diff --cached --stat
    if ($LASTEXITCODE -ne 0) { throw 'git diff check failed.' }
    & git -C $Target commit -m 'backup: preserve FreeBSD disk-health source snapshot 2026-11-09'
    if ($LASTEXITCODE -ne 0) { throw 'Commit failed: configure git user.name and user.email.' }
    $LocalHead = (& git -C $Target rev-parse HEAD).Trim()
    & git -C $Target push origin main
    if ($LASTEXITCODE -ne 0) { throw 'GitHub push failed. Verify authentication and permissions.' }
    $RemoteLine = @(& git -C $Target ls-remote origin refs/heads/main)
    if ($LASTEXITCODE -ne 0 -or $RemoteLine.Count -ne 1) { throw 'Could not verify remote main.' }
    $RemoteHead = ($RemoteLine[0] -split '\s+')[0]
    if ($RemoteHead -ne $LocalHead) { throw 'Remote main differs from uploaded commit.' }
    Write-Host 'GITHUB=PASS' -ForegroundColor Green
    Write-Host "COMMIT=$LocalHead"
    Write-Host "SOURCE_SHA256=$Actual"
}
finally {
    # Keep local staging when push fails so the operator can inspect and retry manually.
    Write-Host "Git staging directory: $Target"
}
