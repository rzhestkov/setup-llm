<#
Быстрый перезапуск только llama-server.
Open WebUI продолжает работать, а параметры запуска собираются из базового
portablellm.ini и необязательного overlay-файла restartllm.ini.
#>
[CmdletBinding()]
param(
    [string]$TargetPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Write-Info {
    param([string]$Text)
    Write-Host "[INFO] $Text" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Text)
    Write-Host "[OK] $Text" -ForegroundColor Green
}

function Write-Utf8Bom {
    param(
        [string]$Path,
        [string]$Text
    )

    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($true)))
}

function Add-RestartLog {
    param(
        [string]$Path,
        [string]$Text
    )

    Add-Content -LiteralPath $Path -Encoding UTF8 -Value ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text)
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

function Join-PortablePath {
    param(
        [string]$Root,
        [string]$Value
    )

    if ([System.IO.Path]::IsPathRooted($Value)) {
        return $Value
    }

    return [System.IO.Path]::GetFullPath((Join-Path $Root $Value))
}

function Read-SimpleConfig {
    param([string]$Path)

    $config = @{}
    if (-not (Test-Path -LiteralPath $Path)) {
        return $config
    }

    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        $trimmed = $line.Trim()
        if ($trimmed -eq '' -or $trimmed.StartsWith('#') -or $trimmed.StartsWith(';')) {
            continue
        }

        if ($trimmed -match '^(.*?)=(.*)$') {
            $config[$matches[1].Trim()] = $matches[2].Trim()
        }
    }

    return $config
}

function Get-ConfigKeyOrder {
    param([string]$Path)

    $keys = @()
    if (-not (Test-Path -LiteralPath $Path)) {
        return $keys
    }

    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        $trimmed = $line.Trim()
        if ($trimmed -eq '' -or $trimmed.StartsWith('#') -or $trimmed.StartsWith(';')) {
            continue
        }

        if ($trimmed -match '^(.*?)=(.*)$') {
            $key = $matches[1].Trim()
            if ($keys -notcontains $key) {
                $keys += $key
            }
        }
    }

    return $keys
}

function Get-ConfigValue {
    param(
        [hashtable]$Config,
        [string]$Key,
        [string]$DefaultValue
    )

    if ($Config.ContainsKey($Key) -and -not [string]::IsNullOrWhiteSpace($Config[$Key])) {
        return $Config[$Key]
    }

    return $DefaultValue
}

function Test-ConfigEnabled {
    param(
        [hashtable]$Config,
        [string]$Key,
        [string]$DefaultValue = 'false'
    )

    $value = Get-ConfigValue -Config $Config -Key $Key -DefaultValue $DefaultValue
    return ($value -match '^(1|true|yes|y|да|д|on)$')
}

function Merge-ConfigFiles {
    param(
        [string]$BasePath,
        [string]$OverridePath,
        [string]$OutputPath
    )

    $override = Read-SimpleConfig -Path $OverridePath
    $overrideKeys = @(Get-ConfigKeyOrder -Path $OverridePath)
    $seen = @{}
    $result = @()

    foreach ($line in Get-Content -LiteralPath $BasePath -Encoding UTF8) {
        if ($line.Trim() -match '^(.*?)=(.*)$') {
            $key = $matches[1].Trim()
            $seen[$key] = $true
            if ($override.ContainsKey($key)) {
                $result += ('{0}={1}' -f $key, $override[$key])
                continue
            }
        }

        $result += $line
    }

    foreach ($key in $overrideKeys) {
        if (-not $seen.ContainsKey($key)) {
            $result += ('{0}={1}' -f $key, $override[$key])
        }
    }

    $outputDir = Split-Path -Parent $OutputPath
    if (-not (Test-Path -LiteralPath $outputDir)) {
        $null = New-Item -ItemType Directory -Path $outputDir -Force
    }

    Write-Utf8Bom -Path $OutputPath -Text (($result -join "`r`n").TrimEnd() + "`r`n")
    return $override
}

function Show-ConfigOverrides {
    param(
        [hashtable]$BaseConfig,
        [hashtable]$OverrideConfig,
        [string[]]$OverrideKeys,
        [string]$LogPath
    )

    if ($OverrideKeys.Count -eq 0) {
        $message = 'restartllm.ini не содержит переопределений. Используется базовая конфигурация portablellm.ini.'
        Write-Info $message
        Add-RestartLog -Path $LogPath -Text $message
        return
    }

    Write-Host ''
    Write-Host 'Параметры экспериментального перезапуска:'
    $rows = foreach ($key in $OverrideKeys) {
        $baseValue = '<не задано>'
        if ($BaseConfig.ContainsKey($key)) {
            $baseValue = [string]$BaseConfig[$key]
        }

        [PSCustomObject]@{
            Parameter = $key
            Base      = $baseValue
            Effective = [string]$OverrideConfig[$key]
        }
        Add-RestartLog -Path $LogPath -Text ('Override: {0}: "{1}" -> "{2}"' -f $key, $baseValue, [string]$OverrideConfig[$key])
    }

    $rows | Format-Table -AutoSize
}

