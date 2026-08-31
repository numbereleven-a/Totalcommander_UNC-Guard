#Requires -Version 5.1

param(
    [ValidateSet('Full', 'PluginOnly')]
    [string]$Mode,
    [string]$TotalCommanderPath,
    [string]$IniPath,
    [switch]$NoElevation,
    [switch]$Quiet,
    [string]$ResultPath,
    [string]$TargetAccount
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($TargetAccount)) {
    $TargetAccount = [Security.Principal.WindowsIdentity]::GetCurrent().Name
}
$script:InstallationStage = 'Starting installer'
$script:ResolvedTotalCommanderPath = $null
$script:ResolvedIniPath = $null

function Write-ResultFile([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($ResultPath)) { return }
    try {
        [IO.File]::WriteAllText($ResultPath, $Text, [Text.UTF8Encoding]::new($false))
    } catch {
        # The console output remains available if the result file cannot be written.
    }
}

trap {
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add('TCUNCGuard installation failed.')
    $lines.Add("Stage: $script:InstallationStage")
    $lines.Add("Reason: $($_.Exception.Message)")
    $lines.Add("Windows account: $TargetAccount")
    if ($script:ResolvedTotalCommanderPath) {
        $lines.Add("Total Commander: $script:ResolvedTotalCommanderPath")
    }
    if ($script:ResolvedIniPath) {
        $lines.Add("Wincmd.ini: $script:ResolvedIniPath")
    }
    $failureText = $lines -join [Environment]::NewLine
    Write-Host ''
    Write-Host $failureText -ForegroundColor Red
    Write-ResultFile $failureText
    exit 1
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Resolve-TotalCommanderDirectory([string]$Candidate) {
    if ([string]::IsNullOrWhiteSpace($Candidate)) { return $null }

    $candidate = $Candidate.Trim().Trim('"')
    if ([string]::IsNullOrWhiteSpace($candidate)) { return $null }

    try {
        $item = Get-Item -LiteralPath $candidate -ErrorAction Stop
        if ($item.PSIsContainer) {
            $directory = $item.FullName
        } elseif ($item.Name -ieq 'TOTALCMD64.EXE') {
            $directory = $item.DirectoryName
        } else {
            return $null
        }

        $executable = Join-Path -Path $directory -ChildPath 'TOTALCMD64.EXE'
        if (Test-Path -LiteralPath $executable -PathType Leaf) {
            return (Resolve-Path -LiteralPath $directory).Path
        }
    } catch {
        # Registry values can contain command-line arguments or other invalid data.
        # Ignore those entries and let the caller request a path from the user.
    }
    return $null
}

function Resolve-ExistingFilePath([string]$Candidate) {
    if ([string]::IsNullOrWhiteSpace($Candidate)) { return $null }

    $candidate = $Candidate.Trim().Trim('"')
    if ([string]::IsNullOrWhiteSpace($candidate)) { return $null }

    try {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $resolved = Resolve-Path -LiteralPath $candidate
            # PathInfo.Path uses a PowerShell-only prefix for UNC paths, for
            # example Microsoft.PowerShell.Core\FileSystem::\\server\share.
            # Win32 profile APIs require the native provider path instead.
            $nativePath = if ($resolved.ProviderPath) {
                $resolved.ProviderPath
            } else {
                $resolved.Path
            }
            if ($nativePath -match '^\\{3,}' -and
                -not $nativePath.StartsWith('\\?\')) {
                $nativePath = '\\' + $nativePath.TrimStart('\')
            }
            return $nativePath
        }
    } catch {
        # Ignore malformed registry values and continue with the next candidate.
    }
    return $null
}

function Find-TotalCommander {
    $candidates = [Collections.Generic.List[string]]::new()
    foreach ($registryPath in @(
        'HKCU:\Software\Ghisler\Total Commander',
        'HKLM:\Software\Ghisler\Total Commander',
        'HKLM:\Software\WOW6432Node\Ghisler\Total Commander'
    )) {
        $item = Get-ItemProperty -LiteralPath $registryPath -ErrorAction SilentlyContinue
        if ($item.InstallDir) {
            foreach ($installDir in @($item.InstallDir)) {
                $candidates.Add([Environment]::ExpandEnvironmentVariables([string]$installDir))
            }
        }
    }

    foreach ($appPath in @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\TOTALCMD64.EXE',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\App Paths\TOTALCMD64.EXE'
    )) {
        $key = Get-Item -LiteralPath $appPath -ErrorAction SilentlyContinue
        if ($key) {
            $executable = $key.GetValue('')
            if ($executable) {
                $candidates.Add([Environment]::ExpandEnvironmentVariables([string]$executable))
            }
        }
    }

    $candidates.Add('C:\Program Files\totalcmd')
    foreach ($drive in Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue) {
        if ($drive.Root) { $candidates.Add((Join-Path $drive.Root 'totalcmd')) }
    }
    foreach ($candidate in $candidates) {
        $directory = Resolve-TotalCommanderDirectory $candidate
        if ($directory) { return $directory }
    }
    return $null
}

function Find-WincmdIni {
    $candidates = [Collections.Generic.List[string]]::new()

    # Portable and shared Total Commander installations commonly keep the
    # active configuration beside TOTALCMD64.EXE. Prefer that file when it
    # exists; a stale/default profile INI may also exist and registry values
    # do not necessarily reflect a shortcut's /i= override.
    if ($TotalCommanderPath) {
        $candidates.Add((Join-Path $TotalCommanderPath 'Wincmd.ini'))
    }

    foreach ($registryPath in @(
        'HKCU:\Software\Ghisler\Total Commander',
        'HKLM:\Software\Ghisler\Total Commander',
        'HKLM:\Software\WOW6432Node\Ghisler\Total Commander'
    )) {
        $item = Get-ItemProperty -LiteralPath $registryPath -ErrorAction SilentlyContinue
        if ($item.IniFileName) {
            foreach ($iniFileName in @($item.IniFileName)) {
                $candidates.Add([Environment]::ExpandEnvironmentVariables([string]$iniFileName))
            }
        }
    }
    if ($env:APPDATA) { $candidates.Add((Join-Path $env:APPDATA 'GHISLER\Wincmd.ini')) }
    foreach ($candidate in $candidates) {
        $path = Resolve-ExistingFilePath $candidate
        if ($path) { return $path }
    }
    return $null
}

function Read-TextFilePreservingEncoding([string]$Path) {
    [byte[]]$bytes = [IO.File]::ReadAllBytes($Path)
    $offset = 0
    $emitBom = $false
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $encoding = [Text.UnicodeEncoding]::new($false, $true, $true)
        $offset = 2
        $emitBom = $true
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $encoding = [Text.UnicodeEncoding]::new($true, $true, $true)
        $offset = 2
        $emitBom = $true
    } elseif ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $encoding = [Text.UTF8Encoding]::new($true, $true)
        $offset = 3
        $emitBom = $true
    } else {
        $encoding = [Text.Encoding]::Default
    }
    $text = $encoding.GetString($bytes, $offset, $bytes.Length - $offset)
    return [pscustomobject]@{ Text = $text; Encoding = $encoding; EmitBom = $emitBom }
}

