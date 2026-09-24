param(
    [string]$Repo = $env:NULYA_INSTALL_REPO,
    [string]$Version = $env:NULYA_VERSION,
    [string]$InstallDir = $env:NULYA_INSTALL_DIR
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Repo)) { $Repo = 'Teamon9161/nulya' }
if ([string]::IsNullOrWhiteSpace($Version)) { $Version = 'latest' }
if ([string]::IsNullOrWhiteSpace($InstallDir)) {
    $InstallDir = Join-Path $env:LOCALAPPDATA 'Programs\nulya\bin'
}

$processor = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
switch -Regex ($processor) {
    'ARM64' { $arch = 'aarch64'; break }
    'AMD64|x86_64' { $arch = 'x86_64'; break }
    default { throw "unsupported architecture: $processor" }
}
$asset = "nulya-$arch-windows.exe"
if ($Version -eq 'latest') {
    $base = "https://github.com/$Repo/releases/latest/download"
} else {
    $tag = if ($Version.StartsWith('v')) { $Version } else { "v$Version" }
    $base = "https://github.com/$Repo/releases/download/$tag"
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("nulya-install-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    $binary = Join-Path $tmp $asset
    $checksums = Join-Path $tmp 'checksums.txt'
    Invoke-WebRequest -Uri "$base/$asset" -OutFile $binary
    Invoke-WebRequest -Uri "$base/checksums.txt" -OutFile $checksums
    $line = Get-Content $checksums | Where-Object { ($_ -split '\s+')[-1] -eq $asset } | Select-Object -First 1
    if (-not $line) { throw "checksum missing for $asset" }
    $expected = ($line -split '\s+')[0].ToLowerInvariant()
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $binary).Hash.ToLowerInvariant()
    if ($expected -ne $actual) { throw "checksum mismatch for $asset" }
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    $target = Join-Path $InstallDir 'nulya.exe'
    Copy-Item -LiteralPath $binary -Destination $target -Force

    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (($userPath -split ';') -notcontains $InstallDir) {
        [Environment]::SetEnvironmentVariable('Path', "$userPath;$InstallDir".TrimStart(';'), 'User')
    }
    Write-Host "Installed nulya to $target"
    Write-Host 'Restart your terminal if nulya is not found on PATH.'
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force
}
