#Requires -Version 5.1
<#
ai-cli-quickinstall — 一行命令装 Claude Code / Codex 等 AI CLI 工具

用法:
    irm https://<host>/install.ps1 | iex                    # 交互式
    irm https://<host>/install.ps1 -OutFile a.ps1; .\a.ps1 -Tool claude-code  # 直接装
#>

[CmdletBinding()]
param(
    [string]$Tool,            # 跳过菜单，直接装指定工具：claude-code | codex
    [ValidateSet('auto','native','npm')]
    [string]$Method = 'auto',
    [string]$Channel = 'latest',
    [ValidateSet('User','Machine')]
    [string]$PathScope = 'User',
    [switch]$NonInteractive
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---------- 元数据 ----------------------------------------------------------
# 镜像仓库布局参考 ai-cli-installer 的 mirrors.rs：
#   channel: raw.githubusercontent.com/{owner}/{repo}/main/channels/{channel}.txt
#   manifest: releases/download/v{ver}/manifest.json
#   asset:    releases/download/v{ver}/{platform}-{binary}

$script:Tools = [ordered]@{
    'claude-code' = @{
        DisplayName  = 'Claude Code'
        Owner        = 'zuoliangyu'
        Repo         = 'claude-code-mirror'
        NpmPackage   = '@anthropic-ai/claude-code'
        NpmMinNode   = 18
        LauncherDir  = (Join-Path $env:USERPROFILE '.local\bin')
        SelfInstall  = $true            # 下载完跑 `<binary> install <channel>` 落位
    }
    'codex' = @{
        DisplayName  = 'OpenAI Codex CLI'
        Owner        = 'zuoliangyu'
        Repo         = 'codex-mirror'
        NpmPackage   = '@openai/codex'
        NpmMinNode   = 18
        LauncherDir  = (Join-Path $env:USERPROFILE '.local\bin')
        SelfInstall  = $false           # 下载下来是 .zst，需要解压到 LauncherDir
    }
}

# GitHub 代理候选（参考 mirrors.rs::builtin_for）
$script:GitHubProxies = @(
    @{ Name = 'github-direct'; Proxy = $null }
    @{ Name = 'gh-proxy';      Proxy = 'https://gh-proxy.com' }
    @{ Name = 'fastgit';       Proxy = 'https://fastgit.cc' }
    @{ Name = 'yylx';          Proxy = 'https://git.yylx.win' }
    @{ Name = 'chenc';         Proxy = 'https://github.chenc.dev' }
    @{ Name = 'ghproxy-net';   Proxy = 'https://ghproxy.net' }
    @{ Name = 'ghfast';        Proxy = 'https://ghfast.top' }
)

$script:NpmRegistries = @(
    @{ Name = 'npmjs';     Url = 'https://registry.npmjs.org' }
    @{ Name = 'npmmirror'; Url = 'https://registry.npmmirror.com' }
)

# 缓存目录（暂存下载、缓存 zstd.exe）
$script:CacheDir = Join-Path $env:LOCALAPPDATA 'ai-cli-quickinstall'

# ---------- URL 构造 --------------------------------------------------------
function Get-PlatformId {
    $arch = if ([Environment]::Is64BitOperatingSystem) {
        if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
    } else { 'x86' }
    "win32-$arch"
}

function Resolve-ProxyUrl {
    param([string]$Raw, [string]$Proxy)
    if (-not $Proxy) { return $Raw }
    "$($Proxy.TrimEnd('/'))/$Raw"
}

function Get-ChannelUrl {
    param($Tool, [string]$ChannelName, [string]$Proxy)
    $raw = "https://raw.githubusercontent.com/$($Tool.Owner)/$($Tool.Repo)/main/channels/$ChannelName.txt"
    Resolve-ProxyUrl $raw $Proxy
}

function Get-ManifestUrl {
    param($Tool, [string]$Version, [string]$Proxy)
    $raw = "https://github.com/$($Tool.Owner)/$($Tool.Repo)/releases/download/v$Version/manifest.json"
    Resolve-ProxyUrl $raw $Proxy
}

function Get-AssetUrl {
    param($Tool, [string]$Version, [string]$AssetName, [string]$Proxy)
    $raw = "https://github.com/$($Tool.Owner)/$($Tool.Repo)/releases/download/v$Version/$AssetName"
    Resolve-ProxyUrl $raw $Proxy
}

# ---------- 模块 1: 环境检测 ------------------------------------------------
function Test-Environment {
    [pscustomobject]@{
        HasNode = [bool](Get-Command node -ErrorAction SilentlyContinue)
        HasNpm  = [bool](Get-Command npm  -ErrorAction SilentlyContinue)
        HasZstd = [bool](Get-Command zstd -ErrorAction SilentlyContinue)
        IsAdmin = ([Security.Principal.WindowsPrincipal]`
                    [Security.Principal.WindowsIdentity]::GetCurrent()`
                  ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        Interactive = [Environment]::UserInteractive -and -not $NonInteractive
    }
}

function Get-NodeMajor {
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) { return $null }
    $v = (& node --version) 2>$null
    if ($v -match 'v(\d+)\.') { return [int]$Matches[1] }
    return $null
}

# ---------- 模块 2: 镜像测速 ------------------------------------------------
function Measure-Mirror {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [array]$Candidates,
        [Parameter(Mandatory)] [string]$ProbeUrlKey,   # 'Url' | 'Probe'
        [int]$TimeoutMs = 6000     # GH 代理冷启动 4-5s 是常态；6s 让代理过、又能挡住 CN 直连擦边
    )
    Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
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
                $m[$ProbeUrlKey],
                [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
            )
            [pscustomobject]@{ Mirror = $m; Stopwatch = $sw; Task = $task }
        }
        try { [System.Threading.Tasks.Task]::WaitAll(@($pending.Task)) } catch [AggregateException] { }

        $results = foreach ($p in $pending) {
            $p.Stopwatch.Stop()
            $ok = $p.Task.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion `
                  -and $p.Task.Result -and $p.Task.Result.IsSuccessStatusCode
            [pscustomobject]@{
                Mirror    = $p.Mirror
                ElapsedMs = $p.Stopwatch.ElapsedMilliseconds
                Ok        = $ok
            }
            if ($p.Task.Result) { $p.Task.Result.Dispose() }
        }

        $best = $results | Where-Object Ok | Sort-Object ElapsedMs | Select-Object -First 1
        if (-not $best) {
            $detail = ($results | ForEach-Object { "$($_.Mirror.Name)=fail" }) -join ', '
            throw "所有镜像都不可达: $detail"
        }
        Write-Host "选用镜像: $($best.Mirror.Name) ($($best.ElapsedMs)ms)"
        return $best.Mirror
    }
    finally {
        $client.Dispose()
        $handler.Dispose()
    }
}

# ---------- 模块 3: 交互菜单 ------------------------------------------------
function Show-Menu {
    param([Parameter(Mandatory)] $Env)
    if (-not $Env.Interactive) {
        throw '非交互环境下必须通过 -Tool 参数指定要安装的工具'
    }
    $keys = @($script:Tools.Keys)
    $choices = foreach ($k in $keys) {
        $t = $script:Tools[$k]
        New-Object Management.Automation.Host.ChoiceDescription "&$($keys.IndexOf($k) + 1) $($t.DisplayName)", "$k"
    }
    $idx = $Host.UI.PromptForChoice('选择要安装的工具', '', [Management.Automation.Host.ChoiceDescription[]]$choices, 0)
    return $keys[$idx]
}

# ---------- 模块 4: PATH 管理 -----------------------------------------------
function Test-PathContains {
    param([string]$PathString, [string]$Dir)
    if (-not $PathString) { return $false }
    $norm = $Dir.TrimEnd('\')
    foreach ($p in $PathString -split ';') {
        if ($p -and ($p.Trim().TrimEnd('\') -ieq $norm)) { return $true }
    }
    return $false
}

function Add-ToPath {
    param(
        [Parameter(Mandatory)] [string]$Dir,
        [ValidateSet('User','Machine')] [string]$Scope = 'User'
    )
    if ($Scope -eq 'Machine' -and -not (Test-Environment).IsAdmin) {
        throw '写入 Machine PATH 需要管理员权限。请用管理员 PowerShell 运行，或使用 -PathScope User。'
    }
    $cur = [Environment]::GetEnvironmentVariable('Path', $Scope)
    if (-not $cur) { $cur = '' }
    if (Test-PathContains $cur $Dir) {
        Write-Verbose "$Dir 已在 $Scope PATH 中"
        return
    }
    if ($cur -and -not $cur.EndsWith(';')) { $cur += ';' }
    [Environment]::SetEnvironmentVariable('Path', $cur + $Dir, $Scope)
    if (-not (Test-PathContains $env:PATH $Dir)) { $env:PATH = "$env:PATH;$Dir" }
    Write-Host "已将 $Dir 添加到 $Scope PATH"
}

# ---------- 模块 5: 下载 / 校验 / zstd 解压 ---------------------------------
function Get-StagingPath {
    param([string]$Name)
    $dir = Join-Path $script:CacheDir 'staging'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Join-Path $dir $Name
}

function Invoke-DownloadWithFallback {
    # 按 proxy 顺序尝试下载到 $Dest，第一个成功即返回。
    param(
        [Parameter(Mandatory)] [scriptblock]$UrlBuilder,  # param($proxyEntry) returning [string]
        [Parameter(Mandatory)] [string]$Dest,
        [Parameter(Mandatory)] [array]$Proxies,
        [int]$TimeoutSec = 30
    )
    $errors = @()
    foreach ($pr in $Proxies) {
        $url = & $UrlBuilder $pr
        try {
            Write-Verbose "  GET $url"
            Invoke-WebRequest -Uri $url -OutFile $Dest -UseBasicParsing -TimeoutSec $TimeoutSec
            Write-Host "  下载完成 ($($pr.Name))"
            return
        } catch {
            $errors += "$($pr.Name): $($_.Exception.Message)"
            if (Test-Path $Dest) { Remove-Item $Dest -Force }
        }
    }
    throw "所有镜像均下载失败:`n$($errors -join "`n")"
}