function Write-TextFilePreservingEncoding([string]$Path, [string]$Text,
                                           [Text.Encoding]$Encoding, [bool]$EmitBom) {
    [byte[]]$body = $Encoding.GetBytes($Text)
    [byte[]]$preamble = if ($EmitBom) { $Encoding.GetPreamble() } else { @() }
    [byte[]]$output = [byte[]]::new($preamble.Length + $body.Length)
    if ($preamble.Length) { [Array]::Copy($preamble, 0, $output, 0, $preamble.Length) }
    if ($body.Length) { [Array]::Copy($body, 0, $output, $preamble.Length, $body.Length) }
    $temporary = "$Path.tcuncguard-$PID.tmp"
    [IO.File]::WriteAllBytes($temporary, $output)
    if (Test-Path -LiteralPath $Path) {
        $replaceBackup = "$Path.tcuncguard-$PID.replace.bak"
        [IO.File]::Replace($temporary, $Path, $replaceBackup)
        Remove-Item -LiteralPath $replaceBackup -Force
    } else {
        Move-Item -LiteralPath $temporary -Destination $Path
    }
}

$script:InstallationStage = 'Choosing installation mode'
if (-not $Mode) {
    if ($Quiet) {
        $Mode = 'Full'
    } else {
        Write-Host 'Installation mode:'
        Write-Host '  1 - Full: install/update Autorun and TCUNCGuard'
        Write-Host '  2 - Plugin only: use the existing Autorun installation'
        $choice = Read-Host 'Choose 1 or 2'
        $Mode = if ($choice -eq '2') { 'PluginOnly' } else { 'Full' }
    }
}

