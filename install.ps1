#Requires -Version 5.1
<#
ai-cli-quickinstall — 一行命令装 Claude Code / Codex 等 AI CLI 工具

用法:
    irm https://<host>/install.ps1 | iex
    # 或下载后本地执行
    .\install.ps1
#>

[CmdletBinding()]
param(
    [string]$Tool,            # 跳过菜单，直接装指定工具：claude-code | codex
    [ValidateSet('auto','native','npm')]
    [string]$Method = 'auto', # 安装方式
    [string]$Mirror,          # 强制使用某个镜像（跳过测速）
    [ValidateSet('User','Machine')]
    [string]$PathScope = 'User',  # native 安装时把 bin 目录加到哪一级 PATH
    [switch]$NonInteractive   # 非交互模式（用于 CI / pipe 流式执行）
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---------- 元数据 ----------------------------------------------------------
# 工具清单：每项描述支持的安装方式、对应的下载/包信息
$script:Tools = [ordered]@{
    'claude-code' = @{
        DisplayName = 'Claude Code'
        Native      = $null            # TODO: 填官方 release 地址模板
        Npm         = '@anthropic-ai/claude-code'
    }
    'codex' = @{
        DisplayName = 'OpenAI Codex CLI'
        Native      = $null            # TODO
        Npm         = $null            # TODO: 确认包名
    }
}

# 镜像源候选——按用途分组，调用方决定测哪一组。
# Measure-Mirror 默认超时 4s（国内访问 github.com 实测 3-4s 是常态）。

# GitHub release 二进制下载（native 安装用）
$script:GitHubMirrors = @(
    @{ Name = 'GitHub';    Probe = 'https://github.com' }
    @{ Name = 'ghproxy';   Probe = 'https://ghproxy.com' }
    @{ Name = 'ghps.cc';   Probe = 'https://ghps.cc' }
    @{ Name = 'gh-proxy';  Probe = 'https://gh-proxy.com' }
)

# npm registry（npm 安装用）
$script:NpmMirrors = @(
    @{ Name = 'npmjs';      Probe = 'https://registry.npmjs.org' }
    @{ Name = 'npmmirror';  Probe = 'https://registry.npmmirror.com' }
)

# ---------- 模块 1: 环境检测 ------------------------------------------------
function Test-Environment {
    [CmdletBinding()]
    param()
    [pscustomobject]@{
        HasNode = [bool](Get-Command node -ErrorAction SilentlyContinue)
        HasNpm  = [bool](Get-Command npm  -ErrorAction SilentlyContinue)
        HasPnpm = [bool](Get-Command pnpm -ErrorAction SilentlyContinue)
        IsAdmin = ([Security.Principal.WindowsPrincipal]`
                    [Security.Principal.WindowsIdentity]::GetCurrent()`
                  ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        Interactive = [Environment]::UserInteractive -and -not $NonInteractive
    }
}

# ---------- 模块 2: 镜像测速 ------------------------------------------------
# 用 HttpClient 并发 GET（ResponseHeadersRead，只等 header，近似 TTFB），
# 统一超时丢弃，返回最快一个。HEAD 在某些 CDN 上行为不一致，所以用 GET。

function Measure-Mirror {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [array]$Candidates,
        [int]$TimeoutMs = 4000
    )
    if (-not $Candidates -or $Candidates.Count -eq 0) {
        throw 'Measure-Mirror: 镜像列表为空'
    }

    Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
    # TLS 1.2（PS 5.1 默认可能是 SSL3/TLS1.0，对现代站点会握手失败）
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $true
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromMilliseconds($TimeoutMs)
    $client.DefaultRequestHeaders.UserAgent.ParseAdd('ai-cli-quickinstall/0.1')

    try {
        $pending = foreach ($m in $Candidates) {
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $task = $client.GetAsync(
                $m.Probe,
                [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
            )
            [pscustomobject]@{ Mirror = $m; Stopwatch = $sw; Task = $task }
        }

        # 等所有任务收敛（成功 / 失败 / Timeout 抛在 task 内部）
        try {
            [System.Threading.Tasks.Task]::WaitAll(@($pending.Task))
        } catch [AggregateException] {
            # 单个 task 的异常被包成 AggregateException，按 task 单独判断即可
        }

        $results = foreach ($p in $pending) {
            $p.Stopwatch.Stop()
            $ok = $p.Task.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion `
                  -and $p.Task.Result -and $p.Task.Result.IsSuccessStatusCode
            [pscustomobject]@{
                Name      = $p.Mirror.Name
                Url       = $p.Mirror.Probe
                ElapsedMs = $p.Stopwatch.ElapsedMilliseconds
                Ok        = $ok
            }
            if ($p.Task.Result) { $p.Task.Result.Dispose() }
        }

        $best = $results | Where-Object Ok | Sort-Object ElapsedMs | Select-Object -First 1
        if (-not $best) {
            $detail = ($results | ForEach-Object { "$($_.Name)=fail" }) -join ', '
            throw "所有镜像都不可达（超时 ${TimeoutMs}ms）: $detail"
        }

        Write-Verbose ("镜像测速结果: " + (
            $results | Sort-Object ElapsedMs | ForEach-Object {
                $tag = if ($_.Ok) { "$($_.ElapsedMs)ms" } else { 'fail' }
                "$($_.Name)=$tag"
            }
        ) -join ', ')
        Write-Host "选用镜像: $($best.Name) ($($best.ElapsedMs)ms)"
        return $best
    }
    finally {
        $client.Dispose()
        $handler.Dispose()
    }
}

# ---------- 模块 3: 交互菜单 ------------------------------------------------
function Show-Menu {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Env)
    if (-not $Env.Interactive) {
        throw '非交互环境下必须通过 -Tool 参数指定要安装的工具'
    }
    # TODO: 用 $Host.UI.PromptForChoice 实现菜单（兼容 irm|iex 流式输入）
    throw 'Show-Menu: not implemented'
}

# ---------- 模块 4: PATH 管理（参考 ai-cli-installer Rust 实现） ------------
# 用 [Environment]::SetEnvironmentVariable 直接改注册表 + 广播 WM_SETTINGCHANGE，
# 新开的进程立刻能看到。User scope 无需 UAC；Machine scope 需要管理员。

function Test-PathContains {
    param([string]$PathString, [string]$Dir)
    if (-not $PathString) { return $false }
    $norm = $Dir.TrimEnd('\')
    foreach ($p in $PathString -split ';') {
        if ($p -and ($p.Trim().TrimEnd('\') -ieq $norm)) { return $true }
    }
    return $false
}

function Get-PathStatus {
    param([Parameter(Mandatory)] [string]$Dir)
    $userPath    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    [pscustomobject]@{
        Dir           = $Dir
        InUserPath    = Test-PathContains $userPath    $Dir
        InMachinePath = Test-PathContains $machinePath $Dir
        Effective     = (Test-PathContains $env:PATH $Dir)
    }
}

function Add-ToPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Dir,
        [ValidateSet('User','Machine')] [string]$Scope = 'User'
    )
    if ($Scope -eq 'Machine' -and -not (Test-Environment).IsAdmin) {
        # 重启自身提权，仅执行 PATH 写入。脚本已下载到磁盘的场景才适用；
        # irm|iex 流式场景请改用 -PathScope User，或先把脚本 Save-Then-Run。
        throw "写入 Machine PATH 需要管理员权限。请用管理员 PowerShell 运行，或使用 -PathScope User。"
    }
    $cur = [Environment]::GetEnvironmentVariable('Path', $Scope)
    if (-not $cur) { $cur = '' }
    if (Test-PathContains $cur $Dir) {
        Write-Verbose "$Dir 已在 $Scope PATH 中，跳过"
        return
    }
    if ($cur -and -not $cur.EndsWith(';')) { $cur += ';' }
    $new = $cur + $Dir
    [Environment]::SetEnvironmentVariable('Path', $new, $Scope)
    # 当前进程也立刻可见
    if (-not (Test-PathContains $env:PATH $Dir)) {
        $env:PATH = "$env:PATH;$Dir"
    }
    Write-Host "已将 $Dir 添加到 $Scope PATH"
}

function Remove-FromPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Dir,
        [ValidateSet('User','Machine')] [string]$Scope = 'User'
    )
    $cur = [Environment]::GetEnvironmentVariable('Path', $Scope)
    if (-not $cur) { return }
    $norm = $Dir.TrimEnd('\')
    $kept = $cur -split ';' | Where-Object { $_ -and ($_.TrimEnd('\') -ine $norm) }
    [Environment]::SetEnvironmentVariable('Path', ($kept -join ';'), $Scope)
}

# ---------- 模块 5: 安装分发 ------------------------------------------------
function Install-Tool {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$ResolvedMethod,  # native | npm
        [string]$MirrorBase
    )
    $meta = $script:Tools[$Name]
    if (-not $meta) { throw "未知工具: $Name" }

    switch ($ResolvedMethod) {
        'native' { Install-Native -Meta $meta -MirrorBase $MirrorBase -Scope $PathScope }
        'npm'    { Install-Npm    -Meta $meta }
        default  { throw "未知安装方式: $ResolvedMethod" }
    }
}

function Install-Native {
    param($Meta, [string]$MirrorBase, [string]$Scope = 'User')
    # TODO: 根据 $Meta.Native 模板拼接下载 URL，下载并校验，解压到 install dir
    # 安装完成后调用：
    #     Add-ToPath -Dir $installBinDir -Scope $Scope
    throw 'Install-Native: not implemented'
}

function Install-Npm {
    param($Meta)
    if (-not $Meta.Npm) { throw "$($Meta.DisplayName) 暂不支持 npm 安装" }
    # TODO: npm i -g $Meta.Npm，可选切 npmmirror registry
    throw 'Install-Npm: not implemented'
}

# ---------- 安装方式决策 ----------------------------------------------------
function Resolve-Method {
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$Requested,
        [Parameter(Mandatory)] $Env
    )
    $meta = $script:Tools[$Name]
    $canNative = [bool]$meta.Native
    $canNpm    = [bool]$meta.Npm -and $Env.HasNpm

    switch ($Requested) {
        'native' {
            if (-not $canNative) { throw "$Name 不支持 native 安装" }
            return 'native'
        }
        'npm' {
            if (-not $meta.Npm) { throw "$Name 没有提供 npm 包" }
            if (-not $Env.HasNpm) { throw 'npm 不可用，请先安装 Node.js' }
            return 'npm'
        }
        'auto' {
            if ($canNative) { return 'native' }
            if ($canNpm)    { return 'npm' }
            throw "$Name 当前环境下没有可用的安装方式（无 native 包，且未检测到 npm）"
        }
    }
}

# ---------- 入口 ------------------------------------------------------------
function Invoke-Main {
    $env = Test-Environment

    $target = if ($Tool) { $Tool } else { Show-Menu -Env $env }
    if (-not $script:Tools.Contains($target)) {
        throw "未知工具: $target（支持: $($script:Tools.Keys -join ', ')）"
    }

    $method     = Resolve-Method -Name $target -Requested $Method -Env $env
    # 不同安装方式用不同镜像组（native = GitHub releases，npm = registry）
    $mirrorSet = switch ($method) {
        'native' { $script:GitHubMirrors }
        'npm'    { $script:NpmMirrors }
    }
    $mirrorBase = if ($Mirror) { $Mirror } else { (Measure-Mirror -Candidates $mirrorSet).Url }

    Write-Host "安装 $($script:Tools[$target].DisplayName) (方式: $method, 镜像: $mirrorBase)"
    Install-Tool -Name $target -ResolvedMethod $method -MirrorBase $mirrorBase
}

Invoke-Main
