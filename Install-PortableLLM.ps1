<#
Блок: параметры установки.
Скрипт принимает полный путь установки или одну букву диска. Если путь не указан, скрипт спросит его интерактивно.
#>
[CmdletBinding()]
param(
    [string]$TargetPath,
    [string]$OpenWebUIPackage = 'open-webui'
)

<#
Блок: базовые настройки.
Строгий режим помогает быстро ловить ошибки в переменных и путях.
#>
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

<#
Блок: константы.
Здесь собраны внешние ссылки и имена служебных файлов.
#>
$ScriptRoot = Split-Path -Parent $PSCommandPath
$PythonUrl = 'https://www.python.org/ftp/python/3.12.3/python-3.12.3-embed-amd64.zip'
$GetPipUrl = 'https://bootstrap.pypa.io/get-pip.py'
$PythonZipName = 'python-3.12.3-embed-amd64.zip'
$ConfigFileName = 'portablellm.ini'
$VersionsFileName = 'installed-versions.txt'

<#
Блок: простые сообщения.
Эти функции оставляют консоль читаемой и не превращают установку в поток технического шума.
#>
function Write-Info {
    param([string]$Text)
    Write-Host "[INFO] $Text" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Text)
    Write-Host "[OK] $Text" -ForegroundColor Green
}

function Write-Bad {
    param([string]$Text)
    Write-Host "[ERROR] $Text" -ForegroundColor Red
}