$script:InstallationStage = 'Locating Total Commander x64'
if (-not $TotalCommanderPath) { $TotalCommanderPath = Find-TotalCommander }
$TotalCommanderPath = Resolve-TotalCommanderDirectory $TotalCommanderPath
if (-not $TotalCommanderPath) {
    if ($Quiet) { throw 'TOTALCMD64.EXE was not found.' }
    do {
        $manualPath = Read-Host 'Enter the Total Commander folder or the full path to TOTALCMD64.EXE'
        $TotalCommanderPath = Resolve-TotalCommanderDirectory $manualPath
        if (-not $TotalCommanderPath) {
            Write-Warning 'The path must point to a folder containing TOTALCMD64.EXE or to TOTALCMD64.EXE itself.'
        }
    } while (-not $TotalCommanderPath)
}
$script:ResolvedTotalCommanderPath = $TotalCommanderPath

# Resolve the current user's configuration before elevation. If UAC uses
# another administrator account, its HKCU and APPDATA point to another profile.
$script:InstallationStage = 'Locating the current Windows account Wincmd.ini'
$requestedIniPath = $IniPath
if (-not $IniPath) { $IniPath = Find-WincmdIni }
$IniPath = Resolve-ExistingFilePath $IniPath
if (-not $IniPath) {
    $checkedPaths = [Collections.Generic.List[string]]::new()
    if ($requestedIniPath) { $checkedPaths.Add([Environment]::ExpandEnvironmentVariables($requestedIniPath)) }
    $checkedPaths.Add((Join-Path $TotalCommanderPath 'Wincmd.ini'))
    if ($env:APPDATA) { $checkedPaths.Add((Join-Path $env:APPDATA 'GHISLER\Wincmd.ini')) }
    throw ("Wincmd.ini was not found for account '$TargetAccount'. Checked: " +
           (($checkedPaths | Select-Object -Unique) -join '; ') +
           '. Start Total Commander once under this account, close it, and run the installer again.')
}
$script:ResolvedIniPath = $IniPath

$script:InstallationStage = 'Checking for running Total Commander processes'
$running = Get-Process -Name TOTALCMD64 -ErrorAction SilentlyContinue
if ($running) {
    $processes = ($running | ForEach-Object {
        $processPath = try { $_.Path } catch { $null }
        if ($processPath) { "PID $($_.Id): $processPath" } else { "PID $($_.Id)" }
    }) -join '; '
    throw "Total Commander is still running ($processes). Close every TOTALCMD64.EXE process and run the installer again."
}

if (-not $NoElevation -and -not (Test-Administrator)) {
    $script:InstallationStage = 'Requesting administrator privileges'
    $elevationResultPath = Join-Path ([IO.Path]::GetTempPath()) ('TCUNCGuard-install-' + [guid]::NewGuid().ToString('N') + '.txt')
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath),
                   '-Mode', $Mode, '-TotalCommanderPath', ('"{0}"' -f $TotalCommanderPath),
                   '-IniPath', ('"{0}"' -f $IniPath), '-NoElevation', '-Quiet',
                   '-ResultPath', ('"{0}"' -f $elevationResultPath),
                   '-TargetAccount', ('"{0}"' -f $TargetAccount))
    try {
        $process = Start-Process powershell.exe -Verb RunAs -ArgumentList $arguments -Wait -PassThru
        $resultText = if (Test-Path -LiteralPath $elevationResultPath -PathType Leaf) {
            Get-Content -LiteralPath $elevationResultPath -Raw
        } else {
            $null
        }
    } finally {
        Remove-Item -LiteralPath $elevationResultPath -Force -ErrorAction SilentlyContinue
    }
    if ($resultText) { Write-Host $resultText }
    if ($process.ExitCode -ne 0 -and -not $resultText) {
        throw "The elevated installer exited with code $($process.ExitCode) without an error report."
    }
    exit $process.ExitCode
}

$script:InstallationStage = 'Checking installer payload'
$autorunTarget = Join-Path $TotalCommanderPath 'Plugins\wdx\Autorun'
$autorunBinary = Join-Path $autorunTarget 'Autorun.wdx64'
$modulePayload = Join-Path $PSScriptRoot 'payload\TCUNCGuard\TCUNCGuard.dll64'
if (-not (Test-Path -LiteralPath $modulePayload -PathType Leaf)) {
    throw "The installer archive is incomplete. Required file is missing: $modulePayload. Extract the complete release archive before running the installer."
}