function Invoke-FetchTextWithFallback {
    # 同 Invoke-DownloadWithFallback，但返回响应文本（不落盘）。
    # GitHub Releases 把 .json 当 octet-stream 发，IWR 返回 byte[]，需要转一下。
    param(
        [Parameter(Mandatory)] [scriptblock]$UrlBuilder,
        [Parameter(Mandatory)] [array]$Proxies,
        [int]$TimeoutSec = 15
    )
    $errors = @()
    foreach ($pr in $Proxies) {
        $url = & $UrlBuilder $pr
        try {
            $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec $TimeoutSec
            $content = $r.Content
            if ($content -is [byte[]]) {
                $content = [System.Text.Encoding]::UTF8.GetString($content)
            }
            return @{ Content = $content; Proxy = $pr }
        } catch {
            $errors += "$($pr.Name): $($_.Exception.Message)"
        }
    }
    throw "所有镜像均请求失败:`n$($errors -join "`n")"
}

function Test-Sha256 {
    param([string]$File, [string]$Expected)
    if (-not $Expected) { return }
    $clean = $Expected -replace '^sha256:', ''
    $actual = (Get-FileHash -Algorithm SHA256 -Path $File).Hash.ToLower()
    if ($actual -ne $clean.ToLower()) {
        throw "SHA256 校验失败: 期望 $clean, 实际 $actual"
    }
    Write-Host '  SHA256 校验通过'
}

function Get-ZstdExe {
    # 缓存 zstd.exe；按需从 facebook/zstd release 下载
    $dest = Join-Path $script:CacheDir 'bin\zstd.exe'
    if (Test-Path $dest) { return $dest }
    if (Get-Command zstd -ErrorAction SilentlyContinue) {
        return (Get-Command zstd).Source
    }

    Write-Host '正在下载 zstd.exe（用于解压 codex）...'
    New-Item -ItemType Directory -Path (Split-Path $dest) -Force | Out-Null
    $tmp = Get-StagingPath 'zstd-win64.zip'
    $version = 'v1.5.6'
    Invoke-DownloadWithFallback `
        -UrlBuilder { param($pr)
            $raw = "https://github.com/facebook/zstd/releases/download/$version/zstd-$version-win64.zip"
            Resolve-ProxyUrl $raw $pr.Proxy
        } `
        -Dest $tmp `
        -Proxies $script:GitHubProxies

    $extract = Get-StagingPath 'zstd-extract'
    if (Test-Path $extract) { Remove-Item $extract -Recurse -Force }
    Expand-Archive -Path $tmp -DestinationPath $extract -Force
    $found = Get-ChildItem -Path $extract -Filter zstd.exe -Recurse | Select-Object -First 1
    if (-not $found) { throw 'zstd.exe 解压后未找到' }
    Copy-Item $found.FullName $dest -Force
    Remove-Item $tmp, $extract -Recurse -Force -ErrorAction SilentlyContinue
    return $dest
}

