<#
Блок: параметры запуска.
Если TargetPath не указан, скрипт пытается найти portable-папку рядом с собой или спрашивает путь.
#>
[CmdletBinding()]
param(
    [string]$TargetPath
)

<#
Блок: базовые настройки.
Скрипт останавливается на ошибках, чтобы не оставлять половину сервисов в неизвестном состоянии.
#>
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

<#
Блок: сообщения и пути.
Эти функции держат запуск коротким и понятным.
#>
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

function Add-StartupLog {
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

<#
Блок: подключение локальных Python-пакетов.
Embedded Python читает пути из python*._pth и игнорирует PYTHONPATH, поэтому packages добавляется туда.
#>
function Ensure-PythonPackagesPath {
    param([string]$PythonExe)

    $pythonDir = Split-Path -Parent $PythonExe
    $pthFile = Get-ChildItem -LiteralPath $pythonDir -Filter 'python*._pth' -File | Select-Object -First 1
    if (-not $pthFile) {
        throw 'Не найден файл python*._pth в embedded Python.'
    }

    $pathEntries = @(
        '..\OpenWebUI\packages',
        '..\OpenWebUI\packages\win32',
        '..\OpenWebUI\packages\win32\lib',
        '..\OpenWebUI\packages\pywin32_system32'
    )
    $lines = @(Get-Content -LiteralPath $pthFile.FullName)
    $existing = @{}
    foreach ($line in $lines) {
        $existing[$line.Trim().ToLowerInvariant()] = $true
    }

    $missing = @()
    foreach ($entry in $pathEntries) {
        if (-not $existing.ContainsKey($entry.ToLowerInvariant())) {
            $missing += $entry
        }
    }

    if (-not $missing) {
        return
    }

    $updated = @()
    $inserted = $false
    foreach ($line in $lines) {
        if (-not $inserted -and $line.Trim() -eq 'import site') {
            $updated += $missing
            $inserted = $true
        }

        $updated += $line
    }

    if (-not $inserted) {
        $updated += $missing
    }

    [System.IO.File]::WriteAllText($pthFile.FullName, (($updated -join "`r`n") + "`r`n"), (New-Object System.Text.ASCIIEncoding))
}

<#
Блок: чтение простого ini.
Конфиг использует формат key=value без секций.
#>
function Read-SimpleConfig {
    param([string]$Path)

    $config = @{}
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

<#
Блок: выбор модели.
Если в models несколько GGUF, пользователь выбирает нужную модель.
#>
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

<#
Блок: проверка порта.
Скрипт не делает сложный автоподбор, а честно сообщает, если стандартные порты заняты.
#>
function Test-PortFree {
    param([int]$Port)

    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
    try {
        $listener.Start()
        return $true
    }
    catch {
        return $false
    }
    finally {
        if ($listener) {
            $listener.Stop()
        }
    }
}

function Get-FreePort {
    param([int]$PreferredPort)

    $port = $PreferredPort
    while ($port -lt 65535) {
        if (Test-PortFree -Port $port) {
            return $port
        }

        $port++
    }

    throw ('Не удалось найти свободный порт начиная с {0}.' -f $PreferredPort)
}

<#
Блок: ожидание готовности сервиса.
Процесс может стартовать быстро, а порт открыться позже, поэтому браузер открывается только после готовности.
#>
function Wait-ServicePort {
    param(
        [System.Diagnostics.Process]$Process,
        [string]$Name,
        [string]$HostName,
        [int]$Port,
        [int]$TimeoutSeconds,
        [string]$LogPath
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $Process.Refresh()
        if ($Process.HasExited) {
            throw ('{0} завершился до открытия порта {1}.' -f $Name, $Port)
        }

        $client = New-Object System.Net.Sockets.TcpClient
        try {
            $task = $client.ConnectAsync($HostName, $Port)
            if ($task.Wait(1000) -and $client.Connected) {
                Add-StartupLog -Path $LogPath -Text ('{0} открыл порт {1}.' -f $Name, $Port)
                return
            }
        }
        catch {
            Start-Sleep -Seconds 1
        }
        finally {
            $client.Close()
        }
    }

    throw ('{0} не открыл порт {1} за {2} секунд.' -f $Name, $Port, $TimeoutSeconds)
}

<#
Блок: публикация фактического размера контекста для Open WebUI.
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
                Add-StartupLog -Path $LogPath -Text ('Фактический размер контекста llama-server: {0}.' -f $actualContextSize)
                return $actualContextSize
            }
        }
        catch {
            $lastError = $_.Exception.Message
        }

        Start-Sleep -Seconds 1
    }

    Add-StartupLog -Path $LogPath -Text ('Не удалось прочитать /props ({0}). Для индикатора используется CtxSize={1}.' -f $lastError, $FallbackContextSize)
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
        Add-StartupLog -Path $LogPath -Text ('Каталоги Open WebUI static не найдены в {0}; индикатор контекста будет недоступен.' -f $PackagesDir)
        return
    }

    Add-StartupLog -Path $LogPath -Text ('Runtime-конфиг Open WebUI обновлён: contextSize={0}.' -f $ContextSize)
}

