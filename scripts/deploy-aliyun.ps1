<#
.SYNOPSIS
    构建 simpleweb 并部署到阿里云服务器（Nginx 由 Docker 容器提供）。

.DESCRIPTION
    服务器上的 nginx-kunkundy 容器把主机 /var/www/kunkundy 以只读方式挂载为站点根目录，
    因此只需替换该目录内容，再让容器 reload 即可，不需要重建镜像或重启容器。
    流程：本地 pnpm build -> tar 打包 -> scp 上传 -> 解压到站点目录 -> docker exec nginx -s reload。
    旧版本会打包备份到服务器 /tmp/kunkundy-backup.tar.gz。

.PARAMETER ServerIp
    服务器公网 IP，默认 43.103.4.129。

.PARAMETER User
    SSH 登录用户，默认 admin（需具备 sudo 与 docker 权限）。

.PARAMETER SshPort
    SSH 端口，默认 22。

.PARAMETER RemotePath
    服务器上的站点根目录（容器挂载的目录），默认 /var/www/kunkundy。

.PARAMETER ContainerName
    Nginx 容器名，默认 nginx-kunkundy。

.PARAMETER SkipBuild
    跳过构建，直接上传 simpleweb/dist 里已有的产物。

.EXAMPLE
    .\scripts\deploy-aliyun.ps1
#>
param(
    [string]$ServerIp = "43.103.4.129",
    [string]$User = "admin",
    [int]$SshPort = 22,
    [string]$RemotePath = "/var/www/kunkundy",
    [string]$ContainerName = "nginx-kunkundy",
    [switch]$SkipBuild
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$simplewebDir = Join-Path $repoRoot "simpleweb"
$distDir = Join-Path $simplewebDir "dist"
$target = "$User@$ServerIp"
$archiveLocal = Join-Path $env:TEMP "kunkundy-dist.tar.gz"
$archiveRemote = "/tmp/kunkundy-dist.tar.gz"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Assert-Command([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "缺少命令：$Name"
    }
}

function New-RemoteShell([string]$Content, [string]$FileName) {
    # 服务器是 Linux，必须 LF 换行；用 UTF-8 无 BOM 写出，避免 bash 报错
    $path = Join-Path $env:TEMP $FileName
    $text = ($Content -replace "`r`n", "`n") `
        -replace "__REMOTE_PATH__", $RemotePath `
        -replace "__CONTAINER__", $ContainerName
    [IO.File]::WriteAllText($path, $text, $utf8NoBom)
    return $path
}

function Invoke-Remote([string]$LocalScript) {
    $remotePath = "/tmp/" + (Split-Path -Leaf $LocalScript)
    scp -P $SshPort -o StrictHostKeyChecking=accept-new $LocalScript "${target}:$remotePath"
    if ($LASTEXITCODE -ne 0) { throw "上传脚本到服务器失败：$LocalScript" }

    ssh -p $SshPort -o StrictHostKeyChecking=accept-new $target "bash $remotePath"
    if ($LASTEXITCODE -ne 0) { throw "远程脚本执行失败：$LocalScript" }
}

Assert-Command pnpm
Assert-Command ssh
Assert-Command scp
Assert-Command tar

# ---------- 1. 构建 ----------
if ($SkipBuild) {
    Write-Host "[1/4] 跳过构建，使用现有 dist" -ForegroundColor Cyan
    if (-not (Test-Path (Join-Path $distDir "index.html"))) {
        throw "simpleweb/dist 不存在或不完整，请去掉 -SkipBuild 重新构建"
    }
}
else {
    Write-Host "[1/4] 构建 simpleweb（base=/，用于根路径部署）" -ForegroundColor Cyan
    if (Test-Path $distDir) { Remove-Item $distDir -Recurse -Force }
    $env:VITE_BASE_PATH = "/"
    pnpm -C $simplewebDir build
    if ($LASTEXITCODE -ne 0) { throw "构建失败（pnpm exit $LASTEXITCODE）" }
    if (-not (Test-Path (Join-Path $distDir "index.html"))) {
        throw "构建完成后未找到 simpleweb/dist/index.html"
    }
}

# ---------- 2. 打包 ----------
Write-Host "[2/4] 打包构建产物" -ForegroundColor Cyan
if (Test-Path $archiveLocal) { Remove-Item $archiveLocal -Force }
tar -czf $archiveLocal -C $distDir .
if ($LASTEXITCODE -ne 0) { throw "打包失败" }
$sizeKb = [math]::Round((Get-Item $archiveLocal).Length / 1KB, 1)
Write-Host "    包大小：$sizeKb KB"

# ---------- 3. 上传 ----------
Write-Host "[3/4] 上传到 $target" -ForegroundColor Cyan
scp -P $SshPort -o StrictHostKeyChecking=accept-new $archiveLocal "${target}:$archiveRemote"
if ($LASTEXITCODE -ne 0) { throw "上传失败，请检查网络、IP、SSH 端口与登录凭据" }

# ---------- 4. 服务器解压并重载 Nginx 容器 ----------
Write-Host "[4/4] 服务器解压并重载 Nginx 容器" -ForegroundColor Cyan
$deploy = @'
set -euo pipefail

REMOTE_PATH="__REMOTE_PATH__"
ARCHIVE="/tmp/kunkundy-dist.tar.gz"
CONTAINER="__CONTAINER__"

SUDO=""
if [ "$(id -u)" -ne 0 ]; then SUDO="sudo"; fi

# 旧版本打包备份到 /tmp，便于回滚
rm -f /tmp/kunkundy-backup.tar.gz
if [ -d "$REMOTE_PATH" ] && [ -n "$(ls -A "$REMOTE_PATH" 2>/dev/null || true)" ]; then
    tar -czf /tmp/kunkundy-backup.tar.gz -C "$REMOTE_PATH" .
fi

# 清空站点目录内容（目录本身保持不变，容器的挂载点不动）
sudo mkdir -p "$REMOTE_PATH"
sudo find "$REMOTE_PATH" -mindepth 1 -delete
sudo tar -xzf "$ARCHIVE" -C "$REMOTE_PATH"
sudo chown -R www-data:www-data "$REMOTE_PATH"
sudo chmod -R u=rwX,go=rX "$REMOTE_PATH"

if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    docker exec "$CONTAINER" nginx -s reload
    echo "已重载容器 $CONTAINER"
else
    echo "警告：未找到运行中的容器 $CONTAINER，文件已就位但未重载 Nginx"
fi

HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/ || echo "000")
echo "本机自检 HTTP 状态码：$HTTP_CODE"

rm -f "$ARCHIVE" "$0"
echo "已部署到 $REMOTE_PATH"
'@
Invoke-Remote (New-RemoteShell $deploy "kunkundy-deploy.sh")

if (Test-Path $archiveLocal) { Remove-Item $archiveLocal -Force }

Write-Host ""
Write-Host "部署完成：http://$ServerIp/" -ForegroundColor Green
Write-Host "如果打不开，检查阿里云安全组是否放行 80 端口（入方向 TCP 80）。" -ForegroundColor Yellow
