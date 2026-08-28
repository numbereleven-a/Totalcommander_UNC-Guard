#Requires -Version 5.1

param(
    [string]$TotalCommanderPath,
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

if (-not $TotalCommanderPath) { $TotalCommanderPath = Find-TotalCommander }
if (-not $TotalCommanderPath -or -not (Test-Path -LiteralPath (Join-Path $TotalCommanderPath 'TOTALCMD64.EXE'))) {
    if ($Quiet) { throw 'TOTALCMD64.EXE was not found.' }
    $TotalCommanderPath = Read-Host 'Enter the folder containing TOTALCMD64.EXE'
}
$TotalCommanderPath = (Resolve-Path -LiteralPath $TotalCommanderPath).Path

$autorunTarget = Join-Path $TotalCommanderPath 'Plugins\wdx\Autorun'
$autorunPlugin = Join-Path $autorunTarget 'Autorun.wdx64'
if (-not (Test-Path -LiteralPath $autorunPlugin -PathType Leaf)) {
    throw 'The external Autorun WDX plugin is required. Install Autorun first, then run this installer again.'
}

if (Get-Process -Name TOTALCMD64 -ErrorAction SilentlyContinue) {
    throw 'Close Total Commander and run the installer again.'
}

$payload = Join-Path $PSScriptRoot 'payload\TCUNCGuard\TCUNCGuard.dll64'
if (-not (Test-Path -LiteralPath $payload -PathType Leaf)) {
    throw "Installer payload is incomplete: $payload"
}

if (-not $NoElevation -and -not (Test-Administrator)) {
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath),
                   '-TotalCommanderPath', ('"{0}"' -f $TotalCommanderPath), '-NoElevation', '-Quiet')
    $process = Start-Process powershell.exe -Verb RunAs -ArgumentList $arguments -Wait -PassThru
    exit $process.ExitCode
}

$pluginDirectory = Join-Path $autorunTarget 'Plugins'
$pluginTarget = Join-Path $pluginDirectory 'TCUNCGuard.dll64'
$autorunCfg = Join-Path $autorunTarget 'autorun.cfg'
$loadLine = 'LoadLibrary "%COMMANDER_PATH%\Plugins\wdx\Autorun\Plugins\TCUNCGuard.dll"'
$stopLine = 'TCUNCGuardStop'
$pragmaLine = 'Pragma AutorunFinalizeSection'

New-Item -ItemType Directory -Path $pluginDirectory -Force | Out-Null
Copy-Item -LiteralPath $payload -Destination $pluginTarget -Force

if (Test-Path -LiteralPath $autorunCfg -PathType Leaf) {
    $cfg = Read-TextFilePreservingEncoding $autorunCfg
    $newline = if ($cfg.Text -match "`r`n") { "`r`n" } elseif ($cfg.Text -match "`n") { "`n" } else { "`r`n" }
    $updated = [regex]::Replace($cfg.Text, '(?im)^[^\r\n]*(?:TCUNCGuard\.dll|TCUNCGuardStop)[^\r\n]*(?:\r\n|\n|\r)?', '')
    $loadBlock = $loadLine + $newline
    $pragmaMatch = [regex]::Match($updated, '(?im)^[^\r\n]*Pragma AutorunFinalizeSection[^\r\n]*(?:\r\n|\n|\r)?')
    if ($pragmaMatch.Success) {
        $updated = $updated.Insert($pragmaMatch.Index, $loadBlock)
        $pragmaEnd = $pragmaMatch.Index + $loadBlock.Length + $pragmaMatch.Length
        $updated = $updated.Insert($pragmaEnd, $stopLine + $newline)
    } else {
        if ($updated -and -not ($updated.EndsWith("`n") -or $updated.EndsWith("`r"))) { $updated += $newline }
        $updated += $loadLine + $newline + $newline + $pragmaLine + $newline + $stopLine + $newline
    }
    if ($updated -ne $cfg.Text) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
        $backup = "$autorunCfg.tcuncguard-backup-$stamp.bak"
        Copy-Item -LiteralPath $autorunCfg -Destination $backup -ErrorAction Stop
        try {
            Write-TextFilePreservingEncoding $autorunCfg $updated $cfg.Encoding $cfg.EmitBom
        } catch {
            Copy-Item -LiteralPath $backup -Destination $autorunCfg -Force -ErrorAction Stop
            throw
        }
        Write-Host "Autorun configuration backup: $backup"
    }
} else {
    $encoding = [Text.UnicodeEncoding]::new($false, $true, $true)
    $content = $loadLine + "`r`n`r`n" + $pragmaLine + "`r`n" + $stopLine + "`r`n"
    Write-TextFilePreservingEncoding $autorunCfg $content $encoding $true
}

Write-Host 'TCUNCGuard was installed. Start Total Commander and press Enter in the path bar to test it.'