<#
Блок: защита от повторного запуска.
Portable-сборка должна иметь одну активную пару llama-server/Open WebUI, иначе порты и GPU-память расходятся.
#>
function Assert-ProcessNotRunning {
    param(
        [string]$ExePath,
        [string]$DisplayName
    )

    $processName = [System.IO.Path]::GetFileNameWithoutExtension($ExePath)
    $fullPath = [System.IO.Path]::GetFullPath($ExePath)
    $running = @()
    foreach ($process in @(Get-Process -Name $processName -ErrorAction SilentlyContinue)) {
        try {
            if ($process.Path -and ([System.IO.Path]::GetFullPath($process.Path) -ieq $fullPath)) {
                $running += $process
            }
        }
        catch {
        }
    }

    if ($running) {
        $ids = (($running | Select-Object -ExpandProperty Id) -join ', ')
        throw ("{0} уже запущен из этой portable-папки. PID: {1}. Сначала выполните Stop-PortableLLM.ps1." -f $DisplayName, $ids)
    }
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
        try {
            $process.Kill()
        }
        catch {
        }

        throw ("Команда не завершилась за {0} секунд: {1}" -f $TimeoutSeconds, $Exe)
    }

    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()

    return [PSCustomObject]@{
        ExitCode = $process.ExitCode
        Output = (($stdout, $stderr) -join "`r`n").Trim()
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
        if ([string]::IsNullOrWhiteSpace($dir)) {
            continue
        }

        try {
            $cleanDir = $dir.Trim().Trim('"')
            $candidate = [System.IO.Path]::Combine($cleanDir, $DllName)
            if (Test-Path -LiteralPath $candidate) {
                return $candidate
            }
        }
        catch {
            continue
        }
    }

    return $null
}

