param(
    [Parameter(Mandatory = $true)]
    [string] $ReleaseDir,
    [string] $VcRuntimeDir = "",
    [switch] $CopyToResources
)

$ErrorActionPreference = "Stop"

$requiredDlls = @(
    "msvcp140.dll",
    "vcruntime140.dll",
    "vcruntime140_1.dll"
)

function Add-ExistingDirectory([System.Collections.Generic.List[string]] $Dirs, [string] $Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }
    if (Test-Path -LiteralPath $Path -PathType Container) {
        $Dirs.Add((Resolve-Path -LiteralPath $Path).Path)
    }
}

function Add-RedistRootCandidates([System.Collections.Generic.List[string]] $Dirs, [string] $Root) {
    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root -PathType Container)) {
        return
    }

    Add-ExistingDirectory $Dirs (Join-Path $Root "x64\Microsoft.VC143.CRT")
    Add-ExistingDirectory $Dirs (Join-Path $Root "x64\Microsoft.VC142.CRT")

    Get-ChildItem -LiteralPath $Root -Recurse -Directory -Filter "Microsoft.VC*.CRT" -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match "\\x64\\Microsoft\.VC\d+\.CRT$" } |
        ForEach-Object { Add-ExistingDirectory $Dirs $_.FullName }
}

function Add-VsRedistCandidates([System.Collections.Generic.List[string]] $Dirs) {
    $roots = @(
        (Join-Path $env:ProgramFiles "Microsoft Visual Studio"),
        (Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio")
    )

    foreach ($root in $roots) {
        if (Test-Path -LiteralPath $root -PathType Container) {
            Get-ChildItem -LiteralPath $root -Recurse -Directory -Filter "Microsoft.VC*.CRT" -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -match "\\VC\\Redist\\MSVC\\.*\\x64\\Microsoft\.VC\d+\.CRT$" } |
                ForEach-Object { Add-ExistingDirectory $Dirs $_.FullName }
        }
    }
}

function Add-VcToolsInstallCandidate([System.Collections.Generic.List[string]] $Dirs) {
    if ([string]::IsNullOrWhiteSpace($env:VCToolsInstallDir)) {
        return
    }

    $toolsDir = Resolve-Path -LiteralPath $env:VCToolsInstallDir -ErrorAction SilentlyContinue
    if ($null -eq $toolsDir) {
        return
    }

    $version = Split-Path $toolsDir.Path -Leaf
    $vcDir = Split-Path (Split-Path (Split-Path $toolsDir.Path -Parent) -Parent) -Parent
    Add-RedistRootCandidates $Dirs (Join-Path $vcDir "Redist\MSVC\$version")
}

function Test-RuntimeDirectory([string] $Path) {
    foreach ($dll in $requiredDlls) {
        if (-not (Test-Path -LiteralPath (Join-Path $Path $dll) -PathType Leaf)) {
            return $false
        }
    }
    return $true
}

function Resolve-VcRuntimeDirectory([string] $ExplicitDir) {
    $dirs = [System.Collections.Generic.List[string]]::new()

    Add-ExistingDirectory $dirs $ExplicitDir
    Add-RedistRootCandidates $dirs $env:VCToolsRedistDir
    if (-not [string]::IsNullOrWhiteSpace($env:VCINSTALLDIR)) {
        Add-RedistRootCandidates $dirs (Join-Path $env:VCINSTALLDIR "Redist\MSVC")
    }
    Add-VcToolsInstallCandidate $dirs
    Add-VsRedistCandidates $dirs

    foreach ($dir in ($dirs | Sort-Object -Unique -Descending)) {
        if (Test-RuntimeDirectory $dir) {
            return $dir
        }
    }

    $dllList = $requiredDlls -join ", "
    throw "Could not find x64 Visual C++ runtime files ($dllList). Install Visual Studio Build Tools with the MSVC redistributable files, set VCToolsRedistDir, or pass -VcRuntimeDir."
}

function Copy-RuntimeFiles([string] $SourceDir, [string] $DestinationDir) {
    if (-not (Test-Path -LiteralPath $DestinationDir -PathType Container)) {
        New-Item -ItemType Directory -Force $DestinationDir | Out-Null
    }

    Get-ChildItem -LiteralPath $SourceDir -File |
        ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $DestinationDir $_.Name) -Force
        }
}

$releasePath = Resolve-Path -LiteralPath $ReleaseDir
$runtimeDir = Resolve-VcRuntimeDirectory $VcRuntimeDir

Write-Host "Copying Visual C++ runtime files from: $runtimeDir"
Copy-RuntimeFiles $runtimeDir $releasePath.Path

if ($CopyToResources) {
    $resourcesPath = Join-Path $releasePath.Path "resources"
    if (Test-Path -LiteralPath $resourcesPath -PathType Container) {
        Copy-RuntimeFiles $runtimeDir $resourcesPath
    }
}
