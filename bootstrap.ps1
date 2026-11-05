#requires -Version 5.1
<#
.SYNOPSIS
    在任意 Windows 机器上重建 DSH 论文阅读环境（六个插件 + 配置 + MinerU 云端后端）。

.DESCRIPTION
    做的事：装包 → 把包装进 profile 的 dsh.profile.bundles → 合并 MinerU 的 cordis patch
    →（可选）写论文伴读自己的 mineru.json。全程可重复执行，已完成的步骤会跳过。

    不做的事：不改论文库、不碰别的插件、不把 token 写进会被 git 跟踪的地方。

.PARAMETER Profile
    DSH profile 名。桌面端是 desktop；Linux / 纯 Web 宿主通常叫 web。

.PARAMETER DshHome
    DSH 的 home，默认 ~/.dsh。

.PARAMETER MineruToken
    mineru.net 的 API Token（sk- 开头）。给了才会写论文伴读的 mineru.json。

.PARAMETER VerifyOnly
    只检查现状，不安装、不写文件。

.PARAMETER ForceCopyConfig
    即使 cordis.patch.yml 里已有 dsh-pdf-mineru 段，也再追加一次（一般不需要）。

.EXAMPLE
    .\bootstrap.ps1 -MineruToken "sk-xxx"
.EXAMPLE
    .\bootstrap.ps1 -Profile web -VerifyOnly
#>
[CmdletBinding()]
param(
    [string]$Profile = 'desktop',
    [string]$DshHome = (Join-Path $env:USERPROFILE '.dsh'),
    [string]$MineruToken = '',
    [switch]$VerifyOnly,
    [switch]$ForceCopyConfig,
    [switch]$InstallBabeldoc
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Plugins = @(
    '@ggboy123/dsh-paper-reader',
    'dsh-pdf-mineru',
    'dsh-paper-search',
    'dsh-free-search',
    'dsh-deepread',
    'dsh-pdf-reader'
)
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Read-Utf8 { param([string]$Path) [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) }
function Write-Step($text) { Write-Host "`n== $text" -ForegroundColor Cyan }
function Write-Ok($text) { Write-Host "   [+] $text" -ForegroundColor Green }
function Write-Skip($text) { Write-Host "   [=] $text" -ForegroundColor DarkGray }
function Write-Warn2($text) { Write-Host "   [!] $text" -ForegroundColor Yellow }

# 找到 DSH 自带的 node 和 pnpm。桌面端的运行时在安装目录下，不依赖 PATH。
function Find-Toolchain {
    $roots = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\DSH NEXT\resources\runtime'),
        (Join-Path $env:LOCALAPPDATA 'Programs\DSH\resources\runtime'),
        'C:\Program Files\DSH NEXT\resources\runtime',
        'C:\Program Files (x86)\DSH NEXT\resources\runtime',
        (Join-Path $env:ProgramFiles 'DSH NEXT\resources\runtime')
    )
    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }
        $dep = Get-ChildItem $root -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName 'primary-runtime\dependencies' } |
            Where-Object { Test-Path (Join-Path $_ 'node\bin\node.exe') } |
            Select-Object -First 1
        if ($dep) {
            return [pscustomobject]@{
                Node = Join-Path $dep 'node\bin\node.exe'
                Pnpm = Join-Path $dep 'pnpm\bin\pnpm.cjs'
                Source = "bundled ($dep)"
            }
        }
    }
    $node = (Get-Command node -ErrorAction SilentlyContinue).Source
    $pnpm = (Get-Command pnpm -ErrorAction SilentlyContinue).Source
    if ($node -and $pnpm) {
        return [pscustomobject]@{ Node = $node; Pnpm = $pnpm; Source = 'PATH' }
    }
    throw "找不到 node/pnpm：既没有 DSH 运行时，PATH 里也没有。请先安装 DeepSeek Harness 桌面端，或自行安装 Node 22+ 与 pnpm。"
}

# 用 node 改 package.json：把缺的包补进 bundles。避免 PowerShell 手改 JSON 出 BOM/转义问题。
function Update-ManifestBundles {
    param([string]$ManifestPath, [string[]]$Names)
    $js = @'
const fs = require('fs');
const [file, ...want] = process.argv.slice(2);
const m = JSON.parse(fs.readFileSync(file, 'utf8'));
m.dsh = m.dsh || {};
m.dsh.profile = m.dsh.profile || {};
const bundles = Array.isArray(m.dsh.profile.bundles) ? m.dsh.profile.bundles : [];
const added = [];
for (const name of want) {
  if (!bundles.includes(name)) { bundles.push(name); added.push(name); }
}
m.dsh.profile.bundles = bundles;
fs.writeFileSync(file, JSON.stringify(m, null, 2) + '\n', 'utf8');
console.log(added.join(','));
'@
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("dsh-bundles-" + [guid]::NewGuid().ToString('N') + ".cjs")
    [System.IO.File]::WriteAllText($tmp, $js, $Utf8NoBom)
    try {
        $added = & $script:Node $tmp $ManifestPath @Names
        return ($added -split ',' | Where-Object { $_ })
    }
    finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
}

