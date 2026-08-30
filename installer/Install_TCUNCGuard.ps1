#Requires -Version 5.1

param(
    [ValidateSet('Full', 'PluginOnly')]
    [string]$Mode,
    [string]$TotalCommanderPath,
    [string]$IniPath,
    [switch]$NoElevation,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Find-TotalCommander {
    $candidates = [Collections.Generic.List[string]]::new()
    foreach ($registryPath in @(
        'HKCU:\Software\Ghisler\Total Commander',
        'HKLM:\Software\Ghisler\Total Commander',
        'HKLM:\Software\WOW6432Node\Ghisler\Total Commander'
    )) {
        $item = Get-ItemProperty -LiteralPath $registryPath -ErrorAction SilentlyContinue
        if ($item.InstallDir) { $candidates.Add([Environment]::ExpandEnvironmentVariables($item.InstallDir)) }
    }
    $candidates.Add('C:\Program Files\totalcmd')
    $candidates.Add('C:\totalcmd')
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath (Join-Path $candidate 'TOTALCMD64.EXE'))) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    return $null
}

function Find-WincmdIni {
    $candidates = [Collections.Generic.List[string]]::new()
    foreach ($registryPath in @(
        'HKCU:\Software\Ghisler\Total Commander',
        'HKLM:\Software\Ghisler\Total Commander',
        'HKLM:\Software\WOW6432Node\Ghisler\Total Commander'
    )) {
        $item = Get-ItemProperty -LiteralPath $registryPath -ErrorAction SilentlyContinue
        if ($item.IniFileName) {
            $candidates.Add([Environment]::ExpandEnvironmentVariables($item.IniFileName))
        }
    }
    if ($TotalCommanderPath) { $candidates.Add((Join-Path $TotalCommanderPath 'Wincmd.ini')) }
    if ($env:APPDATA) { $candidates.Add((Join-Path $env:APPDATA 'GHISLER\Wincmd.ini')) }
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
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

if (-not $TotalCommanderPath) { $TotalCommanderPath = Find-TotalCommander }
if (-not $TotalCommanderPath -or -not (Test-Path -LiteralPath (Join-Path $TotalCommanderPath 'TOTALCMD64.EXE'))) {
    if ($Quiet) { throw 'TOTALCMD64.EXE was not found.' }
    $TotalCommanderPath = Read-Host 'Enter the folder containing TOTALCMD64.EXE'
}
$TotalCommanderPath = (Resolve-Path -LiteralPath $TotalCommanderPath).Path

$running = Get-Process -Name TOTALCMD64 -ErrorAction SilentlyContinue
if ($running) {
    throw 'Close all Total Commander processes and run the installer again.'
}

if (-not $NoElevation -and -not (Test-Administrator)) {
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath),
                   '-Mode', $Mode, '-TotalCommanderPath', ('"{0}"' -f $TotalCommanderPath),
                   '-NoElevation', '-Quiet')
    if ($IniPath) { $arguments += @('-IniPath', ('"{0}"' -f $IniPath)) }
    $process = Start-Process powershell.exe -Verb RunAs -ArgumentList $arguments -Wait -PassThru
    exit $process.ExitCode
}

$autorunTarget = Join-Path $TotalCommanderPath 'Plugins\wdx\Autorun'
$autorunBinary = Join-Path $autorunTarget 'Autorun.wdx64'
$modulePayload = Join-Path $PSScriptRoot 'payload\TCUNCGuard\TCUNCGuard.dll64'
if (-not (Test-Path -LiteralPath $modulePayload -PathType Leaf)) {
    throw "Installer payload is incomplete: $modulePayload"
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
        throw 'Autorun.wdx64 was not found. Choose Full installation or install Autorun separately.'
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
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode)]
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
            throw "Could not write [$Section] $Key"
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
    Install-AutorunIfNeeded
    if (-not $IniPath) { $IniPath = Find-WincmdIni }
    if (-not $IniPath -or -not (Test-Path -LiteralPath $IniPath -PathType Leaf)) {
        if ($Quiet) { throw 'Wincmd.ini was not found.' }
        $IniPath = Read-Host 'Enter the full path to Wincmd.ini'
    }
    $IniPath = (Resolve-Path -LiteralPath $IniPath).Path

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $iniBackup = "$IniPath.tcuncguard-backup-$stamp.bak"
    Copy-Item -LiteralPath $IniPath -Destination $iniBackup -ErrorAction Stop
    $autorunCfg = Join-Path $autorunTarget 'autorun.cfg'
    $cfgExisted = Test-Path -LiteralPath $autorunCfg -PathType Leaf
    $moduleTarget = Join-Path $autorunTarget 'Plugins\TCUNCGuard.dll64'
    $moduleExisted = Test-Path -LiteralPath $moduleTarget -PathType Leaf

    Ensure-AutorunRegistration $IniPath
    Ensure-AutorunConfig $autorunCfg
    New-Item -ItemType Directory -Path (Split-Path -Parent $moduleTarget) -Force | Out-Null
    Copy-Item -LiteralPath $modulePayload -Destination $moduleTarget -Force

    Write-Host "Wincmd.ini backup: $iniBackup"
    Write-Host "TCUNCGuard was installed in $Mode mode. Start Total Commander to activate it."
} catch {
    if ($iniBackup -and (Test-Path -LiteralPath $iniBackup)) {
        Copy-Item -LiteralPath $iniBackup -Destination $IniPath -Force -ErrorAction SilentlyContinue
    }
    if ($autorunCfg -and -not $cfgExisted -and (Test-Path -LiteralPath $autorunCfg)) {
        Remove-Item -LiteralPath $autorunCfg -Force -ErrorAction SilentlyContinue
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