function Expand-ZstdFile {
    param([string]$Source, [string]$Destination)
    $zstd = Get-ZstdExe
    & $zstd -d -f -o $Destination $Source | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "zstd 解压失败: $Source" }
}

# ---------- 模块 6: native 安装 ---------------------------------------------
function Install-Native {
    param([Parameter(Mandatory)] $Tool, [string]$Channel = 'latest', [string]$Scope = 'User')

    $platform = Get-PlatformId
    Write-Host "[$($Tool.DisplayName)] 平台 $platform, channel $Channel"

    # 1. 用 channel 文件 URL 测速选最快代理
    $candidates = $script:GitHubProxies | ForEach-Object {
        $entry = $_.Clone()
        $entry.Probe = Get-ChannelUrl $Tool $Channel $_.Proxy
        $entry
    }
    $fastest = Measure-Mirror -Candidates $candidates -ProbeUrlKey 'Probe'
    $ordered = @($fastest) + ($script:GitHubProxies | Where-Object { $_.Name -ne $fastest.Name })

    # 2. 取版本号（带 fallback，最快代理偶发抽风也能恢复）
    $r = Invoke-FetchTextWithFallback `
        -UrlBuilder { param($pr) Get-ChannelUrl $Tool $Channel $pr.Proxy } `
        -Proxies $ordered
    $version = $r.Content.Trim()
    if (-not $version) { throw "channel '$Channel' 返回空版本号" }
    Write-Host "  版本: $version"

    # 3. 取 manifest（同 fallback）
    $r = Invoke-FetchTextWithFallback `
        -UrlBuilder { param($pr) Get-ManifestUrl $Tool $version $pr.Proxy } `
        -Proxies $ordered
    $manifest = $r.Content | ConvertFrom-Json
    $entry = $manifest.platforms.$platform
    if (-not $entry) { throw "manifest 不包含平台 $platform（可用: $($manifest.platforms.PSObject.Properties.Name -join ', ')）" }

    # 4. 下载 asset
    $assetName = "$platform-$($entry.binary)"
    $staged = Get-StagingPath "$($Tool.Repo)-$version-$assetName"
    Invoke-DownloadWithFallback `
        -UrlBuilder { param($pr) Get-AssetUrl $Tool $version $assetName $pr.Proxy } `
        -Dest $staged `
        -Proxies $ordered

    # 5. SHA256
    Test-Sha256 -File $staged -Expected $entry.checksum

    # 6. 落位
    if (-not (Test-Path $Tool.LauncherDir)) {
        New-Item -ItemType Directory -Path $Tool.LauncherDir -Force | Out-Null
    }

    if ($Tool.SelfInstall) {
        # 下载下来的就是可执行文件，跑 `<binary> install <channel>` 自落位
        & $staged install $Channel
        if ($LASTEXITCODE -ne 0) { throw "self-install 退出码 $LASTEXITCODE" }
    } else {
        # zstd 压缩，解压到 LauncherDir
        $runtimeName = if ($entry.PSObject.Properties['runtime_binary'] -and $entry.runtime_binary) {
            $entry.runtime_binary
        } else { $entry.binary }
        $finalPath = Join-Path $Tool.LauncherDir $runtimeName
        Expand-ZstdFile -Source $staged -Destination $finalPath
        Write-Host "  解压到 $finalPath"
    }

    Remove-Item $staged -Force -ErrorAction SilentlyContinue
    Add-ToPath -Dir $Tool.LauncherDir -Scope $Scope
    Write-Host "$($Tool.DisplayName) $version 安装完成"
}

# ---------- 模块 7: npm 安装 ------------------------------------------------
function Install-Npm {
    param([Parameter(Mandatory)] $Tool)

    if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
        throw 'npm 不可用，请先安装 Node.js（建议 LTS）'
    }
    $major = Get-NodeMajor
    if ($null -ne $major -and $major -lt $Tool.NpmMinNode) {
        throw "$($Tool.DisplayName) 需要 Node.js $($Tool.NpmMinNode)+，当前 v$major"
    }

    # 测 registry 选最快
    $reg = Measure-Mirror -Candidates $script:NpmRegistries -ProbeUrlKey 'Url'

    Write-Host "[$($Tool.DisplayName)] npm i -g $($Tool.NpmPackage) --registry=$($reg.Url)"
    & npm install -g $Tool.NpmPackage --registry=$reg.Url
    if ($LASTEXITCODE -ne 0) { throw "npm install 退出码 $LASTEXITCODE" }
    Write-Host "$($Tool.DisplayName) 通过 npm 安装完成"
}

# ---------- 入口 ------------------------------------------------------------
function Resolve-Method {
    param([string]$Name, [string]$Requested, $Env)
    $meta = $script:Tools[$Name]
    switch ($Requested) {
        'native' { return 'native' }
        'npm' {
            if (-not $meta.NpmPackage) { throw "$Name 没有 npm 包" }
            if (-not $Env.HasNpm) { throw 'npm 不可用，请先安装 Node.js' }
            return 'npm'
        }
        'auto' { return 'native' }   # native 默认，zstd 缺失会自动按需下载
    }
}

function Invoke-Main {
    $envInfo = Test-Environment
    $target = if ($Tool) { $Tool } else { Show-Menu -Env $envInfo }
    if (-not $script:Tools.Contains($target)) {
        throw "未知工具: $target（支持: $($script:Tools.Keys -join ', ')）"
    }

    $resolved = Resolve-Method -Name $target -Requested $Method -Env $envInfo
    $meta = $script:Tools[$target]

    switch ($resolved) {
        'native' { Install-Native -Tool $meta -Channel $Channel -Scope $PathScope }
        'npm'    { Install-Npm    -Tool $meta }
    }
}

Invoke-Main