# ---------- 前置检查 ----------
$profileDir = Join-Path $DshHome "profiles\$Profile"
if (-not (Test-Path (Join-Path $profileDir 'package.json'))) {
    throw "找不到 profile：$profileDir`n先启动一次 DSH（让 profile 生成），或用 -Profile 指定正确的名字。"
}
$tc = Find-Toolchain
$script:Node = $tc.Node
$manifest = Join-Path $profileDir 'package.json'
$patchFile = Join-Path $profileDir 'cordis.patch.yml'

Write-Step "环境"
Write-Ok "DSH home : $DshHome"
Write-Ok "profile  : $Profile"
Write-Ok "toolchain: $($tc.Source)"

# ---------- 检查已装情况 ----------
$nodeModules = Join-Path $profileDir 'node_modules'
$present = @{}
foreach ($p in $Plugins) {
    $pkg = Join-Path $nodeModules "$p\package.json"
    if (Test-Path $pkg) {
        $v = ((Read-Utf8 $pkg) | ConvertFrom-Json).version
        $present[$p] = $v
    }
}

Write-Step "插件状态"
foreach ($p in $Plugins) {
    if ($present.ContainsKey($p)) { Write-Ok "$p $($present[$p])" } else { Write-Warn2 "$p 未安装" }
}

if ($VerifyOnly) {
    Write-Step "配置检查"
    if (Test-Path $patchFile) {
        $txt = Read-Utf8 $patchFile
        if ($txt -match 'activeProvider:\s*mp_official') { Write-Ok 'cordis.patch.yml 已指向 MinerU 云端' }
        else { Write-Warn2 'cordis.patch.yml 里没有 MinerU 云端覆盖' }
    }
    $mineruJson = Join-Path $DshHome '.dsh-paper-reader\mineru.json'
    if (Test-Path $mineruJson) {
        $mj = (Read-Utf8 $mineruJson) | ConvertFrom-Json
        Write-Ok "论文伴读 MinerU 模式：$($mj.mode)"
        if (-not $mj.cloud.apiKey) { Write-Warn2 '论文伴读的 MinerU 没有 key' }
    }
    else { Write-Warn2 '论文伴读没有 mineru.json（阅读器里的 MinerU 不可用）' }
    $data = Join-Path $env:USERPROFILE '.dsh-paper-reader\data'
    if (Test-Path $data) {
        $n = (Get-ChildItem $data -Recurse -File -Filter *.pdf -ErrorAction SilentlyContinue).Count
        $t = (Get-ChildItem $data -Directory -ErrorAction SilentlyContinue).Count
        Write-Ok "论文库：$t 个专题 / $n 篇 PDF（$data）"
    }
    else { Write-Warn2 '论文库为空或还没有创建' }
    return
}

# ---------- 安装缺失的包 ----------
$missing = $Plugins | Where-Object { -not $present.ContainsKey($_) }
if ($missing.Count -gt 0) {
    Write-Step "安装 $($missing.Count) 个包"
    $backup = "$manifest.bak-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
    Copy-Item $manifest $backup -Force
    Write-Ok "已备份清单：$(Split-Path -Leaf $backup)"

    & $script:Node $tc.Pnpm --dir $profileDir add @missing
    if ($LASTEXITCODE -ne 0) { throw "pnpm add 失败（退出码 $LASTEXITCODE）" }
    Write-Ok '安装完成'
}
else {
    Write-Step '安装'
    Write-Skip '六个包都在，跳过安装'
}

# ---------- 补 bundles ----------
Write-Step '登记到 dsh.profile.bundles'
$added = Update-ManifestBundles -ManifestPath $manifest -Names $Plugins
if ($added.Count -gt 0) { Write-Ok "新增：$($added -join ', ')" } else { Write-Skip 'bundles 已齐全' }