$downloadRoot = Join-Path ([IO.Path]::GetTempPath()) ('TCUNCGuard-Autorun-' + [guid]::NewGuid().ToString('N'))
$autorunUrls = @(
    'https://totalcmd.net/download.php?id=autorun',
    'https://total.darkhost.ru/files/autorun/wdx_autorun_2.1.1.zip',
    'https://wincmd.ru/files/4323314/mirror/wdx_autorun_2.1.1.zip'
)

function Install-AutorunIfNeeded {
    if (Test-Path -LiteralPath $autorunBinary -PathType Leaf) {
        Write-Host 'Autorun is already installed; using the existing installation.'
        return
    }
    if ($Mode -eq 'PluginOnly') {
        throw "Autorun.wdx64 was not found at '$autorunBinary'. Choose Full installation or install Autorun in the selected Total Commander folder."
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    New-Item -ItemType Directory -Path $downloadRoot -Force | Out-Null
    $zipPath = Join-Path $downloadRoot 'autorun.zip'
    $extractPath = Join-Path $downloadRoot 'extract'
    $downloaded = $false
    $errors = [Collections.Generic.List[string]]::new()
    foreach ($url in $autorunUrls) {
        try {
            Write-Host "Downloading Autorun: $url"
            Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing -MaximumRedirection 8 -TimeoutSec 60
            if (Test-Path -LiteralPath $extractPath) {
                Remove-Item -LiteralPath $extractPath -Recurse -Force
            }
            Expand-Archive -LiteralPath $zipPath -DestinationPath $extractPath -Force
            if (-not (Test-Path -LiteralPath (Join-Path $extractPath 'Autorun.wdx64') -PathType Leaf)) {
                throw 'The downloaded archive did not contain Autorun.wdx64.'
            }
            $downloaded = $true
            break
        } catch {
            $errors.Add("$url — $($_.Exception.Message)")
        }
    }
    if (-not $downloaded) {
        throw ('Autorun download failed from all sources: ' + ($errors -join '; '))
    }

    New-Item -ItemType Directory -Path $autorunTarget -Force | Out-Null
    Copy-Item -Path (Join-Path $extractPath '*') -Destination $autorunTarget -Recurse -Force
    if (-not (Test-Path -LiteralPath $autorunBinary -PathType Leaf)) {
        throw 'Autorun installation completed without Autorun.wdx64.'
    }
    Write-Host 'Autorun was installed.'
}

function Ensure-AutorunRegistration([string]$ConfigurationPath) {
    if (-not ('TCUNCGuardIniNative' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class TCUNCGuardIniNative {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode)]
    public static extern uint GetPrivateProfileString(string section, string key, string fallback,
        StringBuilder value, uint size, string file);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern bool WritePrivateProfileString(string section, string key, string value, string file);
}
'@
    }

    function Get-IniValue([string]$Section, [string]$Key, [string]$File) {
        $buffer = [Text.StringBuilder]::new(32768)
        [void][TCUNCGuardIniNative]::GetPrivateProfileString($Section, $Key, '', $buffer, 32768, $File)
        return $buffer.ToString()
    }
    function Set-IniValue([string]$Section, [string]$Key, [string]$Value, [string]$File) {
        if (-not [TCUNCGuardIniNative]::WritePrivateProfileString($Section, $Key, $Value, $File)) {
            $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            if ($errorCode) {
                $errorMessage = [ComponentModel.Win32Exception]::new($errorCode).Message
                throw "Could not write [$Section] $Key to '$File'. Windows error $errorCode`: $errorMessage"
            }
            throw "Could not write [$Section] $Key to '$File'. Windows did not provide an error code."
        }
    }

    $registered = $false
    for ($i = 0; $i -le 200; $i++) {
        if ((Get-IniValue 'ContentPlugins' "$i" $ConfigurationPath) -match '(?i)[\\/]Autorun[\\/]Autorun\.wdx') {
            $registered = $true
            break
        }
    }
    if (-not $registered) {
        for ($i = 200; $i -ge 0; $i--) {
            $pluginValue = Get-IniValue 'ContentPlugins' "$i" $ConfigurationPath
            if (-not $pluginValue) { continue }
            Set-IniValue 'ContentPlugins' ([string]($i + 1)) $pluginValue $ConfigurationPath
            foreach ($suffix in @('_detect', '_date', '_flags')) {
                $metadata = Get-IniValue 'ContentPlugins' "$i$suffix" $ConfigurationPath
                if ($metadata) { Set-IniValue 'ContentPlugins' "$($i + 1)$suffix" $metadata $ConfigurationPath }
                [void][TCUNCGuardIniNative]::WritePrivateProfileString('ContentPlugins', "$i$suffix", $null, $ConfigurationPath)
            }
            [void][TCUNCGuardIniNative]::WritePrivateProfileString('ContentPlugins', "$i", $null, $ConfigurationPath)
        }
        Set-IniValue 'ContentPlugins' '0' '%COMMANDER_PATH%\Plugins\wdx\Autorun\Autorun.wdx' $ConfigurationPath
    }

    # Autorun is a content plugin, so merely registering Autorun.wdx does not
    # make Total Commander call it at startup. Autorun's documented loading
    # mechanism is a saved plugin search referenced by a file-color filter.
    Set-IniValue 'Searches' 'Autorun_SearchFor' '' $ConfigurationPath
    Set-IniValue 'Searches' 'Autorun_SearchIn' '' $ConfigurationPath
    Set-IniValue 'Searches' 'Autorun_SearchText' '' $ConfigurationPath
    Set-IniValue 'Searches' 'Autorun_SearchFlags' '0|000002000020|||||||||0000|||' $ConfigurationPath
    Set-IniValue 'Searches' 'Autorun_plugin' '"autorun.Autorun" = 1' $ConfigurationPath

    $hasAutorunColor = $false
    for ($i = 1; $i -le 200; $i++) {
        if ((Get-IniValue 'Colors' "ColorFilter$i" $ConfigurationPath) -eq '>Autorun') {
            $hasAutorunColor = $true
            break
        }
    }
    if (-not $hasAutorunColor) {
        for ($i = 200; $i -ge 1; $i--) {
            $filter = Get-IniValue 'Colors' "ColorFilter$i" $ConfigurationPath
            if (-not $filter) { continue }
            Set-IniValue 'Colors' "ColorFilter$($i + 1)" $filter $ConfigurationPath
            $color = Get-IniValue 'Colors' "ColorFilter${i}Color" $ConfigurationPath
            if ($color) { Set-IniValue 'Colors' "ColorFilter$($i + 1)Color" $color $ConfigurationPath }
            [void][TCUNCGuardIniNative]::WritePrivateProfileString('Colors', "ColorFilter$i", $null, $ConfigurationPath)
            [void][TCUNCGuardIniNative]::WritePrivateProfileString('Colors', "ColorFilter${i}Color", $null, $ConfigurationPath)
        }
        Set-IniValue 'Colors' 'ColorFilter1' '>Autorun' $ConfigurationPath
        Set-IniValue 'Colors' 'ColorFilter1Color' '0' $ConfigurationPath
    }
}

