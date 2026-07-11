param(
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [string[]] $ApkPath = @(
        "build/app/outputs/flutter-apk/app-arm64-v8a-release.apk",
        "build/app/outputs/flutter-apk/app-x86_64-release.apk"
    ),
    [string[]] $RequiredMethod = @(
        "com.easytier.jni.EasyTierJNI int startConfigServerClient(",
        "com.easytier.jni.EasyTierJNI int stopConfigServerClient(",
        "com.easytier.jni.EasyTierJNI boolean isConfigServerClientConnected(",
        "com.easytier.jni.EasyTierJNI java.lang.String listInstances(",
        "com.easytier.jni.EasyTierJNI java.lang.String callJsonRpc("
    )
)

$ErrorActionPreference = "Stop"

function Resolve-AndroidSdkFromLocalProperties {
    $localProperties = Join-Path $RepoRoot "android/local.properties"
    if (-not (Test-Path $localProperties)) {
        return ""
    }

    foreach ($line in Get-Content $localProperties) {
        if ($line -match "^sdk\.dir=(.+)$") {
            return ($Matches[1] -replace "\\\\", "\").Trim()
        }
    }
    return ""
}

function Resolve-AndroidSdkPath {
    foreach ($candidate in @($env:ANDROID_SDK_ROOT, $env:ANDROID_HOME, (Resolve-AndroidSdkFromLocalProperties))) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }
        $resolved = Resolve-Path $candidate -ErrorAction SilentlyContinue
        if ($resolved) {
            return $resolved.Path
        }
    }
    return ""
}

function Resolve-ApkAnalyzerPath {
    $command = Get-Command apkanalyzer -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $androidSdk = Resolve-AndroidSdkPath
    if ([string]::IsNullOrWhiteSpace($androidSdk)) {
        throw "Android SDK path was not found. Set ANDROID_HOME or ANDROID_SDK_ROOT."
    }

    $names = @("apkanalyzer", "apkanalyzer.bat", "apkanalyzer.exe")
    $candidate = Get-ChildItem -Path $androidSdk -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $names -contains $_.Name } |
        Sort-Object FullName -Descending |
        Select-Object -First 1
    if ($candidate) {
        return $candidate.FullName
    }

    throw "apkanalyzer was not found under Android SDK: $androidSdk"
}

$apkAnalyzer = Resolve-ApkAnalyzerPath

foreach ($path in $ApkPath) {
    $apk = if ([System.IO.Path]::IsPathRooted($path)) {
        $path
    } else {
        Join-Path $RepoRoot $path
    }
    if (-not (Test-Path $apk)) {
        throw "Android release APK was not found: $apk"
    }

    $packages = (& $apkAnalyzer dex packages $apk 2>&1) | ForEach-Object { $_.ToString() }
    if ($LASTEXITCODE -ne 0) {
        throw "apkanalyzer failed for $apk with exit code ${LASTEXITCODE}:`n$($packages -join "`n")"
    }
    $text = $packages -join "`n"
    foreach ($method in $RequiredMethod) {
        if (-not $text.Contains($method)) {
            throw "Android release APK is missing JNI bridge method '$method': $apk"
        }
    }

    Write-Host "Android release APK JNI bridge verified: $apk"
}
