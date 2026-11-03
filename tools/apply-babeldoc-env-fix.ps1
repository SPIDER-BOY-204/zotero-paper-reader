#requires -Version 5.1
<#
.SYNOPSIS
    修掉 babeldoc 启动即崩的 InvalidURL(':1]')：往翻译引擎 venv 里装 sitecustomize。

.DESCRIPTION
    DSH 会把 NO_PROXY 写成 "...::1,[::1]"（为 undici 的匹配器服务），
    Python 的 httpx 解析 [::1] 时抛 InvalidURL。这个脚本在 venv 的
    site-packages 放一个 sitecustomize.py，解释器启动时先清理环境变量。

    什么时候需要再跑一次：
      - 删掉/重建了 ~/.dsh-paper-reader/.venv-pdf2zh（插件重新安装引擎）
    升级 httpx、升级 DSH 都不需要重跑。

.EXAMPLE
    .\apply-babeldoc-env-fix.ps1
#>
[CmdletBinding()]
param(
    [string]$VenvDir = (Join-Path $env:USERPROFILE '.dsh-paper-reader\.venv-pdf2zh')
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$src = Join-Path $here 'sitecustomize.py'

$site = Join-Path $VenvDir 'Lib\site-packages'
if (-not (Test-Path $site)) {
    throw "找不到 venv 的 site-packages：$site`n先让论文伴读装好翻译引擎（或确认 -VenvDir）。"
}
if (-not (Test-Path $src)) { throw "缺少 $src" }

Copy-Item $src (Join-Path $site 'sitecustomize.py') -Force
Write-Host "[+] 已写入 $(Join-Path $site 'sitecustomize.py')" -ForegroundColor Green

$vpy = Join-Path $VenvDir 'Scripts\python.exe'
if (Test-Path $vpy) {
    $out = & $vpy -c "import os,httpx; print('NO_PROXY =', os.environ.get('NO_PROXY')); httpx.Client(timeout=5).close(); print('httpx OK')" 2>&1
    $out | ForEach-Object { Write-Host "    $_" }
    if ($LASTEXITCODE -ne 0) { throw '自检失败：httpx 仍然报错' }
    Write-Host '[+] 自检通过' -ForegroundColor Green
}