<#
Блок: проверка CUDA backend.
Для проекта CUDA обязательна: если llama.cpp не видит CUDA-устройство, запуск останавливается с понятной ошибкой.
#>
function Assert-CudaBackend {
    param(
        [string]$LlamaExe,
        [string]$LogPath
    )

    $llamaBinDir = Split-Path -Parent $LlamaExe
    $requiredDlls = @('ggml-cuda.dll', 'cublas64_12.dll', 'cudart64_12.dll', 'nvcuda.dll')
    $missing = @()
    foreach ($dll in $requiredDlls) {
        $path = Find-DllPath -DllName $dll -PreferredDir $llamaBinDir
        if ($path) {
            Add-StartupLog -Path $LogPath -Text ('CUDA DLL найдена: {0}' -f $path)
        }
        else {
            $missing += $dll
        }
    }

    if ($missing) {
        throw ("CUDA backend llama.cpp не готов. Не найдены DLL: {0}. Поместите CUDA 12 runtime DLL рядом с llama-server.exe или добавьте их папку в PATH." -f ($missing -join ', '))
    }

    $probe = Invoke-CapturedProcess -Exe $LlamaExe -CommandArguments @('--list-devices') -WorkingDir $llamaBinDir -TimeoutSeconds 30
    [System.IO.File]::WriteAllText((Join-Path (Split-Path -Parent $LogPath) 'cuda-check.log'), ($probe.Output + "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
    Add-StartupLog -Path $LogPath -Text 'Проверка CUDA устройств записана в cuda-check.log.'

    if ($probe.Output -notmatch '(?i)(CUDA|NVIDIA|GeForce|RTX)') {
        throw 'llama.cpp не увидел CUDA-устройство. Подробности см. в logs\cuda-check.log.'
    }
}

function Get-FreeVramBytes {
    param([string]$LogPath)

    $nvidiaSmi = Get-Command 'nvidia-smi.exe' -ErrorAction SilentlyContinue
    if (-not $nvidiaSmi) {
        Add-StartupLog -Path $LogPath -Text 'nvidia-smi.exe не найден, предварительная оценка VRAM пропущена.'
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
        Add-StartupLog -Path $LogPath -Text ('Не удалось получить свободную VRAM через nvidia-smi: {0}' -f $_.Exception.Message)
    }

    return $null
}

<#
Блок: предварительная оценка VRAM.
Это не точный расчет llama.cpp, а раннее предупреждение: размер GGUF плюс запас на KV/cache/compute/runtime.
#>
function Test-ModelVramFit {
    param(
        [string]$ModelPath,
        [double]$ReserveGb,
        [string]$LogPath
    )

    $modelFile = Get-Item -LiteralPath $ModelPath
    $freeVramBytes = Get-FreeVramBytes -LogPath $LogPath
    if (-not $freeVramBytes) {
        return
    }

    $requiredBytes = [int64]($modelFile.Length + ($ReserveGb * 1GB))
    $modelGb = [math]::Round($modelFile.Length / 1GB, 2)
    $freeGb = [math]::Round($freeVramBytes / 1GB, 2)
    $requiredGb = [math]::Round($requiredBytes / 1GB, 2)

    Add-StartupLog -Path $LogPath -Text ('VRAM estimate: model={0} GB, reserve={1} GB, required={2} GB, free={3} GB' -f $modelGb, $ReserveGb, $requiredGb, $freeGb)

    Write-Info ('Оценка VRAM: модель {0} GB + резерв {1} GB = {2} GB; свободно {3} GB.' -f $modelGb, $ReserveGb, $requiredGb, $freeGb)
    if ($requiredBytes -gt $freeVramBytes) {
        Write-Host ('[WARN] Модель может не поместиться в VRAM при GpuLayers=all. Если запуск упадёт с CUDA out of memory, выберите меньшую модель или уменьшите GpuLayers в config\portablellm.ini.' ) -ForegroundColor Yellow
        Add-StartupLog -Path $LogPath -Text 'WARN: модель может не поместиться в VRAM при GpuLayers=all.'
    }
}

<#
Блок: детальная оценка VRAM штатным llama-fit-params.
Инструмент читает метаданные модели и рассчитывает отдельно model/context/compute buffers
для тех же параметров, с которыми будет запущен сервер. Оценка является диагностической
и не запрещает запуск.
#>
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
        Add-StartupLog -Path $LogPath -Text 'llama-fit-params.exe не найден; используется грубая оценка VRAM.'
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
        Add-StartupLog -Path $LogPath -Text ('llama-fit-params exit code: {0}' -f $probe.ExitCode)
        foreach ($line in ($probe.Output -split "`r?`n")) {
            if ($line -match '^(CUDA\d+|Host)\s+\d+\s+\d+\s+\d+') {
                Add-StartupLog -Path $LogPath -Text ('Memory estimate raw: {0}' -f $line.Trim())
            }
        }

        $matches = [regex]::Matches($probe.Output, '(?m)^CUDA\d+\s+(\d+)\s+(\d+)\s+(\d+)\s*$')
        if ($matches.Count -eq 0) {
            Add-StartupLog -Path $LogPath -Text 'llama-fit-params не вернул распознаваемую CUDA-оценку; используется грубая оценка.'
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
        Add-StartupLog -Path $LogPath -Text $summary
        if ($status -ne 'safe') {
            Write-Host ('[WARN] {0}' -f $status) -ForegroundColor Yellow
            $advice = 'Для увеличения запаса можно изменить CtxSize, CacheTypeK/CacheTypeV, BatchSize/UBatchSize или GpuLayers.'
            Write-Host ('[WARN] {0}' -f $advice) -ForegroundColor Yellow
            Add-StartupLog -Path $LogPath -Text $advice
        }
        return $true
    }
    catch {
        Add-StartupLog -Path $LogPath -Text ('Детальная оценка VRAM не выполнена: {0}' -f $_.Exception.Message)
        return $false
    }
}

function Quote-Arg {
    param([string]$Value)

    if ($Value -match '[\s"]') {
        return ('"{0}"' -f $Value.Replace('"', '\"'))
    }

    return $Value
}

<#
Блок: запуск Open WebUI.
Для Open WebUI нужны локальный PYTHONPATH и DATA_DIR, поэтому используется ProcessStartInfo.
#>
function Start-WebUI {
    param(
        [string]$PythonExe,
        [string]$PackagesDir,
        [string]$DataDir,
        [string]$TempDir,
        [string]$ListenHost,
        [int]$Port,
        [string]$LlamaUrl,
        [string]$WorkingDir,
        [string]$DisableBackgroundTasks,
        [string]$OutputLog,
        [string]$ErrorLog
    )

    $oldPythonPath = $env:PYTHONPATH
    $oldDataDir = $env:DATA_DIR
    $oldTemp = $env:TEMP
    $oldTmp = $env:TMP
    $oldOpenAiBaseUrls = $env:OPENAI_API_BASE_URLS
    $oldOpenAiKeys = $env:OPENAI_API_KEYS
    $oldPythonUtf8 = $env:PYTHONUTF8
    $oldPythonIoEncoding = $env:PYTHONIOENCODING
    $backgroundTaskVars = @(
        'ENABLE_TITLE_GENERATION',
        'ENABLE_TAGS_GENERATION',
        'ENABLE_FOLLOW_UP_GENERATION',
        'ENABLE_SEARCH_QUERY_GENERATION',
        'ENABLE_RETRIEVAL_QUERY_GENERATION',
        'ENABLE_IMAGE_PROMPT_GENERATION',
        'ENABLE_AUTOCOMPLETE_GENERATION'
    )
    $oldBackgroundTaskVars = @{}
    foreach ($name in $backgroundTaskVars) {
        $oldBackgroundTaskVars[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    }

    try {
        $env:PYTHONPATH = $PackagesDir
        $env:DATA_DIR = $DataDir
        $env:TEMP = $TempDir
        $env:TMP = $TempDir
        $env:OPENAI_API_BASE_URLS = $LlamaUrl
        $env:OPENAI_API_KEYS = 'none'
        $env:PYTHONUTF8 = '1'
        $env:PYTHONIOENCODING = 'utf-8'

        if ($DisableBackgroundTasks -match '^(1|true|yes|y|да|д)$') {
            foreach ($name in $backgroundTaskVars) {
                [Environment]::SetEnvironmentVariable($name, 'false', 'Process')
            }
        }

        # pip console launchers contain the Python path used during installation.
        # Invoke the Typer app through the current portable Python so drive-letter changes keep working.
        $arguments = Convert-ToArgumentLine -CommandArguments @(
            '-c',
            'from open_webui import app; app()',
            'serve',
            '--host',
            $ListenHost,
            '--port',
            [string]$Port
        )
        return Start-Process -FilePath $PythonExe -ArgumentList $arguments -WorkingDirectory $WorkingDir -WindowStyle Hidden -RedirectStandardOutput $OutputLog -RedirectStandardError $ErrorLog -PassThru
    }
    finally {
        $env:PYTHONPATH = $oldPythonPath
        $env:DATA_DIR = $oldDataDir
        $env:TEMP = $oldTemp
        $env:TMP = $oldTmp
        $env:OPENAI_API_BASE_URLS = $oldOpenAiBaseUrls
        $env:OPENAI_API_KEYS = $oldOpenAiKeys
        $env:PYTHONUTF8 = $oldPythonUtf8
        $env:PYTHONIOENCODING = $oldPythonIoEncoding
        foreach ($name in $backgroundTaskVars) {
            [Environment]::SetEnvironmentVariable($name, $oldBackgroundTaskVars[$name], 'Process')
        }
    }
}

<#
Блок: основной запуск.
Сначала стартует llama-server, затем Open WebUI.
#>
try {
    $root = Resolve-Root
    $configPath = Join-Path $root 'config\portablellm.ini'
    if (-not (Test-Path -LiteralPath $configPath)) {
        throw ("Не найден конфиг: {0}" -f $configPath)
    }

    $config = Read-SimpleConfig -Path $configPath
    $pythonExe = Join-PortablePath -Root $root -Value $config['PythonExe']
    $packagesDir = Join-PortablePath -Root $root -Value $config['OpenWebUIPackages']
    $dataDir = Join-PortablePath -Root $root -Value $config['OpenWebUIData']
    $llamaExe = Join-PortablePath -Root $root -Value $config['LlamaExe']
    $modelsDir = Join-PortablePath -Root $root -Value $config['ModelsDir']
    $logsDir = Join-PortablePath -Root $root -Value $config['LogsDir']
    $tempDir = Join-PortablePath -Root $root -Value $config['TempDir']
    $startupLog = Join-Path $logsDir 'startup.log'
    Write-Utf8Bom -Path $startupLog -Text ("PortableLLM startup log`r`n")
    Ensure-PythonPackagesPath -PythonExe $pythonExe
    Add-StartupLog -Path $startupLog -Text 'Пути Open WebUI и pywin32 подключены в embedded Python.'
    Assert-ProcessNotRunning -ExePath $llamaExe -DisplayName 'llama-server'

    $llamaHost = $config['LlamaHost']
    $webHost = $config['WebUIHost']
    $llamaPort = Get-FreePort -PreferredPort ([int]$config['LlamaPort'])
    $webPort = Get-FreePort -PreferredPort ([int]$config['WebUIPort'])
    if ($webPort -eq $llamaPort) {
        $webPort = Get-FreePort -PreferredPort ($webPort + 1)
    }
    $cudaRequired = Get-ConfigValue -Config $config -Key 'CudaRequired' -DefaultValue 'true'
    $gpuLayers = Get-ConfigValue -Config $config -Key 'GpuLayers' -DefaultValue 'all'
    $flashAttention = Get-ConfigValue -Config $config -Key 'FlashAttention' -DefaultValue 'auto'
    $cacheTypeK = Get-ConfigValue -Config $config -Key 'CacheTypeK' -DefaultValue 'f16'
    $cacheTypeV = Get-ConfigValue -Config $config -Key 'CacheTypeV' -DefaultValue 'f16'
    $splitMode = Get-ConfigValue -Config $config -Key 'SplitMode' -DefaultValue 'none'
    $mainGpu = Get-ConfigValue -Config $config -Key 'MainGpu' -DefaultValue '0'
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
    $disableOpenWebUIBackgroundTasks = Get-ConfigValue -Config $config -Key 'DisableOpenWebUIBackgroundTasks' -DefaultValue 'true'
    $vramReserveGb = [double](Get-ConfigValue -Config $config -Key 'VramReserveGb' -DefaultValue '2.0')

    Add-StartupLog -Path $startupLog -Text ('TargetPath: {0}' -f $root)
    Add-StartupLog -Path $startupLog -Text ('llama port: {0}' -f $llamaPort)
    Add-StartupLog -Path $startupLog -Text ('Open WebUI port: {0}' -f $webPort)
    Add-StartupLog -Path $startupLog -Text ('CUDA required: {0}' -f $cudaRequired)
    Add-StartupLog -Path $startupLog -Text ('GPU layers: {0}' -f $gpuLayers)
    Add-StartupLog -Path $startupLog -Text ('Context size: {0}' -f $ctxSize)
    Add-StartupLog -Path $startupLog -Text ('KV cache types: K={0}; V={1}' -f $cacheTypeK, $cacheTypeV)
    Add-StartupLog -Path $startupLog -Text ('Batch size: {0}; ubatch size: {1}' -f $batchSize, $ubatchSize)
    Add-StartupLog -Path $startupLog -Text ('Fit: {0}; fit target MiB: {1}; fit ctx: {2}' -f $fit, $fitTargetMiB, $fitCtx)
    if ([string]::IsNullOrWhiteSpace($maxTokens)) {
        Add-StartupLog -Path $startupLog -Text 'Max tokens: не ограничено скриптом.'
    }
    else {
        Add-StartupLog -Path $startupLog -Text ('Max tokens: {0}' -f $maxTokens)
    }
    Add-StartupLog -Path $startupLog -Text ('Parallel slots: {0}' -f $parallelSlots)
    Add-StartupLog -Path $startupLog -Text ('No context shift: {0}; no mmap: {1}' -f $noContextShift, $noMmap)
    Add-StartupLog -Path $startupLog -Text ('CPU MoE: {0}; N CPU MoE: {1}' -f $cpuMoe, $nCpuMoe)
    Add-StartupLog -Path $startupLog -Text ('Metrics: {0}; sleep idle seconds: {1}' -f $metrics, $sleepIdleSeconds)
    Add-StartupLog -Path $startupLog -Text ('Jinja: {0}; reasoning format: {1}; models preset: {2}' -f $jinja, $reasoningFormat, $modelsPreset)
    Add-StartupLog -Path $startupLog -Text ('Disable Open WebUI background tasks: {0}' -f $disableOpenWebUIBackgroundTasks)
    Add-StartupLog -Path $startupLog -Text ('VRAM reserve GB: {0}' -f $vramReserveGb)

    if ($cudaRequired -match '^(1|true|yes|y|да|д)$') {
        Write-Info 'Проверка CUDA backend llama.cpp...'
        Assert-CudaBackend -LlamaExe $llamaExe -LogPath $startupLog
        Write-Ok 'CUDA backend доступен.'
    }

    $model = Select-Model -ModelsDir $modelsDir
    $detailedVramEstimate = Test-LlamaDetailedVramFit -LlamaExe $llamaExe -ModelPath $model -GpuLayers $gpuLayers -FlashAttention $flashAttention -CacheTypeK $cacheTypeK -CacheTypeV $cacheTypeV -SplitMode $splitMode -MainGpu $mainGpu -CtxSize $ctxSize -BatchSize $batchSize -UBatchSize $ubatchSize -Fit $fit -FitTargetMiB $fitTargetMiB -FitCtx $fitCtx -ParallelSlots $parallelSlots -NoMmap $noMmap -CpuMoe $cpuMoe -NCpuMoe $nCpuMoe -LogPath $startupLog
    if (-not $detailedVramEstimate) {
        Test-ModelVramFit -ModelPath $model -ReserveGb $vramReserveGb -LogPath $startupLog
    }
    $llamaLog = Join-Path $logsDir 'llama.log'
    $llamaErr = Join-Path $logsDir 'llama.err.log'
    Remove-Item -LiteralPath $llamaLog, $llamaErr -ErrorAction SilentlyContinue

    Write-Info 'Запуск llama-server...'
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

    <#
    Блок: дополнительные параметры llama.cpp.
    Эти ключи раскрывают оптимизации из llama.cpp, но остаются управляемыми через portablellm.ini.
    #>
    if (-not [string]::IsNullOrWhiteSpace($cacheReuse)) {
        $llamaArgsList += @('--cache-reuse', $cacheReuse)
    }
    if ($noContextShift) {
        $llamaArgsList += '--no-context-shift'
    }
    if ($noMmap) {
        $llamaArgsList += '--no-mmap'
    }
    if ($cpuMoe) {
        $llamaArgsList += '--cpu-moe'
    }
    if (-not [string]::IsNullOrWhiteSpace($nCpuMoe)) {
        $llamaArgsList += @('--n-cpu-moe', $nCpuMoe)
    }
    if ($metrics) {
        $llamaArgsList += '--metrics'
    }
    if (-not [string]::IsNullOrWhiteSpace($sleepIdleSeconds)) {
        $llamaArgsList += @('--sleep-idle-seconds', $sleepIdleSeconds)
    }
    if ($jinja -match '^(1|true|yes|y|да|д|on)$') {
        $llamaArgsList += '--jinja'
    }
    elseif ($jinja -match '^(0|false|no|n|нет|н|off)$') {
        $llamaArgsList += '--no-jinja'
    }
    if (-not [string]::IsNullOrWhiteSpace($reasoningFormat)) {
        $llamaArgsList += @('--reasoning-format', $reasoningFormat)
    }
    if (-not [string]::IsNullOrWhiteSpace($modelsPreset)) {
        $modelsPresetPath = Join-PortablePath -Root $root -Value $modelsPreset
        $llamaArgsList += @('--models-preset', $modelsPresetPath)
    }

    if (-not [string]::IsNullOrWhiteSpace($maxTokens)) {
        $llamaArgsList += @('--predict', $maxTokens)
    }

    if ($cacheIdleSlots -notmatch '^(1|true|yes|y|да|д)$') {
        $llamaArgsList += '--no-cache-idle-slots'
    }

    $llamaArgs = Convert-ToArgumentLine -CommandArguments $llamaArgsList
    Add-StartupLog -Path $startupLog -Text ('llama-server args: {0}' -f $llamaArgs)
    $llama = Start-Process -FilePath $llamaExe -ArgumentList $llamaArgs -WorkingDirectory $root -WindowStyle Hidden -RedirectStandardOutput $llamaLog -RedirectStandardError $llamaErr -PassThru
    [System.IO.File]::WriteAllText((Join-Path $logsDir 'llama.pid'), [string]$llama.Id, (New-Object System.Text.UTF8Encoding($true)))
    Write-Ok ("llama-server PID: {0}" -f $llama.Id)
    Add-StartupLog -Path $startupLog -Text ('llama-server PID: {0}' -f $llama.Id)
    Write-Info 'Ожидание готовности llama-server...'
    Wait-ServicePort -Process $llama -Name 'llama-server' -HostName $llamaHost -Port $llamaPort -TimeoutSeconds 120 -LogPath $startupLog
    $actualCtxSize = Get-LlamaContextSize -HostName $llamaHost -Port $llamaPort -FallbackContextSize ([int]$ctxSize) -LogPath $startupLog
    Write-OpenWebUIRuntimeConfig -PackagesDir $packagesDir -ContextSize $actualCtxSize -LogPath $startupLog
    Write-Ok 'llama-server готов.'

    Write-Info 'Запуск Open WebUI...'
    $llamaUrl = ('http://{0}:{1}/v1' -f $llamaHost, $llamaPort)
    if (-not (Test-Path -LiteralPath $pythonExe)) {
        throw ("Не найден portable Python: {0}" -f $pythonExe)
    }

    $webLog = Join-Path $logsDir 'webui.log'
    $webErr = Join-Path $logsDir 'webui.err.log'
    Remove-Item -LiteralPath $webLog, $webErr -ErrorAction SilentlyContinue
    $web = Start-WebUI -PythonExe $pythonExe -PackagesDir $packagesDir -DataDir $dataDir -TempDir $tempDir -ListenHost $webHost -Port $webPort -LlamaUrl $llamaUrl -WorkingDir $root -DisableBackgroundTasks $disableOpenWebUIBackgroundTasks -OutputLog $webLog -ErrorLog $webErr
    [System.IO.File]::WriteAllText((Join-Path $logsDir 'webui.pid'), [string]$web.Id, (New-Object System.Text.UTF8Encoding($true)))
    Write-Ok ("Open WebUI PID: {0}" -f $web.Id)
    Add-StartupLog -Path $startupLog -Text ('Open WebUI PID: {0}' -f $web.Id)
    Write-Info 'Ожидание готовности Open WebUI. Первый запуск может занять 1-2 минуты...'
    Wait-ServicePort -Process $web -Name 'Open WebUI' -HostName $webHost -Port $webPort -TimeoutSeconds 240 -LogPath $startupLog
    Write-Ok 'Open WebUI готов.'

    $url = ('http://{0}:{1}' -f $webHost, $webPort)
    [System.IO.File]::WriteAllText((Join-Path $logsDir 'last-url.txt'), $url, (New-Object System.Text.UTF8Encoding($true)))
    Add-StartupLog -Path $startupLog -Text ('URL: {0}' -f $url)
    Write-Host ''
    Write-Host ('Откройте в браузере: {0}' -f $url)
    Write-Host 'Если браузер открыл страницу 127.0.0.1 без порта, вставьте адрес выше целиком.'
    Start-Process -FilePath $url | Out-Null
}
catch {
    Write-Host ''
    Write-Host '[ERROR] Запуск остановлен из-за ошибки.' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red

    if ($startupLog) {
        Add-StartupLog -Path $startupLog -Text ('ОШИБКА: {0}' -f $_.Exception.ToString())
        Write-Host ('Подробности: {0}' -f $startupLog) -ForegroundColor Yellow
    }

    Read-Host 'Нажмите Enter, чтобы закрыть окно'
    exit 1
}