<#
Блок: ранняя аварийная диагностика.
Если ошибка случилась до создания целевой папки и install.log, окно не закрывается молча.
#>
function Stop-WithEarlyError {
    param([System.Management.Automation.ErrorRecord]$ErrorRecord)

    $errorLog = Join-Path $ScriptRoot 'install-error.log'
    $message = $ErrorRecord.Exception.Message
    $details = @"
PortableLLM early install error
Дата: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Ошибка: $message

$($ErrorRecord.Exception.ToString())
"@

    try {
        [System.IO.File]::WriteAllText($errorLog, ($details.Trim() + "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
    }
    catch {
        $errorLog = $null
    }

    Write-Host ''
    Write-Bad 'Установка остановлена до создания рабочих папок.'
    Write-Host $message -ForegroundColor Red
    if ($errorLog) {
        Write-Host ('Ранний лог ошибки: {0}' -f $errorLog) -ForegroundColor Yellow
    }

    Read-Host 'Нажмите Enter, чтобы закрыть окно'
    exit 1
}

trap {
    Stop-WithEarlyError -ErrorRecord $_
}

<#
Блок: нормализация пути установки.
Если пользователь вводит H или H:, это считается запросом на H:\LLM.
#>
function Convert-ToTargetPath {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        $Value = Read-Host 'Введите папку установки, например H:\LLM, или только букву диска H'
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

<#
Блок: проверка свободного места.
Без моделей установка занимает несколько гигабайт, поэтому до начала работ проверяется минимум 5 GB.
#>
function Test-FreeSpace {
    param(
        [string]$Root,
        [int64]$RequiredBytes
    )

    $rootPath = [System.IO.Path]::GetPathRoot($Root)
    if ([string]::IsNullOrWhiteSpace($rootPath)) {
        throw ("Не удалось определить диск для пути: {0}" -f $Root)
    }

    $drive = New-Object System.IO.DriveInfo($rootPath)
    if (-not $drive.IsReady) {
        throw ("Диск недоступен: {0}" -f $rootPath)
    }

    if ($drive.AvailableFreeSpace -lt $RequiredBytes) {
        $freeGb = [math]::Round($drive.AvailableFreeSpace / 1GB, 2)
        $requiredGb = [math]::Round($RequiredBytes / 1GB, 2)
        throw ("Недостаточно свободного места на {0}. Доступно {1} GB, требуется не менее {2} GB без учета моделей." -f $rootPath, $freeGb, $requiredGb)
    }

    return $drive.AvailableFreeSpace
}

<#
Блок: работа с папками и текстовыми файлами.
Скрипт создаёт только нужные каталоги и пишет текстовые файлы в UTF-8 BOM.
#>
function Ensure-Directory {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path | Out-Null
    }
}

function Write-Utf8Bom {
    param(
        [string]$Path,
        [string]$Text
    )

    $encoding = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($Path, $Text, $encoding)
}

function Add-Log {
    param(
        [string]$Path,
        [string]$Text
    )

    Add-Content -LiteralPath $Path -Encoding UTF8 -Value ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text)
}

<#
Блок: выбор архива llama.cpp.
Ожидается готовый ZIP-релиз Windows x64 CUDA 12, лежащий рядом с установщиком.
#>
function Select-LlamaZip {
    $zips = @(Get-ChildItem -LiteralPath $ScriptRoot -Filter 'llama*.zip' -File | Sort-Object Name)
    if (-not $zips) {
        throw 'Рядом со скриптом не найден архив llama*.zip.'
    }

    $cudaZips = @($zips | Where-Object {
        $name = $_.Name.ToLowerInvariant()
        $name -match 'cuda' -and $name -match '12' -and $name -notmatch 'cpu|vulkan|rocm|hip|metal|sycl'
    })

    if (-not $cudaZips) {
        throw 'Не найден архив llama.cpp для Windows x64 CUDA 12. Проверьте имя файла llama*.zip.'
    }

    if ($cudaZips.Count -eq 1) {
        return $cudaZips[0]
    }

    Write-Host ''
    Write-Host 'Найдено несколько архивов llama.cpp:'
    for ($i = 0; $i -lt $cudaZips.Count; $i++) {
        Write-Host ('  {0}. {1}' -f ($i + 1), $cudaZips[$i].Name)
    }

    $answer = Read-Host 'Введите номер архива'
    $number = 0
    if (-not [int]::TryParse($answer, [ref]$number) -or $number -lt 1 -or $number -gt $cudaZips.Count) {
        throw 'Выбран некорректный номер архива.'
    }

    return $cudaZips[$number - 1]
}

<#
Блок: выбор архива CUDA runtime.
llama.cpp CUDA-сборка требует отдельный архив cudart с DLL CUDA 12, иначе запуск уйдет на CPU.
#>
function Select-CudaRuntimeZip {
    $zips = @(Get-ChildItem -LiteralPath $ScriptRoot -Filter 'cudart*.zip' -File | Sort-Object Name)
    if (-not $zips) {
        throw 'Рядом со скриптом не найден архив cudart*.zip с CUDA 12 runtime DLL.'
    }

    $cudaZips = @($zips | Where-Object {
        $name = $_.Name.ToLowerInvariant()
        $name -match 'cuda' -and $name -match '12'
    })

    if (-not $cudaZips) {
        throw 'Не найден архив cudart для CUDA 12. Проверьте имя файла cudart*.zip.'
    }

    if ($cudaZips.Count -eq 1) {
        return $cudaZips[0]
    }

    Write-Host ''
    Write-Host 'Найдено несколько архивов CUDA runtime:'
    for ($i = 0; $i -lt $cudaZips.Count; $i++) {
        Write-Host ('  {0}. {1}' -f ($i + 1), $cudaZips[$i].Name)
    }

    $answer = Read-Host 'Введите номер архива'
    $number = 0
    if (-not [int]::TryParse($answer, [ref]$number) -or $number -lt 1 -or $number -gt $cudaZips.Count) {
        throw 'Выбран некорректный номер архива CUDA runtime.'
    }

    return $cudaZips[$number - 1]
}

<#
Блок: проверка совместимости архивов llama.cpp и CUDA runtime.
Для portable-сборки cudart должен быть CUDA 12 и из того же релиза llama.cpp, иначе CUDA backend может не загрузиться.
#>
function Test-CudaRuntimeZipCompatibility {
    param(
        [System.IO.FileInfo]$LlamaZip,
        [System.IO.FileInfo]$CudaRuntimeZip
    )

    $llamaName = $LlamaZip.Name.ToLowerInvariant()
    $cudaName = $CudaRuntimeZip.Name.ToLowerInvariant()

    if ($cudaName -notmatch 'cuda-12') {
        throw ("Архив CUDA runtime должен быть для CUDA 12. Выбран: {0}" -f $CudaRuntimeZip.Name)
    }

    $llamaBuild = $null
    $cudaBuild = $null
    if ($llamaName -match 'b(\d+)') {
        $llamaBuild = $matches[1]
    }
    if ($cudaName -match 'b(\d+)') {
        $cudaBuild = $matches[1]
    }

    if ($llamaBuild -and $cudaBuild -and $llamaBuild -ne $cudaBuild) {
        throw ("Архив CUDA runtime должен быть скачан вместе с тем же релизом llama.cpp. llama.cpp: b{0}, CUDA runtime: b{1}." -f $llamaBuild, $cudaBuild)
    }
}

<#
Блок: показ плана установки.
Перед любыми длительными действиями пользователь видит, где будут созданы папки и куда пойдут загрузки.
#>
function Show-Plan {
    param(
        [string]$Root,
        [string[]]$Directories,
        [string]$DownloadDir,
        [string]$PackagesDir,
        [string]$LogPath,
        [string]$LlamaZipName,
        [string]$CudaRuntimeZipName,
        [string]$WebUIPackage,
        [int64]$FreeSpaceBytes,
        [int64]$RequiredSpaceBytes
    )

    Write-Host ''
    Write-Host 'PortableLLM: план установки'
    Write-Host '=============================='
    Write-Host ('Целевая папка: {0}' -f $Root)
    Write-Host ('Архив llama.cpp: {0}' -f $LlamaZipName)
    Write-Host ('Архив CUDA runtime: {0}' -f $CudaRuntimeZipName)
    Write-Host 'Важно: CUDA runtime должен быть именно CUDA 12 и скачан вместе с тем же релизом llama.cpp.'
    Write-Host ('Пакет Open WebUI: {0}' -f $WebUIPackage)
    Write-Host ('Свободно на целевом диске: {0} GB' -f ([math]::Round($FreeSpaceBytes / 1GB, 2)))
    Write-Host ('Минимум для установки без моделей: {0} GB' -f ([math]::Round($RequiredSpaceBytes / 1GB, 2)))
    Write-Host ''
    Write-Host 'Будут созданы папки:'
    foreach ($dir in $Directories) {
        Write-Host ('  - {0}' -f $dir)
    }
    Write-Host ''
    Write-Host ('Загрузка компонентов будет производиться сюда: {0}' -f $DownloadDir)
    Write-Host ('Python-пакеты Open WebUI будут установлены сюда: {0}' -f $PackagesDir)
    Write-Host ('Подробный лог установки: {0}' -f $LogPath)
    Write-Host ''
}

<#
Блок: загрузка файлов.
Скрипт скачивает только Python embedded ZIP и get-pip.py.
#>
function Download-File {
    param(
        [string]$Url,
        [string]$OutFile,
        [string]$LogPath
    )

    if (Test-Path -LiteralPath $OutFile) {
        Add-Log -Path $LogPath -Text ("Файл уже есть: {0}" -f $OutFile)
        return
    }

    Write-Info ("Скачивание: {0}" -f $Url)
    Add-Log -Path $LogPath -Text ("Скачивание: {0}" -f $Url)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
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

<#
Блок: запуск внешних команд.
Вывод pip и Python пишется в install.log, а в консоли остаются только крупные шаги.
#>
function Invoke-LoggedCommand {
    param(
        [string]$Exe,
        [string[]]$CommandArguments,
        [string]$LogPath,
        [string]$StepName
    )

    Add-Log -Path $LogPath -Text ("=== {0}: START ===" -f $StepName)
    Add-Log -Path $LogPath -Text ("Команда: {0} {1}" -f $Exe, ($CommandArguments -join ' '))

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $Exe
    $startInfo.Arguments = Convert-ToArgumentLine -CommandArguments $CommandArguments
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $null = $process.Start()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    $exitCode = $process.ExitCode

    if (-not [string]::IsNullOrWhiteSpace($stdout)) {
        Add-Content -LiteralPath $LogPath -Encoding UTF8 -Value '--- stdout ---'
        Add-Content -LiteralPath $LogPath -Encoding UTF8 -Value $stdout
    }

    if (-not [string]::IsNullOrWhiteSpace($stderr)) {
        Add-Content -LiteralPath $LogPath -Encoding UTF8 -Value '--- stderr ---'
        Add-Content -LiteralPath $LogPath -Encoding UTF8 -Value $stderr
    }

    Add-Log -Path $LogPath -Text ("=== {0}: EXIT CODE {1} ===" -f $StepName, $exitCode)
    if ($exitCode -ne 0) {
        throw ("Шаг '{0}' завершился с ошибкой. Подробности см. в {1}" -f $StepName, $LogPath)
    }
}

<#
Блок: настройка embedded Python.
Для embedded Python нужно включить import site в python*._pth.
#>
function Enable-PythonSite {
    param([string]$PythonDir)

    $pthFile = Get-ChildItem -LiteralPath $PythonDir -Filter 'python*._pth' -File | Select-Object -First 1
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
    $updated = @()
    $found = $false
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

    foreach ($line in $lines) {
        if ($line -match '^\s*#\s*import site\s*$' -or $line -match '^\s*import site\s*$') {
            if ($missing) {
                $updated += $missing
                $missing = @()
            }

            $updated += 'import site'
            $found = $true
        }
        else {
            $updated += $line
        }
    }

    if (-not $found) {
        if ($missing) {
            $updated += $missing
        }

        $updated += 'import site'
    }

    [System.IO.File]::WriteAllText($pthFile.FullName, (($updated -join "`r`n") + "`r`n"), (New-Object System.Text.ASCIIEncoding))
}

<#
Блок: подготовка папки Python-пакетов.
Перед установкой Open WebUI папка packages очищается, чтобы повторный запуск не смешивал разные версии.
#>
function Reset-PackagesDirectory {
    param([string]$PackagesDir)

    if (Test-Path -LiteralPath $PackagesDir) {
        Get-ChildItem -LiteralPath $PackagesDir -Force | Remove-Item -Recurse -Force
    }
    else {
        Ensure-Directory -Path $PackagesDir
    }
}

<#
Блок: распаковка llama.cpp.
Из ZIP берётся папка, где найден llama-server.exe, и копируется в llama.cpp\bin.
#>
function Install-LlamaCpp {
    param(
        [string]$ZipPath,
        [string]$TempDir,
        [string]$BinDir
    )

    $extractDir = Join-Path $TempDir 'llama-extract'
    if (Test-Path -LiteralPath $extractDir) {
        Remove-Item -LiteralPath $extractDir -Recurse -Force
    }

    Ensure-Directory -Path $extractDir
    Ensure-Directory -Path $BinDir
    Expand-Archive -LiteralPath $ZipPath -DestinationPath $extractDir -Force

    $server = Get-ChildItem -LiteralPath $extractDir -Recurse -Filter 'llama-server.exe' -File | Select-Object -First 1
    if (-not $server) {
        throw 'В архиве llama.cpp не найден llama-server.exe.'
    }

    Copy-Item -Path (Join-Path (Split-Path -Parent $server.FullName) '*') -Destination $BinDir -Recurse -Force
}

<#
Блок: распаковка CUDA runtime.
Из архива cudart копируются DLL, необходимые ggml-cuda.dll для работы на видеокарте.
#>
function Install-CudaRuntime {
    param(
        [string]$ZipPath,
        [string]$TempDir,
        [string]$BinDir
    )

    $extractDir = Join-Path $TempDir 'cudart-extract'
    if (Test-Path -LiteralPath $extractDir) {
        Remove-Item -LiteralPath $extractDir -Recurse -Force
    }

    Ensure-Directory -Path $extractDir
    Ensure-Directory -Path $BinDir
    Expand-Archive -LiteralPath $ZipPath -DestinationPath $extractDir -Force

    $requiredDlls = @('cublas64_12.dll', 'cublasLt64_12.dll', 'cudart64_12.dll')
    foreach ($dll in $requiredDlls) {
        $file = Get-ChildItem -LiteralPath $extractDir -Recurse -Filter $dll -File | Select-Object -First 1
        if (-not $file) {
            throw ("В архиве CUDA runtime не найден файл: {0}" -f $dll)
        }

        Copy-Item -LiteralPath $file.FullName -Destination $BinDir -Force
    }
}

<#
Блок: сохранение конфигурации.
Конфиг использует простой key=value ini без секций.
#>
function Save-Config {
    param(
        [string]$Path,
        [string]$OpenWebUIPackage
    )

    $text = @"
TargetPath=.
PythonExe=python\python.exe
OpenWebUIPackages=OpenWebUI\packages
OpenWebUIData=OpenWebUI\data
LlamaExe=llama.cpp\bin\llama-server.exe
ModelsDir=models
LogsDir=logs
TempDir=temp
LlamaHost=127.0.0.1
LlamaPort=8080
WebUIHost=127.0.0.1
WebUIPort=3000
CudaRequired=true
GpuLayers=all
FlashAttention=auto
SplitMode=none
MainGpu=0
CtxSize=16000
BatchSize=2048
UBatchSize=512
Fit=on
FitTargetMiB=2048
FitCtx=4096
ParallelSlots=1
PromptCacheMiB=0
CacheIdleSlots=false
CacheReuse=
NoContextShift=true
NoMmap=false
CpuMoe=false
NCpuMoe=
Metrics=true
SleepIdleSeconds=
Jinja=true
ReasoningFormat=deepseek
ModelsPreset=
DisableOpenWebUIBackgroundTasks=true
VramReserveGb=2.0
OpenWebUIPackage=$OpenWebUIPackage
"@

    Write-Utf8Bom -Path $Path -Text ($text.Trim() + "`r`n")
}

<#
Блок: основная установка.
Этот блок идёт линейно: путь, план, папки, Python, Open WebUI, llama.cpp, конфиг.
#>
$root = Convert-ToTargetPath -Value $TargetPath
$llamaZip = Select-LlamaZip
$cudaRuntimeZip = Select-CudaRuntimeZip
Test-CudaRuntimeZipCompatibility -LlamaZip $llamaZip -CudaRuntimeZip $cudaRuntimeZip
$requiredFreeSpace = 5GB
$freeSpace = Test-FreeSpace -Root $root -RequiredBytes $requiredFreeSpace

$pythonDir = Join-Path $root 'python'
$openWebUIDir = Join-Path $root 'OpenWebUI'
$openWebUIPackages = Join-Path $openWebUIDir 'packages'
$openWebUIData = Join-Path $openWebUIDir 'data'
$llamaBin = Join-Path $root 'llama.cpp\bin'
$modelsDir = Join-Path $root 'models'
$logsDir = Join-Path $root 'logs'
$configDir = Join-Path $root 'config'
$scriptsDir = Join-Path $root 'scripts'
$tempDir = Join-Path $root 'temp'
$downloadsDir = Join-Path $tempDir 'downloads'
$installLog = Join-Path $logsDir 'install.log'
$configPath = Join-Path $configDir $ConfigFileName
$versionsPath = Join-Path $configDir $VersionsFileName

$directories = @(
    $root,
    $pythonDir,
    $openWebUIPackages,
    $openWebUIData,
    $llamaBin,
    $modelsDir,
    $logsDir,
    $configDir,
    $scriptsDir,
    $tempDir,
    $downloadsDir
)

Show-Plan -Root $root -Directories $directories -DownloadDir $downloadsDir -PackagesDir $openWebUIPackages -LogPath $installLog -LlamaZipName $llamaZip.Name -CudaRuntimeZipName $cudaRuntimeZip.Name -WebUIPackage $OpenWebUIPackage -FreeSpaceBytes $freeSpace -RequiredSpaceBytes $requiredFreeSpace
$confirm = Read-Host 'Продолжить установку? Введите Y для подтверждения'
if ($confirm -notmatch '^(y|yes|д|да)$') {
    Write-Host 'Установка отменена.'
    exit 0
}

foreach ($dir in $directories) {
    Ensure-Directory -Path $dir
}

Write-Utf8Bom -Path $installLog -Text ("PortableLLM install log`r`n")

try {
    $oldTemp = $env:TEMP
    $oldTmp = $env:TMP
    $env:TEMP = $tempDir
    $env:TMP = $tempDir

    $pythonZip = Join-Path $downloadsDir $PythonZipName
    $getPip = Join-Path $downloadsDir 'get-pip.py'
    $pythonExe = Join-Path $pythonDir 'python.exe'

    Download-File -Url $PythonUrl -OutFile $pythonZip -LogPath $installLog
    Write-Info 'Распаковка embedded Python...'
    Expand-Archive -LiteralPath $pythonZip -DestinationPath $pythonDir -Force
    Enable-PythonSite -PythonDir $pythonDir
    Write-Ok 'Python подготовлен.'

    Download-File -Url $GetPipUrl -OutFile $getPip -LogPath $installLog
    Write-Info 'Установка pip...'
    Invoke-LoggedCommand -Exe $pythonExe -CommandArguments @($getPip) -LogPath $installLog -StepName 'Установка pip'
    Write-Ok 'pip установлен.'

    Write-Info 'Установка Open WebUI. Подробный вывод пишется в install.log...'
    Reset-PackagesDirectory -PackagesDir $openWebUIPackages
    Invoke-LoggedCommand -Exe $pythonExe -CommandArguments @(
        '-m', 'pip', 'install',
        '--disable-pip-version-check',
        '--no-warn-script-location',
        '--progress-bar', 'off',
        '--upgrade',
        '--target', $openWebUIPackages,
        $OpenWebUIPackage
    ) -LogPath $installLog -StepName 'Установка Open WebUI'
    Write-Ok 'Open WebUI установлен.'

    Write-Info 'Распаковка llama.cpp...'
    Install-LlamaCpp -ZipPath $llamaZip.FullName -TempDir $tempDir -BinDir $llamaBin
    Write-Ok 'llama.cpp подготовлен.'

    Write-Info 'Распаковка CUDA runtime...'
    Install-CudaRuntime -ZipPath $cudaRuntimeZip.FullName -TempDir $tempDir -BinDir $llamaBin
    Write-Ok 'CUDA runtime подготовлен.'

    Save-Config -Path $configPath -OpenWebUIPackage $OpenWebUIPackage

    $pythonVersion = (& $pythonExe -c "import sys; print('.'.join(map(str, sys.version_info[:3])))" 2>$null | Select-Object -First 1)
    $webUIDist = Get-ChildItem -LiteralPath $openWebUIPackages -Directory -Filter 'open_webui-*.dist-info' -ErrorAction SilentlyContinue | Select-Object -First 1
    $webUIVersion = 'не определена'
    if ($webUIDist -and $webUIDist.Name -match '^open_webui-(.+)\.dist-info$') {
        $webUIVersion = $matches[1]
    }

    $versions = @"
PortableLLM
Дата установки: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Python: $pythonVersion
Open WebUI: $webUIVersion
Пакет Open WebUI: $OpenWebUIPackage
llama.cpp ZIP: $($llamaZip.Name)
llama.cpp вариант: Windows x64 CUDA 12
CUDA runtime ZIP: $($cudaRuntimeZip.Name)
"@
    Write-Utf8Bom -Path $versionsPath -Text ($versions.Trim() + "`r`n")

    Copy-Item -LiteralPath (Join-Path $ScriptRoot 'Start-PortableLLM.ps1') -Destination $scriptsDir -Force -ErrorAction SilentlyContinue
    Copy-Item -LiteralPath (Join-Path $ScriptRoot 'Stop-PortableLLM.ps1') -Destination $scriptsDir -Force -ErrorAction SilentlyContinue
    Copy-Item -LiteralPath (Join-Path $ScriptRoot 'Start-PortableLLM.cmd') -Destination $root -Force -ErrorAction SilentlyContinue
    Copy-Item -LiteralPath (Join-Path $ScriptRoot 'Stop-PortableLLM.cmd') -Destination $root -Force -ErrorAction SilentlyContinue
    Add-Log -Path $installLog -Text 'Установка успешно завершена.'

    Write-Host ''
    Write-Ok 'Установка завершена.'
    Write-Host ('Папка: {0}' -f $root)
    Write-Host ('Конфиг: {0}' -f $configPath)
    Write-Host ('Лог: {0}' -f $installLog)
    Write-Host ('Запуск: {0}' -f (Join-Path $root 'Start-PortableLLM.cmd'))
    Write-Host ('Останов: {0}' -f (Join-Path $root 'Stop-PortableLLM.cmd'))
}
catch {
    Write-Host ''
    Write-Bad 'Установка остановлена из-за ошибки.'
    Write-Host ($_.Exception.Message) -ForegroundColor Red
    Add-Log -Path $installLog -Text ('ОШИБКА: {0}' -f $_.Exception.ToString())
    Write-Host ('Подробности: {0}' -f $installLog) -ForegroundColor Yellow
    Read-Host 'Нажмите Enter, чтобы закрыть окно'
    exit 1
}
finally {
    if (Get-Variable -Name oldTemp -Scope Local -ErrorAction SilentlyContinue) {
        $env:TEMP = $oldTemp
    }
    if (Get-Variable -Name oldTmp -Scope Local -ErrorAction SilentlyContinue) {
        $env:TMP = $oldTmp
    }
}
