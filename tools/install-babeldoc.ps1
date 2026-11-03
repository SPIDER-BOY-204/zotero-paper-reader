#requires -Version 5.1
<#
.SYNOPSIS
    直接装好论文伴读的翻译引擎（babeldoc），绕开插件里那个会超时的 GitHub 下载。

.DESCRIPTION
    插件原本的流程是：下载 uv（api.github.com，国内常超时）→ uv venv → uv pip install babeldoc。
    这里跳过 uv，用系统 Python 建 venv，再从 PyPI 镜像装：
      babeldoc==0.6.4（插件实测过的版本） + bitstring<5（5.0 删了 BitStream）

    装完建议接 tools\apply-babeldoc-env-fix.ps1（bootstrap.ps1 会自动做）。

.PARAMETER Python
    用哪个 Python 建 venv。默认取 PATH 上的 python。
.PARAMETER Mirror
    PyPI 镜像。默认清华；失败时自动再试官方源。
.EXAMPLE
    .\install-babeldoc.ps1
#>
[CmdletBinding()]
param(
    [string]$Python = '',
    [string]$Mirror = 'https://pypi.tuna.tsinghua.edu.cn/simple',
    [string]$VenvDir = (Join-Path $env:USERPROFILE '.dsh-paper-reader\.venv-pdf2zh')
)

$ErrorActionPreference = 'Stop'

if (-not $Python) {
    $cmd = Get-Command python -ErrorAction SilentlyContinue
    if (-not $cmd) { throw 'PATH 里没有 python。装一个 3.10+ 再来，或用 -Python 指定绝对路径。' }
    $Python = $cmd.Source
}
Write-Host "[*] python: $Python"

$vpy = Join-Path $VenvDir 'Scripts\python.exe'
if (-not (Test-Path $vpy)) {
    & $Python -m venv $VenvDir
    if ($LASTEXITCODE -ne 0) { throw '创建 venv 失败' }
    Write-Host "[+] venv: $VenvDir" -ForegroundColor Green
}
else {
    Write-Host "[=] venv 已存在，直接补依赖"
}

$pkgs = @('babeldoc==0.6.4', 'bitstring<5')
& $vpy -m pip install --disable-pip-version-check -q --upgrade pip -i $Mirror 2>&1 | Out-Null

Write-Host '[*] 安装 babeldoc（约 700MB，几分钟）…'
& $vpy -m pip install --disable-pip-version-check -i $Mirror @pkgs
if ($LASTEXITCODE -ne 0) {
    Write-Host '[!] 镜像失败，改用官方源重试' -ForegroundColor Yellow
    & $vpy -m pip install --disable-pip-version-check --no-cache-dir @pkgs
    if ($LASTEXITCODE -ne 0) { throw 'babeldoc 安装失败' }
}

$bin = Join-Path $VenvDir 'Scripts\babeldoc.exe'
if (-not (Test-Path $bin)) { throw "装完没有 babeldoc.exe：$bin" }
$ver = & $bin --version
Write-Host "[+] 完成：$ver" -ForegroundColor Green
Write-Host '    下一步：tools\apply-babeldoc-env-fix.ps1（bootstrap 会自动跑）'