function Ensure-AutorunConfig([string]$ConfigPath) {
    $loadLine = 'LoadLibrary "%COMMANDER_PATH%\Plugins\wdx\Autorun\Plugins\TCUNCGuard.dll"'
    $stopLine = 'TCUNCGuardStop'
    $pragmaLine = 'Pragma AutorunFinalizeSection'
    if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
        $cfg = Read-TextFilePreservingEncoding $ConfigPath
        $newline = if ($cfg.Text -match "`r`n") { "`r`n" } elseif ($cfg.Text -match "`n") { "`n" } else { "`r`n" }
        $updated = [regex]::Replace($cfg.Text, '(?im)^[^\r\n]*(?:TCUNCGuard\.dll|TCUNCGuardStop)[^\r\n]*(?:\r\n|\n|\r)?', '')
        $pragmaMatch = [regex]::Match($updated, '(?im)^[^\r\n]*Pragma AutorunFinalizeSection[^\r\n]*(?:\r\n|\n|\r)?')
        if ($pragmaMatch.Success) {
            $updated = $updated.Insert($pragmaMatch.Index, $loadLine + $newline)
            $pragmaAfter = [regex]::Match($updated, '(?im)^[^\r\n]*Pragma AutorunFinalizeSection[^\r\n]*(?:\r\n|\n|\r)?')
            $updated = $updated.Insert($pragmaAfter.Index + $pragmaAfter.Length, $stopLine + $newline)
        } else {
            if ($updated -and -not ($updated.EndsWith("`n") -or $updated.EndsWith("`r"))) { $updated += $newline }
            $updated += $loadLine + $newline + $newline + $pragmaLine + $newline + $stopLine + $newline
        }
        if ($updated -ne $cfg.Text) {
            $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
            $backup = "$ConfigPath.tcuncguard-backup-$stamp.bak"
            Copy-Item -LiteralPath $ConfigPath -Destination $backup -ErrorAction Stop
            try {
                Write-TextFilePreservingEncoding $ConfigPath $updated $cfg.Encoding $cfg.EmitBom
            } catch {
                Copy-Item -LiteralPath $backup -Destination $ConfigPath -Force -ErrorAction Stop
                throw
            }
            Write-Host "Autorun configuration backup: $backup"
        }
    } else {
        $encoding = [Text.UnicodeEncoding]::new($false, $true, $true)
        $content = $loadLine + "`r`n`r`n" + $pragmaLine + "`r`n" + $stopLine + "`r`n"
        Write-TextFilePreservingEncoding $ConfigPath $content $encoding $true
    }
}