function Select-Model {
    param([string]$ModelsDir)

    $models = @(Get-ChildItem -LiteralPath $ModelsDir -Filter '*.gguf' -File | Sort-Object Name)
    if (-not $models) {
        throw ("В папке моделей нет .gguf файлов: {0}" -f $ModelsDir)
    }

    if ($models.Count -eq 1) {
        return $models[0].FullName
    }

    Write-Host ''
    Write-Host 'Выберите модель:'
    for ($i = 0; $i -lt $models.Count; $i++) {
        Write-Host ('  {0}. {1}' -f ($i + 1), $models[$i].Name)
    }

    $answer = Read-Host 'Введите номер модели'
    $number = 0
    if (-not [int]::TryParse($answer, [ref]$number) -or $number -lt 1 -or $number -gt $models.Count) {
        throw 'Выбран некорректный номер модели.'
    }

    return $models[$number - 1].FullName
}

function Convert-ToArgumentLine {
    param([string[]]$CommandArguments)

    $quoted = @()
    foreach ($argument in $CommandArguments) {
        if ($argument -match '[\s"]') {
            $quoted += ('"{0}"' -f $argument.Replace('"', '\"'))
        }
        else {
            $quoted += $argument
        }
    }

    return ($quoted -join ' ')
}

function Invoke-CapturedProcess {
    param(
        [string]$Exe,
        [string[]]$CommandArguments,
        [string]$WorkingDir,
        [int]$TimeoutSeconds
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $Exe
    $startInfo.Arguments = Convert-ToArgumentLine -CommandArguments $CommandArguments
    $startInfo.WorkingDirectory = $WorkingDir
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $null = $process.Start()
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        try { $process.Kill() } catch {}
        throw ("Команда не завершилась за {0} секунд: {1}" -f $TimeoutSeconds, $Exe)
    }

    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    return [PSCustomObject]@{
        ExitCode = $process.ExitCode
        Output   = (($stdout, $stderr) -join "`r`n").Trim()
    }
}

function Find-DllPath {
    param(
        [string]$DllName,
        [string]$PreferredDir
    )

    $dirs = @($PreferredDir, [Environment]::GetFolderPath('System'))
    if (-not [string]::IsNullOrWhiteSpace($env:PATH)) {
        $dirs += ($env:PATH -split ';')
    }

    foreach ($dir in $dirs) {
        if ([string]::IsNullOrWhiteSpace($dir)) { continue }
        try {
            $candidate = [System.IO.Path]::Combine($dir.Trim().Trim('"'), $DllName)
            if (Test-Path -LiteralPath $candidate) { return $candidate }
        }
        catch {}
    }

    return $null
}

