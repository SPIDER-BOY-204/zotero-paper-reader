#requires -Version 5.1
<#
.SYNOPSIS
    把 tools\git-hooks\ 下的钩子装进本仓库的 .git\hooks\。

.DESCRIPTION
    pre-commit 会在提交前扫暂存区，发现明文密钥（sk-…、ghp_…、私钥块、JWT 等）就拒绝提交。
    钩子文件不入库（.git 本来就不入库），所以换机器后要重跑一次 —— bootstrap.ps1 会自动做。

.EXAMPLE
    .\install-git-hooks.ps1
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = ''
)

if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }

$ErrorActionPreference = 'Stop'
$src = Join-Path $RepoRoot 'tools\git-hooks'
$dst = Join-Path $RepoRoot '.git\hooks'

if (-not (Test-Path $src)) { throw "找不到钩子源目录：$src" }
if (-not (Test-Path $dst)) { throw "这不是个 git 仓库（缺 .git\hooks）：$RepoRoot" }

Get-ChildItem $src -File | ForEach-Object {
    $target = Join-Path $dst $_.Name
    # 钩子必须是 LF 结尾、无 BOM，否则 sh 会报 bad interpreter
    $text = [System.IO.File]::ReadAllText($_.FullName, [System.Text.Encoding]::UTF8)
    $text = $text -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText($target, $text, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "[+] $($_.Name) -> .git\hooks\" -ForegroundColor Green
}

# 验证 git 认这个钩子
$probe = & git -C $RepoRoot config core.hooksPath 2>$null
if ($probe) { Write-Host "[!] core.hooksPath 被设成了 $probe，钩子从那里读，不是 .git\hooks" -ForegroundColor Yellow }
Write-Host '    测试：echo 假装 > _secret_test; git add _secret_test; git commit -m t  → 应当被拒'
