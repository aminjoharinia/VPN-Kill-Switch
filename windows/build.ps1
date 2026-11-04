# Builds the Windows version natively on Windows: the vpnks daemon and the
# VPN Kill Switch app, a portable .zip and, if NSIS is installed, the
# installer. Then offers to install it. Run it through build.cmd in the
# project folder, which takes care of PowerShell's script policy:
#
#   build.cmd              this PC's architecture
#   build.cmd arm64        one architecture (amd64 or arm64)
#   build.cmd -Yes         build and install without asking
#   build.cmd -NoInstall   build only
#
# Needs Go 1.26+ (winget install GoLang.Go). Optional: NSIS for the
# installer (winget install NSIS.NSIS). From macOS or Linux, use
# windows/build.sh instead; it makes the same files.
param(
    [ValidateSet('amd64', 'arm64', '')]
    [string]$Arch = '',
    [switch]$Yes,
    [switch]$NoInstall
)
$ErrorActionPreference = 'Stop'

$Win = $PSScriptRoot
$Root = Split-Path $Win -Parent
$GoSrc = Join-Path $Root 'go'
$Icons = Join-Path $Root 'linux\packaging\icons'

if (-not (Get-Command go -ErrorAction SilentlyContinue)) {
    Write-Host 'Go is not installed. Install it with:  winget install GoLang.Go'
    Write-Host 'then open a new terminal and run build.cmd again.'
    exit 1
}
if (-not $Arch) { $Arch = (go env GOHOSTARCH).Trim() }

# Version is the build date, YY.MM.DD, as on macOS and Linux; the time of
# day keeps repeated builds on one date in order. Override with VPNKS_VERSION.
$Version = if ($env:VPNKS_VERSION) { $env:VPNKS_VERSION } else { Get-Date -Format 'yy.MM.dd' }
$BuildNum = if ($env:VPNKS_BUILD) { $env:VPNKS_BUILD } else { Get-Date -Format 'HHmmss' }
Write-Host "==> Version $Version (build $BuildNum): $Arch"

$Out = Join-Path $Root 'output\windows'
$Bin = Join-Path $Out $Arch
if (Test-Path $Bin) { Remove-Item $Bin -Recurse -Force }
New-Item -ItemType Directory -Force -Path $Bin | Out-Null
$Ico = Join-Path $Out 'vpn-kill-switch.ico'
$IconPngs = '32', '64', '128', '256' | ForEach-Object { Join-Path $Icons "$_.png" }
$LdFlags = "-s -w -X vpnks/internal/core.Version=$Version -X vpnks/internal/core.Number=$BuildNum"

function Invoke-Checked {
    & $args[0] $args[1..($args.Count - 1)]
    if ($LASTEXITCODE -ne 0) { throw "Failed: $($args -join ' ')" }
}

Push-Location $GoSrc
$env:GOOS = 'windows'
$env:GOARCH = $Arch
$env:CGO_ENABLED = '0'
try {
    Write-Host "==> [$Arch] Resources (icon, manifest)"
    # The resource tool runs on this PC, so it is built for this PC.
    $env:GOARCH = ''
    Invoke-Checked go run ./tools/winres -arch $Arch -manifest gui -out "app/rsrc_windows_$Arch.syso" -ico $Ico @IconPngs
    Invoke-Checked go run ./tools/winres -arch $Arch -manifest cli -out "cmd/vpnks/rsrc_windows_$Arch.syso" @IconPngs
    $env:GOARCH = $Arch

    Write-Host "==> [$Arch] Building vpnks daemon"
    Invoke-Checked go build -trimpath -ldflags $LdFlags -o (Join-Path $Bin 'vpnks.exe') ./cmd/vpnks

    Write-Host "==> [$Arch] Building VPN Kill Switch app"
    # The Wails tags a manual build needs; -H windowsgui: no console window.
    Invoke-Checked go build -trimpath -tags desktop,production -ldflags "$LdFlags -H windowsgui" `
        -o (Join-Path $Bin 'vpn-kill-switch.exe') ./app
}
finally {
    Remove-Item Env:GOOS, Env:GOARCH, Env:CGO_ENABLED -ErrorAction SilentlyContinue
    Pop-Location
}

$Zip = Join-Path $Out "VPN-Kill-Switch-$Version-windows-$Arch-portable.zip"
Compress-Archive -Force -DestinationPath $Zip `
    -Path (Join-Path $Bin 'vpn-kill-switch.exe'), (Join-Path $Bin 'vpnks.exe')
Write-Host "    $Zip"

$Setup = $null
$Nsis = Get-Command makensis -ErrorAction SilentlyContinue
if (-not $Nsis) {
    $Default = Join-Path ${env:ProgramFiles(x86)} 'NSIS\makensis.exe'
    if (Test-Path $Default) { $Nsis = Get-Command $Default }
}
if ($Nsis) {
    Write-Host "==> [$Arch] Installer"
    $Setup = Join-Path $Out "VPN-Kill-Switch-$Version-windows-$Arch-setup.exe"
    Invoke-Checked $Nsis.Source -V2 "-DARCH=$Arch" "-DVERSION=$Version" "-DBUILD=$BuildNum" `
        "-DBINDIR=$Bin" "-DICON=$Ico" "-DOUTFILE=$Setup" (Join-Path $Win 'packaging\installer.nsi')
    Write-Host "    $Setup"
}

Write-Host ''
if (-not $Setup) {
    Write-Host 'No installer built: NSIS is not installed (winget install NSIS.NSIS).'
    Write-Host "Run the app straight from the build:  $Bin\vpn-kill-switch.exe"
    exit 0
}
if ($NoInstall) { exit 0 }

$Answer = if ($Yes) { 'y' } else { Read-Host 'Install it now (Windows asks for permission)? [y/N]' }
if ($Answer -match '^[Yy]') {
    # Quit the running app first; the kill switch keeps running.
    Get-Process vpn-kill-switch -ErrorAction SilentlyContinue | Stop-Process -Force
    # The installer asks for administrator rights itself (UAC).
    $Proc = Start-Process -FilePath $Setup -Wait -PassThru
    if ($Proc.ExitCode -ne 0) { Write-Host "The installer stopped with code $($Proc.ExitCode)."; exit 1 }
    Write-Host 'Installed. Open VPN Kill Switch from the Start menu.'
}
else {
    Write-Host "Install it later by running:  $Setup"
}
