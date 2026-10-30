@echo off
setlocal
set "DSH_UPDATE_SELF=%~f0"
set "DSH_UPDATE_CP="
for /f "tokens=2 delims=:" %%c in ('chcp') do set "DSH_UPDATE_CP=%%c"
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -Command "$s=[IO.File]::ReadAllText($env:DSH_UPDATE_SELF,[Text.Encoding]::UTF8); & ([ScriptBlock]::Create($s.Substring($s.LastIndexOf('# POWERSHELL_PAYLOAD')+20)))"
set "DSH_UPDATE_RC=%errorlevel%"
if defined DSH_UPDATE_CP chcp %DSH_UPDATE_CP% >nul
pause
exit /b %DSH_UPDATE_RC%
# POWERSHELL_PAYLOAD
$ErrorActionPreference = 'Stop'
$exitCode = 1
$lock = $null
$oldVersion = $null
$npm = $null
function Get-DshProcesses {
    @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" | Where-Object {
        $_.CommandLine -match '@deepseek-ai[\\/]dsh[\\/]' -and $_.CommandLine -match ' web(?:\s|$)'
    })
}
function Get-Listeners([int]$processId) {
    $queryErrors = @()
    $connections = @(Get-NetTCPConnection -State Listen -OwningProcess $processId -ErrorAction SilentlyContinue -ErrorVariable queryErrors)
    foreach ($queryError in $queryErrors) {
        if ($queryError.FullyQualifiedErrorId -notlike 'CmdletizationQuery_NotFound*') { throw $queryError }
    }
    $connections
}
function Show-Rollback {
    if ($npm -and $oldVersion) {
        Write-Host '可复制的回滚并启动命令（在 CMD 中执行，安装成功后才启动）：'
        $restartArgs = if ($null -ne $port) { " --port $port" } else { '' }
        Write-Host ('    "{0}" i -g @deepseek-ai/dsh@{1} && cd /d "{2}" && "{3}" web{4}' -f $npm, $oldVersion, $workdir, $dsh, $restartArgs)
    } else {
        Write-Host '未取得有效旧版本，无法生成可靠的回滚命令。'
    }
}
function Assert-PortAvailable([int]$number) {
    if ($number -eq 0) {
        Write-Host '    配置为随机空闲端口，由系统分配，启动后再打印实际地址。'
        return
    }
    $busy = @(Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object LocalPort -eq $number)
    if ($busy.Count) {
        foreach ($ownerId in @($busy.OwningProcess | Sort-Object -Unique)) {
            $owner = Get-CimInstance Win32_Process -Filter "ProcessId=$ownerId"
            Write-Host "[端口占用] 端口 $number，PID $ownerId，程序 $($owner.Name)；不会结束该程序。"
        }
        throw "启动前检查失败：端口 $number 已被占用，请先处理上述程序后再运行。"
    }
    Write-Host "    启动前检查通过：端口 $number 未被监听。"
}
function Get-DshExitKind([long]$code) {
    if ($code -eq 0) { return '正常退出' }
    if (@([long]130, [long]-1073741510, [long]3221225786) -contains $code) { return '用户停止' }
    '异常退出'
}
function Assert-Package {
    if (!(Test-Path -LiteralPath $dsh -PathType Leaf)) { throw "找不到启动入口：$dsh" }
    $packageJson = Join-Path $packageDir 'package.json'
    if (!(Test-Path -LiteralPath $packageJson -PathType Leaf)) { throw "找不到包信息：$packageJson" }
    $package = Get-Content -LiteralPath $packageJson -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($package.name -cne '@deepseek-ai/dsh') { throw '包名称校验失败。' }
    $bin = if ($package.bin -is [string]) { $package.bin } else { $package.bin.dsh }
    if (!$bin -or [IO.Path]::IsPathRooted($bin)) { throw 'package.json 的 dsh 入口无效。' }
    $entry = [IO.Path]::GetFullPath((Join-Path $packageDir $bin))
    if (!$entry.StartsWith($packageDir + '\', [StringComparison]::OrdinalIgnoreCase) -or !(Test-Path -LiteralPath $entry -PathType Leaf)) { throw 'dsh 包入口不存在或越界。' }
    $shim = [IO.File]::ReadAllText($dsh)
    $relativeEntry = 'node_modules\@deepseek-ai\dsh\' + ($bin -replace '/', '\' -replace '^\.\\', '')
    if ($shim.IndexOf(('%dp0%\' + $relativeEntry), [StringComparison]::OrdinalIgnoreCase) -lt 0) { throw 'dsh.cmd 未指向 npm 全局前缀中的同一份包。' }
}
try {
    $workdir = Split-Path -LiteralPath $env:DSH_UPDATE_SELF
    Set-Location -LiteralPath $workdir
    $lockPath = Join-Path $workdir '.dsh-update.lock'
    try {
        $lock = [IO.FileStream]::new($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read, 4096, [IO.FileOptions]::DeleteOnClose)
    } catch [IO.IOException] {
        $nativeCode = $_.Exception.HResult -band 65535
        if ($nativeCode -eq 32) {
            Write-Host '锁文件存在共享冲突：脚本可能已在运行，也可能被其他程序占用。'
            exit 2
        }
        throw "无法创建锁文件：$lockPath；系统错误码 $nativeCode；$($_.Exception.Message)"
    } catch [UnauthorizedAccessException] {
        throw "没有权限创建或读写锁文件：$lockPath；$($_.Exception.Message)"
    }
    $reader = New-Object IO.StreamReader($lock, [Text.Encoding]::UTF8, $true, 1024, $true)
    $ownerText = $reader.ReadToEnd().Trim()
    $reader.Dispose()
    if ($ownerText -match '^\d+$' -and (Get-Process -Id ([int]$ownerText) -ErrorAction SilentlyContinue)) {
        Write-Host '脚本已在运行。'
        $lock.Dispose()
        $lock = $null
        exit 2
    }
    $lock.SetLength(0)
    $bytes = [Text.Encoding]::UTF8.GetBytes([string]$PID)
    $lock.Write($bytes, 0, $bytes.Length)
    $lock.Flush()
    $npm = (Get-Command npm.cmd -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $prefixOutput = @(& $npm prefix -g)
    if ($LASTEXITCODE -ne 0) { throw 'npm prefix -g 失败。' }
    $prefix = ($prefixOutput -join "`n").Trim()
    if (![IO.Path]::IsPathRooted($prefix) -or !(Test-Path -LiteralPath $prefix -PathType Container)) { throw 'npm 全局前缀无效。' }
    $dsh = Join-Path $prefix 'dsh.cmd'
    $packageDir = [IO.Path]::GetFullPath((Join-Path $prefix 'node_modules\@deepseek-ai\dsh'))
    Write-Host "`n[1/4] 查找并关闭 dsh web 进程 ..."
    $processes = @(Get-DshProcesses)
    $ports = @()
    foreach ($item in $processes) {
        $listeners = @(Get-Listeners $item.ProcessId)
        $ports += @($listeners | Select-Object -ExpandProperty LocalPort)
        Write-Host "    PID $($item.ProcessId)，监听端口：$(($listeners.LocalPort | Sort-Object -Unique) -join ', ')"
        Write-Host "    $($item.CommandLine)"
    }
    $ports = @($ports | Sort-Object -Unique)
    $port = $null
    $commandPorts = @($processes | ForEach-Object {
        $found = [regex]::Matches($_.CommandLine, '(?:^|\s)--port(?:=|\s+)["'']?(\d+)["'']?(?=\s|$)')
        if ($found.Count) {
            $value = 0
            if ([int]::TryParse($found[$found.Count - 1].Groups[1].Value, [ref]$value) -and $value -ge 0 -and $value -le 65535) { $value }
        }
    } | Sort-Object -Unique)
    if ($commandPorts.Count -eq 1) { $port = $commandPorts[0] }
    elseif ($commandPorts.Count -eq 0 -and $ports.Count -eq 1) { $port = $ports[0] }
    if ($null -ne $port) { Write-Host "    重启端口：$port（优先取命令行，其次取唯一监听端口）。" }
    else { Write-Host '    无法唯一确定端口，不传 --port，按配置启动。' }
    if (!$processes.Count) { Write-Host '    没找到 dsh，跳过杀进程；启动时不传 --port，使用默认端口。' }
    elseif ($null -eq $port) { Write-Host '    dsh 尚未监听端口；启动时不传 --port，使用默认端口。' }
    if (Test-Path -LiteralPath $dsh) {
        Assert-Package
        $versionOutput = @(& $dsh --version)
        if ($LASTEXITCODE -ne 0) { throw '读取当前 dsh 版本失败。' }
        $oldVersion = ($versionOutput | Where-Object { $_ -match '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$' } | Select-Object -Last 1)
        if (!$oldVersion) { throw '当前 dsh 版本格式无效。' }
    }
    $targetOutput = @(& $npm view '@deepseek-ai/dsh@latest' version --fetch-timeout=30000 --fetch-retries=1)
    if ($LASTEXITCODE -ne 0) { throw '读取 npm latest 版本失败。' }
    $target = ($targetOutput -join "`n").Trim()
    if ($target -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$') { throw 'npm latest 版本格式无效。' }
    Write-Host '============================================'
    Write-Host '  DSH 一键更新脚本'
    Write-Host "  目标版本：npm 上的 latest（当前为 $target）"
    Write-Host '============================================'
    Write-Host "当前版本 $(if ($oldVersion) {$oldVersion} else {'未安装'}) → 目标版本 $target"
    Write-Host "npm 路径：$npm"
    Write-Host "dsh 路径：$dsh"
    Write-Host '[注意] 这个脚本会关掉正在运行的 dsh web。'
    Write-Host '        已保存的会话不会丢，重启后能在左侧列表里找回。'
    # 版本确认即为继续确认，无需额外 pause
    if ($oldVersion -ne $target) {
        Write-Host '[版本变更] 将安装上方目标版本；可能跨越多个版本或从预发布版切换到正式版。'
        if ((Read-Host '确认安装该版本？输入 Y 继续，其它输入取消') -ine 'Y') {
            Write-Host '已取消，未结束任何 dsh 进程，未安装。'
            exit 0
        }
    }
    if ($oldVersion -eq $target -and (Read-Host '确认重启？输入 Y 继续，其它输入取消') -ine 'Y') { exit 0 }
    if ($processes.Count -gt 1 -or $ports.Count -gt 1) {
        Write-Host '!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!' -ForegroundColor Yellow
        Write-Host '[多实例警告] 将结束上面列出的全部 dsh 进程，只启动一个实例！' -ForegroundColor Yellow
        Write-Host "    将关闭的监听端口：$($ports -join ', ')"
        Write-Host "    仅重启：$(if ($null -ne $port) {"端口 $port"} else {'默认端口'})；其余实例不会自动恢复。"
        if ((Read-Host '确认关闭全部并仅启动上述一个实例？输入 Y 继续，其它输入取消') -ine 'Y') {
            Write-Host '已取消，未结束任何 dsh 进程，未安装。'
            exit 0
        }
    }
    foreach ($item in $processes) {
        $current = Get-CimInstance Win32_Process -Filter "ProcessId=$($item.ProcessId)"
        if (!$current -or $current.Name -ine 'node.exe' -or $current.CommandLine -notmatch '@deepseek-ai[\\/]dsh[\\/]' -or $current.CommandLine -notmatch ' web(?:\s|$)' -or $current.CreationDate -ne $item.CreationDate) { throw "PID $($item.ProcessId) 身份复核失败，停止执行，绝不强杀。" }
        & taskkill.exe /F /PID $item.ProcessId
        $killCode = $LASTEXITCODE
        $remaining = Get-CimInstance Win32_Process -Filter "ProcessId=$($item.ProcessId)"
        if ($remaining) { throw "PID $($item.ProcessId) 结束失败（taskkill 退出码 $killCode），可能权限不足；停止安装。" }
        if ($killCode -ne 0) { throw "taskkill 异常（退出码 $killCode），停止执行。" }
        Write-Host "    PID $($item.ProcessId) 已确认结束。"
    }
    if ($ports.Count) {
        $deadline = [DateTime]::UtcNow.AddSeconds(10)
        do {
            $busy = @(Get-NetTCPConnection -State Listen | Where-Object { $ports -contains $_.LocalPort })
            if (!$busy.Count) { break }
            if ([DateTime]::UtcNow -ge $deadline) { throw "等待端口释放超时：$(($busy.LocalPort | Sort-Object -Unique) -join ', ')；停止安装。" }
            Start-Sleep -Seconds 1
        } while ($true)
        Write-Host '    原监听端口已确认释放。'
    }
    Write-Host "`n[2/4] 升级全局 dsh 到最新版 ..."
    if ($oldVersion -eq $target) { Write-Host '    已是最新，跳过安装，直接进入启动步骤。' }
    else {
        Write-Host "    安装前旧版本：$(if ($oldVersion) {$oldVersion} else {'未安装'})"
        & $npm i -g "@deepseek-ai/dsh@$target" --no-audit --no-fund --fetch-timeout=30000 --fetch-retries=1
        if ($LASTEXITCODE -ne 0) { throw "升级没成功，npm 退出码 $LASTEXITCODE。请查看上方输出，检查权限或文件占用。" }
    }
    Write-Host "`n[3/4] 确认版本与启动入口 ..."
    Assert-Package
    $installed = @(& $dsh --version)
    if ($LASTEXITCODE -ne 0 -or ($installed -notcontains $target)) { throw '安装后的版本与目标版本不一致。' }
    $installed | ForEach-Object { Write-Host $_ }
    Write-Host "`n[4/4] 启动 dsh web ..."
    Write-Host '    这个窗口要一直开着，关掉就等于关掉服务。'
    Write-Host '    进去先按一次 Ctrl + Shift + R 强制刷新。'
    if ($null -ne $port) { Assert-PortAvailable ([int]$port) }
    else { Write-Host '    不探测合成配置，直接启动并显示实际监听地址。' }
    $beforeIds = @((Get-DshProcesses).ProcessId)
    $arguments = '/d /s /c ""' + $dsh + '" web' + $(if ($null -ne $port) { " --port $port" } else { '' }) + '"'
    $child = New-Object Diagnostics.Process
    $child.StartInfo.FileName = $env:ComSpec
    $child.StartInfo.Arguments = $arguments
    $child.StartInfo.WorkingDirectory = $workdir
    $child.StartInfo.UseShellExecute = $false
    if (!$child.Start()) { throw '无法创建 dsh 启动进程。' }
    $shown = @{}
    do {
        foreach ($newProcess in @(Get-DshProcesses | Where-Object { $beforeIds -notcontains $_.ProcessId -and $_.ParentProcessId -eq $child.Id })) {
            foreach ($actualPort in @((Get-Listeners $newProcess.ProcessId).LocalPort | Sort-Object -Unique)) {
                if (!$shown.ContainsKey($actualPort)) {
                    if ($null -ne $port -and $actualPort -ne $port) { Write-Host "[注意] 实际监听端口 $actualPort 与请求端口 $port 不同。" }
                    Write-Host "    启动后在浏览器打开：http://127.0.0.1:$actualPort"
                    $shown[$actualPort] = $true
                }
            }
        }
        if ($child.WaitForExit(1000)) { break }
    } while ($true)
    $child.WaitForExit()
    $exitCode = $child.ExitCode
    $exitKind = Get-DshExitKind $exitCode
    if ($exitKind -eq '用户停止') {
        Write-Host "`ndsh web 正常停止（Ctrl+C，原退出码 $exitCode）。"
        $exitCode = 0
    } elseif ($exitKind -eq '正常退出') {
        Write-Host "`ndsh web 正常退出。"
    } else {
        Write-Host "`ndsh web 异常退出（退出码 $exitCode），请查看上方输出/日志。"
        Show-Rollback
    }
} catch {
    Write-Host "`n[失败] $($_.Exception.Message)"
    Show-Rollback
    $exitCode = 1
} finally {
    if ($lock) {
        $lock.Dispose()
    }
}
exit $exitCode