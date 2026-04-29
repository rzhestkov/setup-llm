<#
Блок: параметры остановки.
TargetPath можно указать явно или дать скрипту найти portable-папку рядом с собой.
#>
[CmdletBinding()]
param(
    [string]$TargetPath
)

<#
Блок: базовые настройки.
Ошибки обработки не должны мешать удалить устаревшие PID-файлы.
#>
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

<#
Блок: сообщения и путь.
Остановка намеренно простая: читаем PID и останавливаем процессы.
#>
function Write-Info {
    param([string]$Text)
    Write-Host "[INFO] $Text" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Text)
    Write-Host "[OK] $Text" -ForegroundColor Green
}

function Convert-ToTargetPath {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        $Value = Read-Host 'Введите папку PortableLLM, например H:\LLM, или только букву диска H'
    }

    $trimmed = $Value.Trim()
    if ($trimmed -match '^[A-Za-z](:)?$') {
        return ('{0}:\LLM' -f $trimmed.Substring(0, 1).ToUpperInvariant())
    }

    if (-not [System.IO.Path]::IsPathRooted($trimmed)) {
        throw 'Нужно указать полный путь вроде H:\LLM или одну букву диска, например H.'
    }

    return [System.IO.Path]::GetFullPath($trimmed)
}

function Resolve-Root {
    if (-not [string]::IsNullOrWhiteSpace($TargetPath)) {
        return Convert-ToTargetPath -Value $TargetPath
    }

    $scriptDir = Split-Path -Parent $PSCommandPath
    $candidate = Split-Path -Parent $scriptDir
    if (Test-Path -LiteralPath (Join-Path $candidate 'config\portablellm.ini')) {
        return $candidate
    }

    return Convert-ToTargetPath -Value $null
}

<#
Блок: чтение PID.
PID-файлы являются простыми UTF-8 текстовыми файлами в logs.
#>
function Read-Pid {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $text = (Get-Content -LiteralPath $Path -Encoding UTF8 | Select-Object -First 1).Trim()
    $pidValue = 0
    if ([int]::TryParse($text, [ref]$pidValue)) {
        return $pidValue
    }

    return $null
}

<#
Блок: остановка процесса.
Сначала обычная остановка, потом принудительная, если процесс ещё жив.
#>
function Stop-ProcessSafely {
    param(
        [System.Diagnostics.Process]$Process,
        [string]$Name
    )

    Write-Info ("Остановка {0}, PID {1}..." -f $Name, $Process.Id)
    Stop-Process -Id $Process.Id -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    if (Get-Process -Id $Process.Id -ErrorAction SilentlyContinue) {
        Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
    }

    Write-Ok ("{0} остановлен, PID {1}." -f $Name, $Process.Id)
}

function Stop-ByPidFile {
    param(
        [string]$Name,
        [string]$PidPath
    )

    $pidValue = Read-Pid -Path $PidPath
    if (-not $pidValue) {
        Write-Info ("PID для {0} не найден." -f $Name)
        return
    }

    $process = Get-Process -Id $pidValue -ErrorAction SilentlyContinue
    if (-not $process) {
        Write-Info ("Процесс {0} уже не запущен." -f $Name)
        Remove-Item -LiteralPath $PidPath -Force -ErrorAction SilentlyContinue
        return
    }

    Stop-ProcessSafely -Process $process -Name $Name
    Remove-Item -LiteralPath $PidPath -Force -ErrorAction SilentlyContinue
}

<#
Блок: остановка оставшихся процессов из portable-папки.
Если раньше случайно запустили несколько копий, PID-файлы знают только последнюю пару.
#>
function Stop-ByExePath {
    param(
        [string]$Name,
        [string]$ExePath
    )

    if (-not (Test-Path -LiteralPath $ExePath)) {
        return
    }

    $processName = [System.IO.Path]::GetFileNameWithoutExtension($ExePath)
    $fullPath = [System.IO.Path]::GetFullPath($ExePath)
    $processes = @()

    foreach ($process in @(Get-Process -Name $processName -ErrorAction SilentlyContinue)) {
        try {
            if ($process.Path -and ([System.IO.Path]::GetFullPath($process.Path) -ieq $fullPath)) {
                $processes += $process
            }
        }
        catch {
        }
    }

    foreach ($process in $processes) {
        Stop-ProcessSafely -Process $process -Name $Name
    }
}

<#
Блок: основная остановка.
Останавливаются оба процесса, если их PID-файлы существуют.
#>
$root = Resolve-Root
$logsDir = Join-Path $root 'logs'
$llamaExe = Join-Path $root 'llama.cpp\bin\llama-server.exe'
$webUIExe = Join-Path $root 'OpenWebUI\packages\bin\open-webui.exe'

Stop-ByPidFile -Name 'Open WebUI' -PidPath (Join-Path $logsDir 'webui.pid')
Stop-ByPidFile -Name 'llama-server' -PidPath (Join-Path $logsDir 'llama.pid')
Stop-ByExePath -Name 'Open WebUI' -ExePath $webUIExe
Stop-ByExePath -Name 'llama-server' -ExePath $llamaExe

Write-Ok 'Остановка завершена.'