function Assert-CudaBackend {
    param(
        [string]$LlamaExe,
        [string]$LogPath
    )

    $llamaBinDir = Split-Path -Parent $LlamaExe
    $missing = @()
    foreach ($dll in @('ggml-cuda.dll', 'cublas64_12.dll', 'cudart64_12.dll', 'nvcuda.dll')) {
        $path = Find-DllPath -DllName $dll -PreferredDir $llamaBinDir
        if ($path) {
            Add-RestartLog -Path $LogPath -Text ('CUDA DLL найдена: {0}' -f $path)
        }
        else {
            $missing += $dll
        }
    }

    if ($missing) {
        throw ("CUDA backend llama.cpp не готов. Не найдены DLL: {0}." -f ($missing -join ', '))
    }

    $probe = Invoke-CapturedProcess -Exe $LlamaExe -CommandArguments @('--list-devices') -WorkingDir $llamaBinDir -TimeoutSeconds 30
    [System.IO.File]::WriteAllText((Join-Path (Split-Path -Parent $LogPath) 'cuda-check.log'), ($probe.Output + "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
    if ($probe.Output -notmatch '(?i)(CUDA|NVIDIA|GeForce|RTX)') {
        throw 'llama.cpp не увидел CUDA-устройство. Подробности см. в logs\cuda-check.log.'
    }
}

function Get-FreeVramBytes {
    param([string]$LogPath)

    $nvidiaSmi = Get-Command 'nvidia-smi.exe' -ErrorAction SilentlyContinue
    if (-not $nvidiaSmi) {
        Add-RestartLog -Path $LogPath -Text 'nvidia-smi.exe не найден, оценка VRAM пропущена.'
        return $null
    }

    try {
        $output = & $nvidiaSmi.Source --query-gpu=memory.free --format=csv,noheader,nounits 2>$null | Select-Object -First 1
        $freeMiB = 0
        if ([int64]::TryParse(($output -as [string]).Trim(), [ref]$freeMiB)) {
            return ($freeMiB * 1MB)
        }
    }
    catch {
        Add-RestartLog -Path $LogPath -Text ('Не удалось получить свободную VRAM: {0}' -f $_.Exception.Message)
    }

    return $null
}

function Test-ModelVramFit {
    param(
        [string]$ModelPath,
        [double]$ReserveGb,
        [string]$LogPath
    )

    $modelFile = Get-Item -LiteralPath $ModelPath
    $freeVramBytes = Get-FreeVramBytes -LogPath $LogPath
    if (-not $freeVramBytes) { return }

    $requiredBytes = [int64]($modelFile.Length + ($ReserveGb * 1GB))
    $modelGb = [math]::Round($modelFile.Length / 1GB, 2)
    $freeGb = [math]::Round($freeVramBytes / 1GB, 2)
    $requiredGb = [math]::Round($requiredBytes / 1GB, 2)

    Write-Info ('Оценка VRAM: модель {0} GB + резерв {1} GB = {2} GB; свободно {3} GB.' -f $modelGb, $ReserveGb, $requiredGb, $freeGb)
    Add-RestartLog -Path $LogPath -Text ('VRAM estimate: model={0} GB, reserve={1} GB, required={2} GB, free={3} GB' -f $modelGb, $ReserveGb, $requiredGb, $freeGb)
    if ($requiredBytes -gt $freeVramBytes) {
        Write-Host '[WARN] Модель может не поместиться в VRAM при полном GPU-offload.' -ForegroundColor Yellow
        Add-RestartLog -Path $LogPath -Text 'WARN: модель может не поместиться в VRAM.'
    }
}

function Test-LlamaDetailedVramFit {
    param(
        [string]$LlamaExe,
        [string]$ModelPath,
        [string]$GpuLayers,
        [string]$FlashAttention,
        [string]$CacheTypeK,
        [string]$CacheTypeV,
        [string]$SplitMode,
        [string]$MainGpu,
        [string]$CtxSize,
        [string]$BatchSize,
        [string]$UBatchSize,
        [string]$Fit,
        [string]$FitTargetMiB,
        [string]$FitCtx,
        [string]$ParallelSlots,
        [bool]$NoMmap,
        [bool]$CpuMoe,
        [string]$NCpuMoe,
        [string]$LogPath
    )

    $fitExe = Join-Path (Split-Path -Parent $LlamaExe) 'llama-fit-params.exe'
    if (-not (Test-Path -LiteralPath $fitExe)) {
        Add-RestartLog -Path $LogPath -Text 'llama-fit-params.exe не найден; используется грубая оценка VRAM.'
        return $false
    }

    $fitArgs = @(
        '--model', $ModelPath,
        '--gpu-layers', $GpuLayers,
        '--flash-attn', $FlashAttention,
        '--cache-type-k', $CacheTypeK,
        '--cache-type-v', $CacheTypeV,
        '--split-mode', $SplitMode,
        '--main-gpu', $MainGpu,
        '--ctx-size', $CtxSize,
        '--batch-size', $BatchSize,
        '--ubatch-size', $UBatchSize,
        '--fit', $Fit,
        '--fit-target', $FitTargetMiB,
        '--fit-ctx', $FitCtx,
        '--parallel', $ParallelSlots,
        '--fit-print', 'on'
    )
    if ($NoMmap) { $fitArgs += '--no-mmap' }
    if ($CpuMoe) { $fitArgs += '--cpu-moe' }
    if (-not [string]::IsNullOrWhiteSpace($NCpuMoe)) { $fitArgs += @('--n-cpu-moe', $NCpuMoe) }

    try {
        $probe = Invoke-CapturedProcess -Exe $fitExe -CommandArguments $fitArgs -WorkingDir (Split-Path -Parent $fitExe) -TimeoutSeconds 120
        Add-RestartLog -Path $LogPath -Text ('llama-fit-params exit code: {0}' -f $probe.ExitCode)
        foreach ($line in ($probe.Output -split "`r?`n")) {
            if ($line -match '^(CUDA\d+|Host)\s+\d+\s+\d+\s+\d+') {
                Add-RestartLog -Path $LogPath -Text ('Memory estimate raw: {0}' -f $line.Trim())
            }
        }

        $matches = [regex]::Matches($probe.Output, '(?m)^CUDA\d+\s+(\d+)\s+(\d+)\s+(\d+)\s*$')
        if ($matches.Count -eq 0) {
            Add-RestartLog -Path $LogPath -Text 'llama-fit-params не вернул распознаваемую CUDA-оценку; используется грубая оценка.'
            return $false
        }

        $modelMiB = 0
        $contextMiB = 0
        $computeMiB = 0
        foreach ($match in $matches) {
            $modelMiB += [int64]$match.Groups[1].Value
            $contextMiB += [int64]$match.Groups[2].Value
            $computeMiB += [int64]$match.Groups[3].Value
        }
        $requiredMiB = $modelMiB + $contextMiB + $computeMiB
        $freeBytes = Get-FreeVramBytes -LogPath $LogPath
        if (-not $freeBytes) {
            Write-Info ('Детальная оценка VRAM: model={0} MiB, context={1} MiB, compute={2} MiB, всего={3} MiB.' -f $modelMiB, $contextMiB, $computeMiB, $requiredMiB)
            return $true
        }

        $freeMiB = [int64]($freeBytes / 1MB)
        $remainingMiB = $freeMiB - $requiredMiB
        $targetText = ($FitTargetMiB -split ',')[0].Trim()
        [int64]$targetMiB = 0
        [void][int64]::TryParse($targetText, [ref]$targetMiB)
        $status = 'safe'
        if ($remainingMiB -lt 0) { $status = 'oversubscribed' }
        elseif ($remainingMiB -lt $targetMiB) { $status = 'low VRAM margin' }

        $summary = 'Детальная оценка VRAM: model={0} MiB + context={1} MiB + compute={2} MiB = {3} MiB; свободно={4} MiB; остаток={5} MiB; статус={6}.' -f $modelMiB, $contextMiB, $computeMiB, $requiredMiB, $freeMiB, $remainingMiB, $status
        Write-Info $summary
        Add-RestartLog -Path $LogPath -Text $summary
        if ($status -ne 'safe') {
            Write-Host ('[WARN] {0}' -f $status) -ForegroundColor Yellow
            $advice = 'Для увеличения запаса можно изменить CtxSize, CacheTypeK/CacheTypeV, BatchSize/UBatchSize или GpuLayers.'
            Write-Host ('[WARN] {0}' -f $advice) -ForegroundColor Yellow
            Add-RestartLog -Path $LogPath -Text $advice
        }
        return $true
    }
    catch {
        Add-RestartLog -Path $LogPath -Text ('Детальная оценка VRAM не выполнена: {0}' -f $_.Exception.Message)
        return $false
    }
}

function Read-Pid {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $text = (Get-Content -LiteralPath $Path -Encoding UTF8 | Select-Object -First 1).Trim()
    $pidValue = 0
    if ([int]::TryParse($text, [ref]$pidValue)) { return $pidValue }
    return $null
}

function Stop-ProcessSafely {
    param(
        [System.Diagnostics.Process]$Process,
        [string]$Name,
        [string]$LogPath
    )

    Write-Info ("Остановка {0}, PID {1}..." -f $Name, $Process.Id)
    Add-RestartLog -Path $LogPath -Text ('Остановка {0}, PID {1}.' -f $Name, $Process.Id)
    Stop-Process -Id $Process.Id -ErrorAction SilentlyContinue
    $Process.WaitForExit(10000) | Out-Null
    if (Get-Process -Id $Process.Id -ErrorAction SilentlyContinue) {
        Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
    }
    Write-Ok ("{0} остановлен." -f $Name)
}

function Stop-LlamaServer {
    param(
        [string]$LlamaExe,
        [string]$PidPath,
        [string]$LogPath
    )

    $stopped = @{}
    $pidValue = Read-Pid -Path $PidPath
    if ($pidValue) {
        $process = Get-Process -Id $pidValue -ErrorAction SilentlyContinue
        if ($process) {
            Stop-ProcessSafely -Process $process -Name 'llama-server' -LogPath $LogPath
            $stopped[$pidValue] = $true
        }
        Remove-Item -LiteralPath $PidPath -Force -ErrorAction SilentlyContinue
    }

    if (-not (Test-Path -LiteralPath $LlamaExe)) { return }
    $processName = [System.IO.Path]::GetFileNameWithoutExtension($LlamaExe)
    $fullPath = [System.IO.Path]::GetFullPath($LlamaExe)
    foreach ($process in @(Get-Process -Name $processName -ErrorAction SilentlyContinue)) {
        if ($stopped.ContainsKey($process.Id)) { continue }
        try {
            if ($process.Path -and ([System.IO.Path]::GetFullPath($process.Path) -ieq $fullPath)) {
                Stop-ProcessSafely -Process $process -Name 'llama-server' -LogPath $LogPath
            }
        }
        catch {}
    }
}

function Test-PortFree {
    param([int]$Port)

    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
    try {
        $listener.Start()
        return $true
    }
    catch { return $false }
    finally { if ($listener) { $listener.Stop() } }
}

function Get-FreePort {
    param([int]$PreferredPort)

    $port = $PreferredPort
    while ($port -lt 65535) {
        if (Test-PortFree -Port $port) { return $port }
        $port++
    }
    throw ('Не удалось найти свободный порт начиная с {0}.' -f $PreferredPort)
}

function Wait-ServicePort {
    param(
        [System.Diagnostics.Process]$Process,
        [string]$HostName,
        [int]$Port,
        [int]$TimeoutSeconds,
        [string]$LogPath
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $Process.Refresh()
        if ($Process.HasExited) {
            throw ('llama-server завершился до открытия порта {0}.' -f $Port)
        }

        $client = New-Object System.Net.Sockets.TcpClient
        try {
            $task = $client.ConnectAsync($HostName, $Port)
            if ($task.Wait(1000) -and $client.Connected) {
                Add-RestartLog -Path $LogPath -Text ('llama-server открыл порт {0}.' -f $Port)
                return
            }
        }
        catch { Start-Sleep -Seconds 1 }
        finally { $client.Close() }
    }
    throw ('llama-server не открыл порт {0} за {1} секунд.' -f $Port, $TimeoutSeconds)
}

<#
Блок: публикация фактического размера контекста для уже работающего Open WebUI.
llama.cpp может скорректировать запрошенный CtxSize, поэтому используется значение n_ctx из /props.
#>
function Get-LlamaContextSize {
    param(
        [string]$HostName,
        [int]$Port,
        [int]$FallbackContextSize,
        [string]$LogPath
    )

    $queryHost = $HostName
    if ($queryHost -in @('0.0.0.0', '::', '*', '+')) {
        $queryHost = '127.0.0.1'
    }

    $propsUrl = ('http://{0}:{1}/props' -f $queryHost, $Port)
    $deadline = (Get-Date).AddSeconds(15)
    $lastError = $null
    while ((Get-Date) -lt $deadline) {
        try {
            $props = Invoke-RestMethod -Uri $propsUrl -Method Get -TimeoutSec 3
            $actualContextSize = [int]$props.default_generation_settings.n_ctx
            if ($actualContextSize -gt 0) {
                Add-RestartLog -Path $LogPath -Text ('Фактический размер контекста llama-server: {0}.' -f $actualContextSize)
                return $actualContextSize
            }
        }
        catch {
            $lastError = $_.Exception.Message
        }

        Start-Sleep -Seconds 1
    }

    Add-RestartLog -Path $LogPath -Text ('Не удалось прочитать /props ({0}). Для индикатора используется CtxSize={1}.' -f $lastError, $FallbackContextSize)
    return $FallbackContextSize
}

function Write-OpenWebUIRuntimeConfig {
    param(
        [string]$PackagesDir,
        [int]$ContextSize,
        [string]$LogPath
    )

    $payload = [ordered]@{
        contextSize = $ContextSize
        updatedAtUtc = [DateTime]::UtcNow.ToString('o')
    } | ConvertTo-Json -Compress
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $writtenPaths = @()

    foreach ($staticDir in @(
        (Join-Path $PackagesDir 'open_webui\frontend\static'),
        (Join-Path $PackagesDir 'open_webui\static')
    )) {
        if (Test-Path -LiteralPath $staticDir) {
            $runtimeConfigPath = Join-Path $staticDir 'portablellm-runtime.json'
            [System.IO.File]::WriteAllText($runtimeConfigPath, $payload, $utf8NoBom)
            $writtenPaths += $runtimeConfigPath
        }
    }

    if ($writtenPaths.Count -eq 0) {
        Add-RestartLog -Path $LogPath -Text ('Каталоги Open WebUI static не найдены в {0}; индикатор контекста будет недоступен.' -f $PackagesDir)
        return
    }

    Add-RestartLog -Path $LogPath -Text ('Runtime-конфиг Open WebUI обновлён: contextSize={0}.' -f $ContextSize)
}

$restartLog = $null
try {
    $root = Resolve-Root
    $baseConfigPath = Join-Path $root 'config\portablellm.ini'
    $overrideConfigPath = Join-Path $root 'config\restartllm.ini'
    if (-not (Test-Path -LiteralPath $baseConfigPath)) {
        throw ("Не найден базовый конфиг: {0}" -f $baseConfigPath)
    }

    $baseConfig = Read-SimpleConfig -Path $baseConfigPath
    $baseLogsDir = Join-PortablePath -Root $root -Value $baseConfig['LogsDir']
    $baseTempDir = Join-PortablePath -Root $root -Value $baseConfig['TempDir']
    $basePackagesDir = Join-PortablePath -Root $root -Value $baseConfig['OpenWebUIPackages']
    if (-not (Test-Path -LiteralPath $baseLogsDir)) { $null = New-Item -ItemType Directory -Path $baseLogsDir -Force }
    if (-not (Test-Path -LiteralPath $baseTempDir)) { $null = New-Item -ItemType Directory -Path $baseTempDir -Force }

    $restartLog = Join-Path $baseLogsDir 'restart.log'
    if (-not (Test-Path -LiteralPath $restartLog)) {
        Write-Utf8Bom -Path $restartLog -Text ("PortableLLM restart log`r`n")
    }
    Add-Content -LiteralPath $restartLog -Encoding UTF8 -Value ''
    Add-RestartLog -Path $restartLog -Text 'Начат перезапуск llama-server.'

    $effectiveConfigPath = Join-Path $baseTempDir 'portablellm_tmp.ini'
    $overrideConfig = Merge-ConfigFiles -BasePath $baseConfigPath -OverridePath $overrideConfigPath -OutputPath $effectiveConfigPath
    $overrideKeys = @(Get-ConfigKeyOrder -Path $overrideConfigPath)
    Show-ConfigOverrides -BaseConfig $baseConfig -OverrideConfig $overrideConfig -OverrideKeys $overrideKeys -LogPath $restartLog
    Add-RestartLog -Path $restartLog -Text ('Effective config: {0}' -f $effectiveConfigPath)

    $config = Read-SimpleConfig -Path $effectiveConfigPath
    $baseLlamaExe = Join-PortablePath -Root $root -Value $baseConfig['LlamaExe']
    $basePidPath = Join-Path $baseLogsDir 'llama.pid'
    Stop-LlamaServer -LlamaExe $baseLlamaExe -PidPath $basePidPath -LogPath $restartLog

    $restartDelaySeconds = [int](Get-ConfigValue -Config $config -Key 'RestartDelaySeconds' -DefaultValue '5')
    Write-Info ("Ожидание освобождения памяти: {0} сек." -f $restartDelaySeconds)
    Add-RestartLog -Path $restartLog -Text ('Ожидание освобождения памяти: {0} сек.' -f $restartDelaySeconds)
    Start-Sleep -Seconds $restartDelaySeconds

    $llamaExe = Join-PortablePath -Root $root -Value $config['LlamaExe']
    $modelsDir = Join-PortablePath -Root $root -Value $config['ModelsDir']
    $logsDir = Join-PortablePath -Root $root -Value $config['LogsDir']
    if (-not (Test-Path -LiteralPath $logsDir)) { $null = New-Item -ItemType Directory -Path $logsDir -Force }

    $model = Select-Model -ModelsDir $modelsDir
    Add-RestartLog -Path $restartLog -Text ('Выбрана модель: {0}' -f $model)

    $cudaRequired = Get-ConfigValue -Config $config -Key 'CudaRequired' -DefaultValue 'true'
    $gpuLayers = Get-ConfigValue -Config $config -Key 'GpuLayers' -DefaultValue 'all'
    $flashAttention = Get-ConfigValue -Config $config -Key 'FlashAttention' -DefaultValue 'auto'
    $cacheTypeK = Get-ConfigValue -Config $config -Key 'CacheTypeK' -DefaultValue 'f16'
    $cacheTypeV = Get-ConfigValue -Config $config -Key 'CacheTypeV' -DefaultValue 'f16'
    $splitMode = Get-ConfigValue -Config $config -Key 'SplitMode' -DefaultValue 'none'
    $mainGpu = Get-ConfigValue -Config $config -Key 'MainGpu' -DefaultValue '0'
    $modelAlias = Get-ConfigValue -Config $config -Key 'ModelAlias' -DefaultValue 'Current model'
    $ctxSize = Get-ConfigValue -Config $config -Key 'CtxSize' -DefaultValue '16000'
    $batchSize = Get-ConfigValue -Config $config -Key 'BatchSize' -DefaultValue '2048'
    $ubatchSize = Get-ConfigValue -Config $config -Key 'UBatchSize' -DefaultValue '512'
    $fit = Get-ConfigValue -Config $config -Key 'Fit' -DefaultValue 'on'
    $fitTargetMiB = Get-ConfigValue -Config $config -Key 'FitTargetMiB' -DefaultValue '2048'
    $fitCtx = Get-ConfigValue -Config $config -Key 'FitCtx' -DefaultValue '4096'
    $maxTokens = Get-ConfigValue -Config $config -Key 'MaxTokens' -DefaultValue ''
    $parallelSlots = Get-ConfigValue -Config $config -Key 'ParallelSlots' -DefaultValue '1'
    $promptCacheMiB = Get-ConfigValue -Config $config -Key 'PromptCacheMiB' -DefaultValue '0'
    $cacheIdleSlots = Get-ConfigValue -Config $config -Key 'CacheIdleSlots' -DefaultValue 'false'
    $cacheReuse = Get-ConfigValue -Config $config -Key 'CacheReuse' -DefaultValue ''
    $noContextShift = Test-ConfigEnabled -Config $config -Key 'NoContextShift' -DefaultValue 'true'
    $noMmap = Test-ConfigEnabled -Config $config -Key 'NoMmap' -DefaultValue 'false'
    $cpuMoe = Test-ConfigEnabled -Config $config -Key 'CpuMoe' -DefaultValue 'false'
    $nCpuMoe = Get-ConfigValue -Config $config -Key 'NCpuMoe' -DefaultValue ''
    $metrics = Test-ConfigEnabled -Config $config -Key 'Metrics' -DefaultValue 'true'
    $sleepIdleSeconds = Get-ConfigValue -Config $config -Key 'SleepIdleSeconds' -DefaultValue ''
    $jinja = Get-ConfigValue -Config $config -Key 'Jinja' -DefaultValue 'true'
    $reasoningFormat = Get-ConfigValue -Config $config -Key 'ReasoningFormat' -DefaultValue 'deepseek'
    $modelsPreset = Get-ConfigValue -Config $config -Key 'ModelsPreset' -DefaultValue ''
    $vramReserveGb = [double](Get-ConfigValue -Config $config -Key 'VramReserveGb' -DefaultValue '2.0')
    $llamaHost = $config['LlamaHost']
    $llamaPort = Get-FreePort -PreferredPort ([int]$config['LlamaPort'])

    Add-RestartLog -Path $restartLog -Text ('Model alias={0}; Context={1}; KV K={2}; KV V={3}; batch={4}; ubatch={5}; GPU layers={6}' -f $modelAlias, $ctxSize, $cacheTypeK, $cacheTypeV, $batchSize, $ubatchSize, $gpuLayers)

    if ($cudaRequired -match '^(1|true|yes|y|да|д)$') {
        Write-Info 'Проверка CUDA backend llama.cpp...'
        Assert-CudaBackend -LlamaExe $llamaExe -LogPath $restartLog
        Write-Ok 'CUDA backend доступен.'
    }

    $detailedVramEstimate = Test-LlamaDetailedVramFit -LlamaExe $llamaExe -ModelPath $model -GpuLayers $gpuLayers -FlashAttention $flashAttention -CacheTypeK $cacheTypeK -CacheTypeV $cacheTypeV -SplitMode $splitMode -MainGpu $mainGpu -CtxSize $ctxSize -BatchSize $batchSize -UBatchSize $ubatchSize -Fit $fit -FitTargetMiB $fitTargetMiB -FitCtx $fitCtx -ParallelSlots $parallelSlots -NoMmap $noMmap -CpuMoe $cpuMoe -NCpuMoe $nCpuMoe -LogPath $restartLog
    if (-not $detailedVramEstimate) {
        Test-ModelVramFit -ModelPath $model -ReserveGb $vramReserveGb -LogPath $restartLog
    }

    $llamaArgsList = @(
        '--model', $model,
        '--host', $llamaHost,
        '--port', [string]$llamaPort,
        '--gpu-layers', $gpuLayers,
        '--flash-attn', $flashAttention,
        '--cache-type-k', $cacheTypeK,
        '--cache-type-v', $cacheTypeV,
        '--split-mode', $splitMode,
        '--main-gpu', $mainGpu,
        '--ctx-size', $ctxSize,
        '--batch-size', $batchSize,
        '--ubatch-size', $ubatchSize,
        '--fit', $fit,
        '--fit-target', $fitTargetMiB,
        '--fit-ctx', $fitCtx,
        '--parallel', $parallelSlots,
        '--cache-ram', $promptCacheMiB
    )

    if (-not [string]::IsNullOrWhiteSpace($modelAlias)) { $llamaArgsList += @('--alias', $modelAlias) }

    if (-not [string]::IsNullOrWhiteSpace($cacheReuse)) { $llamaArgsList += @('--cache-reuse', $cacheReuse) }
    if ($noContextShift) { $llamaArgsList += '--no-context-shift' }
    if ($noMmap) { $llamaArgsList += '--no-mmap' }
    if ($cpuMoe) { $llamaArgsList += '--cpu-moe' }
    if (-not [string]::IsNullOrWhiteSpace($nCpuMoe)) { $llamaArgsList += @('--n-cpu-moe', $nCpuMoe) }
    if ($metrics) { $llamaArgsList += '--metrics' }
    if (-not [string]::IsNullOrWhiteSpace($sleepIdleSeconds)) { $llamaArgsList += @('--sleep-idle-seconds', $sleepIdleSeconds) }
    if ($jinja -match '^(1|true|yes|y|да|д|on)$') { $llamaArgsList += '--jinja' }
    elseif ($jinja -match '^(0|false|no|n|нет|н|off)$') { $llamaArgsList += '--no-jinja' }
    if (-not [string]::IsNullOrWhiteSpace($reasoningFormat)) { $llamaArgsList += @('--reasoning-format', $reasoningFormat) }
    if (-not [string]::IsNullOrWhiteSpace($modelsPreset)) {
        $llamaArgsList += @('--models-preset', (Join-PortablePath -Root $root -Value $modelsPreset))
    }
    if (-not [string]::IsNullOrWhiteSpace($maxTokens)) { $llamaArgsList += @('--predict', $maxTokens) }
    if ($cacheIdleSlots -notmatch '^(1|true|yes|y|да|д)$') { $llamaArgsList += '--no-cache-idle-slots' }

    $llamaArgs = Convert-ToArgumentLine -CommandArguments $llamaArgsList
    Add-RestartLog -Path $restartLog -Text ('llama-server args: {0}' -f $llamaArgs)

    $llamaLog = Join-Path $logsDir 'llama.log'
    $llamaErr = Join-Path $logsDir 'llama.err.log'
    Remove-Item -LiteralPath $llamaLog, $llamaErr -ErrorAction SilentlyContinue
    Write-Info 'Запуск llama-server...'
    $llama = Start-Process -FilePath $llamaExe -ArgumentList $llamaArgs -WorkingDirectory $root -WindowStyle Hidden -RedirectStandardOutput $llamaLog -RedirectStandardError $llamaErr -PassThru
    [System.IO.File]::WriteAllText((Join-Path $logsDir 'llama.pid'), [string]$llama.Id, (New-Object System.Text.UTF8Encoding($true)))
    Add-RestartLog -Path $restartLog -Text ('Новый llama-server PID: {0}' -f $llama.Id)
    Write-Ok ("llama-server PID: {0}" -f $llama.Id)

    Write-Info 'Ожидание готовности llama-server...'
    Wait-ServicePort -Process $llama -HostName $llamaHost -Port $llamaPort -TimeoutSeconds 120 -LogPath $restartLog
    $actualCtxSize = Get-LlamaContextSize -HostName $llamaHost -Port $llamaPort -FallbackContextSize ([int]$ctxSize) -LogPath $restartLog
    Write-OpenWebUIRuntimeConfig -PackagesDir $basePackagesDir -ContextSize $actualCtxSize -LogPath $restartLog
    Write-Ok 'llama-server готов. Open WebUI не перезапускался.'
    Add-RestartLog -Path $restartLog -Text 'Перезапуск успешно завершён.'
}
catch {
    Write-Host ''
    Write-Host '[ERROR] Перезапуск llama-server остановлен из-за ошибки.' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    if ($restartLog) {
        Add-RestartLog -Path $restartLog -Text ('ОШИБКА: {0}' -f $_.Exception.ToString())
        Write-Host ('Подробности: {0}' -f $restartLog) -ForegroundColor Yellow
    }
    Read-Host 'Нажмите Enter, чтобы закрыть окно'
    exit 1
}
