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
    $replaceBackup = "$Path.tcuncguard-$PID.replace.bak"
    [IO.File]::Replace($temporary, $Path, $replaceBackup)
    Remove-Item -LiteralPath $replaceBackup -Force
}

if (-not $TotalCommanderPath) { $TotalCommanderPath = Find-TotalCommander }
if (-not $TotalCommanderPath -or -not (Test-Path -LiteralPath (Join-Path $TotalCommanderPath 'TOTALCMD64.EXE'))) {
    if ($Quiet) { throw 'TOTALCMD64.EXE was not found.' }
    $TotalCommanderPath = Read-Host 'Enter the folder containing TOTALCMD64.EXE'
}
$TotalCommanderPath = (Resolve-Path -LiteralPath $TotalCommanderPath).Path

if (Get-Process -Name TOTALCMD64 -ErrorAction SilentlyContinue) {
    throw 'Close Total Commander and run the uninstaller again.'
}

if (-not $NoElevation -and -not (Test-Administrator)) {
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath),
                   '-TotalCommanderPath', ('"{0}"' -f $TotalCommanderPath), '-NoElevation', '-Quiet')
    $process = Start-Process powershell.exe -Verb RunAs -ArgumentList $arguments -Wait -PassThru
    exit $process.ExitCode
}

$autorunTarget = Join-Path $TotalCommanderPath 'Plugins\wdx\Autorun'
$autorunCfg = Join-Path $autorunTarget 'autorun.cfg'
if (Test-Path -LiteralPath $autorunCfg -PathType Leaf) {
    $cfg = Read-TextFilePreservingEncoding $autorunCfg
    $updated = [regex]::Replace($cfg.Text, '(?im)^[^\r\n]*(?:TCUNCGuard\.dll|TCUNCGuardStop)[^\r\n]*(?:\r\n|\n|\r)?', '')
    if ($updated -ne $cfg.Text) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
        $backup = "$autorunCfg.tcuncguard-uninstall-$stamp.bak"
        Copy-Item -LiteralPath $autorunCfg -Destination $backup -ErrorAction Stop
        try {
            Write-TextFilePreservingEncoding $autorunCfg $updated $cfg.Encoding $cfg.EmitBom
        } catch {
            Copy-Item -LiteralPath $backup -Destination $autorunCfg -Force -ErrorAction Stop
            throw
        }
        Write-Host "Autorun configuration backup: $backup"
    }
}

$pluginTarget = Join-Path $autorunTarget 'Plugins\TCUNCGuard.dll64'
if (Test-Path -LiteralPath $pluginTarget -PathType Leaf) {
    Remove-Item -LiteralPath $pluginTarget -Force
}

Write-Host 'TCUNCGuard was removed. The external Autorun installation was preserved.'