# ---------- 合并 MinerU patch ----------
Write-Step 'MinerU provider 配置'
$haveBlock = (Test-Path $patchFile) -and ((Read-Utf8 $patchFile) -match 'id:\s*dsh-pdf-mineru')
if ($haveBlock -and -not $ForceCopyConfig) {
    Write-Skip 'cordis.patch.yml 里已有 dsh-pdf-mineru 段'
}
else {
    $snippet = Join-Path $ScriptDir 'cordis.patch.snippet.yml'
    if (-not (Test-Path $snippet)) { throw "缺少 $snippet" }
    Copy-Item $patchFile ($patchFile + '.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss')) -Force -ErrorAction SilentlyContinue
    $body = "`n" + (Read-Utf8 $snippet)
    [System.IO.File]::AppendAllText($patchFile, $body, $Utf8NoBom)
    Write-Ok '已追加云端 provider 段（保留了两个自部署 provider，方便以后切回）'
}

# ---------- 论文伴读的 MinerU 后端 ----------
Write-Step '论文伴读的 MinerU 后端'
$mineruJson = Join-Path $DshHome '.dsh-paper-reader\mineru.json'
if (-not $MineruToken) {
    Write-Warn2 '没给 -MineruToken，跳过。之后也可在 设置 → 论文伴读 → MinerU 解析后端 里填。'
}
else {
    New-Item -ItemType Directory -Path (Split-Path $mineruJson) -Force | Out-Null
    $cfg = [ordered]@{
        mode  = 'cloud'
        cloud = [ordered]@{
            baseUrl      = 'https://mineru.net/api/v4'
            apiKey       = $MineruToken
            modelVersion = 'pipeline'
        }
    } | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($mineruJson, $cfg, $Utf8NoBom)
    Write-Ok "写入 $mineruJson"
    Write-Warn2 'dsh-pdf-mineru 插件读的是凭据服务里的 MINERU_API_KEY，与这里不是同一份 —— 见 README 的“换机器还差什么”。'
}

# ---------- 翻译引擎（babeldoc）环境修复 ----------
Write-Step '翻译引擎环境'
$venvDir = Join-Path $env:USERPROFILE '.dsh-paper-reader\.venv-pdf2zh'
$fixScript = Join-Path $ScriptDir 'tools\apply-babeldoc-env-fix.ps1'
$installScript = Join-Path $ScriptDir 'tools\install-babeldoc.ps1'

if ($InstallBabeldoc -and -not (Test-Path (Join-Path $venvDir 'Scripts\babeldoc.exe'))) {
    if (Test-Path $installScript) {
        try {
            & $installScript -VenvDir $venvDir
        }
        catch {
            Write-Warn2 "引擎安装失败：$($_.Exception.Message)（可稍后单独跑 tools\install-babeldoc.ps1）"
        }
    }
    else {
        Write-Warn2 "缺少 $installScript"
    }
}

if (Test-Path (Join-Path $venvDir 'Lib\site-packages')) {
    if (Test-Path $fixScript) {
        try {
            & $fixScript -VenvDir $venvDir | Out-Null
            Write-Ok '已写入 sitecustomize（修掉 NO_PROXY 里 [::1] 导致的 httpx 崩溃）'
        }
        catch {
            Write-Warn2 "修复脚本失败：$($_.Exception.Message)"
        }
    }
    else {
        Write-Warn2 "缺少 $fixScript"
    }
}
else {
    Write-Warn2 '还没有翻译引擎 venv（首次点「中」才会创建）——之后运行 tools\apply-babeldoc-env-fix.ps1'
}

# ---------- git 钩子：防止把密钥提交进仓库 ----------
Write-Step 'git 钩子'
$hookScript = Join-Path $ScriptDir 'tools\install-git-hooks.ps1'
if (Test-Path (Join-Path $ScriptDir '.git')) {
    if (Test-Path $hookScript) {
        try {
            & $hookScript -RepoRoot $ScriptDir | Out-Null
            Write-Ok 'pre-commit 已安装（提交前拦明文密钥）'
        }
        catch {
            Write-Warn2 "钩子安装失败：$($_.Exception.Message)"
        }
    }
    else {
        Write-Warn2 "缺少 $hookScript"
    }
}
else {
    Write-Skip '本目录不是 git 仓库，跳过钩子'
}

Write-Step '完成'
Write-Host @"
下一步：
  1. 重启 DSH（让它重新组合 profile）：完全退出后重新打开
  2. 侧栏出现「📚 论文伴读」即正常
  3. 论文库：把 PDF 放进 ~/.dsh-paper-reader/data/<专题>/ 或在界面里上传
  4. 详细流程见本目录 paper-workflow.md
  5. 遇到怪问题先查 docs/troubleshooting.md
"@ -ForegroundColor Gray
