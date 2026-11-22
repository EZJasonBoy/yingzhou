#Requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Spider,
    [Parameter(Mandatory)][string] $GraalHome,
    [Parameter(Mandatory)][string] $EngineLib,
    [Parameter(Mandatory)][string] $OutputDirectory,
    [string] $VisualStudio
)

$ErrorActionPreference = 'Stop'
if (-not $IsWindows -or [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'X64') {
    throw 'The supported target is Windows x64.'
}
$spiderFile = (Get-Item -LiteralPath $Spider).FullName
$expectedDigest = 'BEAA0C16ECD5257BAE7DD680EA145EDA9A4385CE384BC02125AB64001940A0FE'
if ((Get-FileHash -LiteralPath $spiderFile -Algorithm SHA256).Hash -ne $expectedDigest) {
    throw "This build supports the spider with SHA-256 $expectedDigest."
}
$engineDirectory = (Get-Item -LiteralPath $EngineLib).FullName
$graalDirectory = (Get-Item -LiteralPath $GraalHome).FullName
$java = (Get-Item -LiteralPath (Join-Path $graalDirectory 'bin/java.exe')).FullName
$javac = (Get-Item -LiteralPath (Join-Path $graalDirectory 'bin/javac.exe')).FullName
$nativeImage = (Get-Item -LiteralPath (Join-Path $graalDirectory 'bin/native-image.cmd')).FullName
$outputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
$destination = [IO.Directory]::CreateDirectory($outputPath).FullName
$hostName = 'ganfan-host.exe'
$launcherName = 'ganfan-sandbox.exe'
foreach ($name in @($hostName, $launcherName)) {
    if (Test-Path -LiteralPath (Join-Path $destination $name)) {
        throw "Choose a new output directory. $name already exists in $destination."
    }
}

if (-not $VisualStudio) {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
    $VisualStudio = & $vswhere -latest -version '[17.0,18.0)' -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $VisualStudio) { throw 'Visual Studio 2022 with the x64 C++ tools and Windows SDK is required.' }
}
Import-Module (Join-Path $VisualStudio 'Common7/Tools/Microsoft.VisualStudio.DevShell.dll')
Enter-VsDevShell -VsInstallPath $VisualStudio -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64'

$stageName = 'ganfan-build-' + [Guid]::NewGuid().ToString('N')
$stage = [IO.Directory]::CreateDirectory((Join-Path $destination $stageName)).FullName
try {
    $engineClasspath = Join-Path $engineDirectory '*'
    & $javac '-proc:none' '-encoding' 'UTF-8' '-cp' $engineClasspath '-d' $stage (Join-Path $PSScriptRoot 'TranslateSpider.java') (Join-Path $PSScriptRoot 'MonitorRegions.java')
    if ($LASTEXITCODE) { throw "Compiling the DEX translator failed ($LASTEXITCODE)." }
    & $java '-cp' "$stage;$engineClasspath" 'TranslateSpider' $spiderFile $stage
    if ($LASTEXITCODE) { throw "Translating the pinned spider failed ($LASTEXITCODE)." }

    $desktopJar = Join-Path $stage 'desktop.jar'
    $archive = [IO.Compression.ZipFile]::OpenRead($desktopJar)
    try {
        $reflection = @($archive.Entries | Where-Object { $_.FullName -match '^com/github/catvod/spider/merge/c/[^/]+\.class$' } | ForEach-Object {
            [ordered]@{ name = $_.FullName.Substring(0, $_.FullName.Length - 6).Replace('/', '.'); allDeclaredFields = $true; allDeclaredConstructors = $true }
        })
    } finally { $archive.Dispose() }
    if ($reflection.Count -ne 16) { throw 'Unexpected Gson model layout for the pinned spider.' }
    $metadata = Join-Path $stage 'reflect-config.json'
    [IO.File]::WriteAllText($metadata, (ConvertTo-Json -InputObject $reflection -Depth 4))

    $runtimeLibraries = '^(runtime-jar-|core-|gson-|android-json-|kotlin-stdlib-|okhttp-|okio-jvm-|jsoup-|collection-jvm-|annotation-jvm-|slf4j-api-|kotlinx-coroutines-core-|kotlinx-serialization-(core|json)-jvm-)'
    $dependencies = @(Get-ChildItem -LiteralPath $engineDirectory -Filter '*.jar' | Where-Object { $_.Name -match $runtimeLibraries } | ForEach-Object FullName)
    $classes = [IO.Directory]::CreateDirectory((Join-Path $stage 'host-classes')).FullName
    $classpath = (@($classes) + $dependencies + @($desktopJar)) -join ';'
    & $javac '-proc:none' '-encoding' 'UTF-8' '-cp' $classpath '-d' $classes (Join-Path $PSScriptRoot 'GanfanHost.java')
    if ($LASTEXITCODE) { throw "Compiling the host failed ($LASTEXITCODE)." }

    $launcherSource = Join-Path $PSScriptRoot 'windows-sandbox/launcher.cpp'
    $launcherOutput = Join-Path $stage $launcherName
    $launcherObject = Join-Path $stage 'launcher.obj'
    & cl.exe '/nologo' '/EHsc' '/std:c++17' '/O2' '/MT' "/Fo$launcherObject" "/Fe$launcherOutput" $launcherSource
    if ($LASTEXITCODE) { throw "Compiling the AppContainer launcher failed ($LASTEXITCODE)." }

    & $nativeImage '-J-Xmx4g' '-J-XX:ActiveProcessorCount=5' '-Ob' '--no-fallback' '--enable-url-protocols=http,https' '--initialize-at-run-time=com.github.catvod' "-H:ReflectionConfigurationFiles=$metadata" '-cp' $classpath '-o' (Join-Path $stage 'ganfan-host') 'GanfanHost'
    if ($LASTEXITCODE) { throw "Building the native image failed ($LASTEXITCODE)." }
    foreach ($name in @($hostName, $launcherName)) {
        [IO.File]::Copy((Join-Path $stage $name), (Join-Path $destination $name), $false)
    }
    Write-Output "Built $hostName and $launcherName in $destination"
} finally {
    $resolved = Get-Item -LiteralPath $stage
    if ($resolved.Name -ne $stageName -or $resolved.Parent.FullName -ne (Get-Item -LiteralPath $destination).FullName -or $resolved.LinkType) {
        throw "Refusing to clean an unexpected build directory: $stage"
    }
    Remove-Item -LiteralPath $resolved.FullName -Recurse -Force
}
