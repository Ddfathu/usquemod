[CmdletBinding()]
param(
    # Named BuildProfile to avoid PowerShell automatic $Profile; keep -Profile CLI alias.
    [Alias("Profile")]
    [ValidateSet("debug", "release")]
    [string]$BuildProfile = "debug",
    [string]$NdkRoot = "",
    [ValidateSet("all", "arm64-v8a", "armeabi-v7a", "x86_64")]
    [string]$AbiFilter = "all",
    # build: compile and copy .so into jniLibs. clippy: lint arm64-v8a lib only, no .so copy.
    [ValidateSet("build", "clippy")]
    [string]$CargoAction = "build",
    # Matched native A/B measurement, never a packaging or installation switch.
    [switch]$DisableWireGuard
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if ($DisableWireGuard -and $CargoAction -ne "build") {
    throw "DisableWireGuard is only supported for compile-only builds."
}
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$androidRoot = Join-Path $repoRoot "apps/usque_gui/android"
$jniRoot = Join-Path $androidRoot "app/src/main/jniLibs"
$ndkVersion = "29.0.14206865"
$minimumApi = "26"

if ($CargoAction -eq "clippy") {
    # Clippy is a static gate for the primary device ABI only; full multi-ABI
    # coverage remains with the build action and Flutter APK jobs.
    if ($PSBoundParameters.ContainsKey("AbiFilter") -and $AbiFilter -ne "arm64-v8a") {
        Write-Warning "Clippy mode only supports arm64-v8a; ignoring -AbiFilter '$AbiFilter'."
    }
    $AbiFilter = "arm64-v8a"
}

if ([string]::IsNullOrWhiteSpace($NdkRoot)) {
    # Hosted runners may predefine ANDROID_NDK_HOME to an arbitrary image
    # default. The repository contract pins NDK 29, so prefer the pinned SDK
    # side-by-side installation whenever an SDK root is available.
    if (-not [string]::IsNullOrWhiteSpace($env:ANDROID_SDK_ROOT)) {
        $NdkRoot = Join-Path $env:ANDROID_SDK_ROOT "ndk/$ndkVersion"
    } elseif (-not [string]::IsNullOrWhiteSpace($env:ANDROID_HOME)) {
        $NdkRoot = Join-Path $env:ANDROID_HOME "ndk/$ndkVersion"
    } elseif (-not [string]::IsNullOrWhiteSpace($env:ANDROID_NDK_HOME)) {
        $NdkRoot = $env:ANDROID_NDK_HOME
    } elseif (-not [string]::IsNullOrWhiteSpace($env:ANDROID_NDK_ROOT)) {
        $NdkRoot = $env:ANDROID_NDK_ROOT
    } else {
        $localProperties = Join-Path $androidRoot "local.properties"
        if (Test-Path -LiteralPath $localProperties) {
            $sdkLine = Get-Content -LiteralPath $localProperties |
                Where-Object { $_ -like "sdk.dir=*" } |
                Select-Object -First 1
            if ($sdkLine) {
                # Java properties escape both the drive colon and path
                # separators. Decode those two forms before passing the path
                # back to PowerShell.
                $sdkRoot = $sdkLine.Substring("sdk.dir=".Length).Replace("\:", ":").Replace("\\", "\")
                $NdkRoot = Join-Path $sdkRoot "ndk/$ndkVersion"
            }
        }
    }
}

if ([string]::IsNullOrWhiteSpace($NdkRoot) -or -not (Test-Path -LiteralPath $NdkRoot)) {
    throw "Android NDK $ndkVersion was not found. Set ANDROID_SDK_ROOT or ANDROID_NDK_HOME."
}
$NdkRoot = (Resolve-Path -LiteralPath $NdkRoot).Path
$ndkSourceProperties = Join-Path $NdkRoot "source.properties"
if (-not (Test-Path -LiteralPath $ndkSourceProperties -PathType Leaf)) {
    throw "Android NDK source.properties was not found: $ndkSourceProperties"
}
$ndkRevisionLine = Get-Content -LiteralPath $ndkSourceProperties |
    Where-Object { $_ -match '^\s*Pkg\.Revision\s*=' } |
    Select-Object -First 1
$ndkRevision = if ([string]::IsNullOrWhiteSpace($ndkRevisionLine)) {
    ""
}
else {
    $revisionText = [string]$ndkRevisionLine
    $revisionText.Substring($revisionText.IndexOf('=') + 1).Trim()
}
if (-not [StringComparer]::Ordinal.Equals($ndkRevision, $ndkVersion)) {
    throw "Android NDK version mismatch: expected $ndkVersion, found '$ndkRevision' at $NdkRoot."
}
$env:ANDROID_NDK_HOME = $NdkRoot
$env:ANDROID_NDK_ROOT = $NdkRoot
$sdkRootFromNdk = Split-Path -Parent (Split-Path -Parent $NdkRoot)
$androidCmakeBin = Join-Path $sdkRootFromNdk "cmake/3.22.1/bin"
$isWindowsHost = $env:OS -eq "Windows_NT"
$executableSuffix = if ($isWindowsHost) { ".exe" } else { "" }
$commandSuffix = if ($isWindowsHost) { ".cmd" } else { "" }
$pathSeparator = [IO.Path]::PathSeparator
$cmakeExecutable = Join-Path $androidCmakeBin "cmake$executableSuffix"
$ninjaExecutable = Join-Path $androidCmakeBin "ninja$executableSuffix"
if (-not (Test-Path -LiteralPath $cmakeExecutable)) {
    throw "Pinned Android CMake 3.22.1 was not found at $androidCmakeBin"
}
if (-not (Test-Path -LiteralPath $ninjaExecutable)) {
    throw "Pinned Android Ninja was not found at $androidCmakeBin"
}
$env:PATH = "$androidCmakeBin$pathSeparator$env:PATH"
$env:CMAKE_GENERATOR = "Ninja"
$env:CMAKE_MAKE_PROGRAM = $ninjaExecutable
# Cross-target debug artifacts are large and are never reused by the signed
# release build. Disabling incremental compilation keeps a local three-ABI
# verification from recreating tens of gigabytes under target/.
$env:CARGO_INCREMENTAL = "0"

$hostTag = if ($isWindowsHost) { "windows-x86_64" } else { "linux-x86_64" }
$toolchainBin = Join-Path $NdkRoot "toolchains/llvm/prebuilt/$hostTag/bin"
if (-not (Test-Path -LiteralPath $toolchainBin)) {
    throw "NDK LLVM toolchain was not found at $toolchainBin"
}
$libclangDirectory =
if ($isWindowsHost) {
    $toolchainBin
} else {
    # NDK r29 follows the upstream LLVM layout on Linux and ships libclang
    # directly under lib/. Older NDK images used lib64/, but accepting that
    # layout here would silently select an unpinned runner default again.
    Join-Path $NdkRoot "toolchains/llvm/prebuilt/$hostTag/lib"
}
$libclang =
if ($isWindowsHost) {
    Join-Path $libclangDirectory "libclang.dll"
} else {
    Join-Path $libclangDirectory "libclang.so"
}
if (-not (Test-Path -LiteralPath $libclang)) {
    throw "NDK libclang was not found at $libclang"
}
$env:LIBCLANG_PATH = $libclangDirectory
$env:PATH = "$toolchainBin$pathSeparator$env:PATH"

$cargoCommand = Get-Command cargo -ErrorAction SilentlyContinue
$cargoPath = if ($cargoCommand) { $cargoCommand.Source } else { "" }
if ([string]::IsNullOrWhiteSpace($cargoPath) -and $isWindowsHost) {
    $userCargo = Join-Path $env:USERPROFILE ".cargo/bin/cargo.exe"
    if (Test-Path -LiteralPath $userCargo) {
        $cargoPath = $userCargo
    }
}
if ([string]::IsNullOrWhiteSpace($cargoPath)) {
    throw "cargo was not found in PATH or the standard user install directory."
}

$targets = @(
    @{
        RustTarget = "aarch64-linux-android"
        Abi = "arm64-v8a"
        Linker = "aarch64-linux-android$minimumApi-clang$commandSuffix"
        CxxLinker = "aarch64-linux-android$minimumApi-clang++$commandSuffix"
        Environment = "CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER"
        CcEnvironment = "CC_aarch64_linux_android"
        CxxEnvironment = "CXX_aarch64_linux_android"
        ArEnvironment = "AR_aarch64_linux_android"
    },
    @{
        RustTarget = "armv7-linux-androideabi"
        Abi = "armeabi-v7a"
        Linker = "armv7a-linux-androideabi$minimumApi-clang$commandSuffix"
        CxxLinker = "armv7a-linux-androideabi$minimumApi-clang++$commandSuffix"
        Environment = "CARGO_TARGET_ARMV7_LINUX_ANDROIDEABI_LINKER"
        CcEnvironment = "CC_armv7_linux_androideabi"
        CxxEnvironment = "CXX_armv7_linux_androideabi"
        ArEnvironment = "AR_armv7_linux_androideabi"
    },
    @{
        RustTarget = "x86_64-linux-android"
        Abi = "x86_64"
        Linker = "x86_64-linux-android$minimumApi-clang$commandSuffix"
        CxxLinker = "x86_64-linux-android$minimumApi-clang++$commandSuffix"
        Environment = "CARGO_TARGET_X86_64_LINUX_ANDROID_LINKER"
        CcEnvironment = "CC_x86_64_linux_android"
        CxxEnvironment = "CXX_x86_64_linux_android"
        ArEnvironment = "AR_x86_64_linux_android"
    }
)
if ($AbiFilter -ne "all") {
    $targets = @($targets | Where-Object { $_.Abi -eq $AbiFilter })
}

Push-Location $repoRoot
try {
    foreach ($target in $targets) {
        $linker = (Join-Path $toolchainBin $target.Linker).Replace("\", "/")
        if (-not (Test-Path -LiteralPath $linker)) {
            throw "Android linker was not found: $linker"
        }
        Set-Item -Path "Env:$($target.Environment)" -Value $linker
        $cxx = (Join-Path $toolchainBin $target.CxxLinker).Replace("\", "/")
        if (-not (Test-Path -LiteralPath $cxx)) {
            throw "Android C++ target compiler was not found: $cxx"
        }

        # Native Rust dependencies such as ring use cc-rs directly and need
        # the NDK's API-qualified wrappers. Never point these variables at the
        # host-facing clang.exe: doing so loses both the Android API level and,
        # for 32-bit ARM, the armv7 architecture selection.
        Set-Item -Path "Env:$($target.CcEnvironment)" -Value $linker
        Set-Item -Path "Env:$($target.CxxEnvironment)" -Value $cxx
        $archiver = (Join-Path $toolchainBin "llvm-ar$executableSuffix").Replace("\", "/")
        Set-Item -Path "Env:$($target.ArEnvironment)" -Value $archiver

        if ($CargoAction -eq "clippy") {
            $cargoArguments = @(
                "clippy",
                "--locked",
                "--package", "usque-android",
                "--lib",
                "--target", $target.RustTarget
            )
            if ($BuildProfile -eq "release") {
                $cargoArguments += "--release"
            }
            $cargoArguments += @("--", "-D", "warnings")

            & $cargoPath @cargoArguments
            if ($LASTEXITCODE -ne 0) {
                throw "Rust Android clippy failed for $($target.RustTarget)."
            }
            # Clippy does not produce a shared library; skip jniLibs install.
            continue
        }

        $cargoArguments = @(
            "build",
            "--locked",
            "--package", "usque-android",
            "--target", $target.RustTarget
        )
        if ($BuildProfile -eq "release") {
            $cargoArguments += "--release"
        }

        if ($DisableWireGuard) {
            $cargoArguments += "--no-default-features"
        }
        & $cargoPath @cargoArguments
        if ($LASTEXITCODE -ne 0) {
            throw "Rust Android build failed for $($target.RustTarget)."
        }

        $artifactProfile = if ($BuildProfile -eq "release") { "release" } else { "debug" }
        $source = Join-Path $repoRoot "target/$($target.RustTarget)/$artifactProfile/libusque_android.so"
        if (-not (Test-Path -LiteralPath $source)) {
            throw "Expected Rust library was not produced: $source"
        }
        $destination = Join-Path $jniRoot $target.Abi
        New-Item -ItemType Directory -Path $destination -Force | Out-Null
        Copy-Item -LiteralPath $source -Destination (Join-Path $destination "libusque_android.so") -Force
    }
} finally {
    Pop-Location
}

# --- Inject mode natives (Fase 2a): Xray core + hev-socks5-tunnel ---------
# Best-effort: kegagalan di blok ini tidak boleh menjatuhkan build utama
# (MASQUE). Bila binary tidak terpasang, mode Inject di aplikasi akan
# melaporkan "binary tidak tersedia" secara jujur.
if ($CargoAction -eq "build") {
    try {
        $injectTemp = Join-Path ([System.IO.Path]::GetTempPath()) "usque-inject-natives"
        New-Item -ItemType Directory -Path $injectTemp -Force | Out-Null
        $xrayVersion = "v26.11.9"
        $hevVersion = "2.20.0"
        # Hanya arm64-v8a: Xray-core tidak merilis build Android armv7, dan
        # build linux-arm32-v7a bertipe ET_EXEC (bukan ET_DYN) sehingga
        # ditolak validasi ELF APK (verify_android_apk.py mewajibkan
        # shared-object type 3 untuk semua .so). Mode Inject di APK
        # armeabi-v7a akan melaporkan binary tidak tersedia; perangkat
        # arm64 (mayoritas, termasuk POCO C75) tidak terpengaruh.
        $xrayAssets = @(
            @{ Abi = "arm64-v8a"; File = "Xray-android-arm64-v8a.zip"; Sha256 = "edcefc25b9b3195b11e18624c8269a969d6aabc39c6298a9a5ab29de15d46f3b" }
        )
        foreach ($asset in $xrayAssets) {
            $destDir = Join-Path $jniRoot $asset.Abi
            $destFile = Join-Path $destDir "libxray.so"
            if (-not (Test-Path -LiteralPath $destFile)) {
                $zipPath = Join-Path $injectTemp $asset.File
                Invoke-WebRequest -Uri "https://github.com/XTLS/Xray-core/releases/download/$xrayVersion/$($asset.File)" -OutFile $zipPath
                $hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
                if ($hash -ne $asset.Sha256) {
                    throw "SHA256 mismatch for $($asset.File): $hash"
                }
                New-Item -ItemType Directory -Path $destDir -Force | Out-Null
                $extractDir = Join-Path $injectTemp "xray-$($asset.Abi)"
                Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir -Force
                Copy-Item -LiteralPath (Join-Path $extractDir "xray") -Destination $destFile -Force
            }
            Write-Output "INJECT_XRAY_READY=$($asset.Abi)"
        }

        $hevLibName = "libhev-socks5-tunnel.so"
        $hevMissing = $false
        foreach ($abi in @("arm64-v8a", "armeabi-v7a")) {
            if (-not (Test-Path -LiteralPath (Join-Path (Join-Path $jniRoot $abi) $hevLibName))) {
                $hevMissing = $true
            }
        }
        if ($hevMissing) {
            $hevTar = Join-Path $injectTemp "hev.tar.xz"
            Invoke-WebRequest -Uri "https://github.com/heiher/hev-socks5-tunnel/releases/download/$hevVersion/hev-socks5-tunnel-$hevVersion.tar.xz" -OutFile $hevTar
            $hevHash = (Get-FileHash -LiteralPath $hevTar -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($hevHash -ne "bc2ce746a0beeb71030d3ffe299f5a9d48e2895902d3883c2cac1a551ee128e9") {
                throw "SHA256 mismatch for hev tarball: $hevHash"
            }
            $hevSrc = Join-Path $injectTemp "hev-src"
            New-Item -ItemType Directory -Path $hevSrc -Force | Out-Null
            & tar -xf $hevTar -C $hevSrc --strip-components=1
            if ($LASTEXITCODE -ne 0) {
                throw "tar extract hev failed with exit code $LASTEXITCODE"
            }
            $ndkBuild = Join-Path $NdkRoot "build/ndk-build"
            if (-not (Test-Path -LiteralPath $ndkBuild)) {
                $ndkBuild = "$ndkBuild.cmd"
            }
            if (-not (Test-Path -LiteralPath $ndkBuild)) {
                throw "ndk-build not found under $NdkRoot"
            }
            $hevLibs = Join-Path $injectTemp "hev-libs"
            foreach ($abi in @("arm64-v8a", "armeabi-v7a")) {
                $hevOut = Join-Path $injectTemp "hev-out-$abi"
                & $ndkBuild -C $hevSrc "NDK_PROJECT_PATH=$hevSrc" "APP_BUILD_SCRIPT=$(Join-Path $hevSrc 'Android.mk')" "NDK_APPLICATION_MK=$(Join-Path $hevSrc 'Application.mk')" "NDK_OUT=$hevOut" "NDK_LIBS_OUT=$hevLibs" "APP_ABI=$abi" "-j4"
                if ($LASTEXITCODE -ne 0) {
                    throw "ndk-build hev failed for $abi with exit code $LASTEXITCODE"
                }
                $destDir = Join-Path $jniRoot $abi
                New-Item -ItemType Directory -Path $destDir -Force | Out-Null
                Copy-Item -LiteralPath (Join-Path (Join-Path $hevLibs $abi) $hevLibName) -Destination (Join-Path $destDir $hevLibName) -Force
                Write-Output "INJECT_HEV_READY=$abi"
            }
        }
    } catch {
        Write-Warning "Inject natives tidak terpasang (mode Inject akan nonaktif di APK ini): $($_.Exception.Message)"
    }
}

if ($CargoAction -eq "clippy") {
    Write-Output "RUST_ANDROID_CLIPPY_OK=arm64-v8a"
} else {
    Write-Output "RUST_ANDROID_LIBS_READY=$jniRoot"
}