try {
    $script:InstallationStage = 'Installing or checking Autorun'
    Install-AutorunIfNeeded

    $script:InstallationStage = 'Backing up Wincmd.ini and Autorun configuration'
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $iniBackup = "$IniPath.tcuncguard-backup-$stamp.bak"
    Copy-Item -LiteralPath $IniPath -Destination $iniBackup -ErrorAction Stop
    $autorunCfg = Join-Path $autorunTarget 'autorun.cfg'
    $cfgExisted = Test-Path -LiteralPath $autorunCfg -PathType Leaf
    $cfgBackup = $null
    if ($cfgExisted) {
        $cfgBackup = "$autorunCfg.tcuncguard-transaction-$stamp.bak"
        Copy-Item -LiteralPath $autorunCfg -Destination $cfgBackup -ErrorAction Stop
    }
    $moduleTarget = Join-Path $autorunTarget 'Plugins\TCUNCGuard.dll64'
    $moduleExisted = Test-Path -LiteralPath $moduleTarget -PathType Leaf

    $script:InstallationStage = 'Registering Autorun in Wincmd.ini'
    Ensure-AutorunRegistration $IniPath
    $script:InstallationStage = 'Updating autorun.cfg'
    Ensure-AutorunConfig $autorunCfg
    $script:InstallationStage = 'Copying TCUNCGuard.dll64'
    New-Item -ItemType Directory -Path (Split-Path -Parent $moduleTarget) -Force | Out-Null
    Copy-Item -LiteralPath $modulePayload -Destination $moduleTarget -Force

    $script:InstallationStage = 'Installation completed'
    $successText = @(
        'TCUNCGuard installation completed successfully.'
        "Mode: $Mode"
        "Windows account: $TargetAccount"
        "Total Commander: $TotalCommanderPath"
        "Wincmd.ini: $IniPath"
        "Autorun: $autorunBinary"
        "TCUNCGuard: $moduleTarget"
        "Wincmd.ini backup: $iniBackup"
        'Start Total Commander to activate the plugin.'
    ) -join [Environment]::NewLine
    Write-Host $successText -ForegroundColor Green
    Write-ResultFile $successText
} catch {
    if ($iniBackup -and (Test-Path -LiteralPath $iniBackup)) {
        Copy-Item -LiteralPath $iniBackup -Destination $IniPath -Force -ErrorAction SilentlyContinue
    }
    if ($autorunCfg -and -not $cfgExisted -and (Test-Path -LiteralPath $autorunCfg)) {
        Remove-Item -LiteralPath $autorunCfg -Force -ErrorAction SilentlyContinue
    }
    if ($cfgBackup -and (Test-Path -LiteralPath $cfgBackup)) {
        Copy-Item -LiteralPath $cfgBackup -Destination $autorunCfg -Force -ErrorAction SilentlyContinue
    }
    if ($moduleTarget -and -not $moduleExisted -and (Test-Path -LiteralPath $moduleTarget)) {
        Remove-Item -LiteralPath $moduleTarget -Force -ErrorAction SilentlyContinue
    }
    throw
} finally {
    if (Test-Path -LiteralPath $downloadRoot) {
        Remove-Item -LiteralPath $downloadRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
