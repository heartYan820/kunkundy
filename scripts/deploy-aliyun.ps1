<#
.SYNOPSIS
    构建 simpleweb 并部署到阿里云 Ubuntu 服务器（Nginx 静态托管）。

.DESCRIPTION
    流程：本地 pnpm build -> tar 打包 dist -> scp 上传 -> ssh 解压到站点目录 -> 重载 Nginx。
    旧版本会被移到 <站点目录>.bak，出问题可手动回滚。
    非 root 用户（如 admin）需要 sudo 权限，远端执行时会提示输入 sudo 密码。

.PARAMETER ServerIp
    服务器公网 IP，默认 43.103.4.129。

.PARAMETER User
    SSH 登录用户，默认 admin。

.PARAMETER SshPort
    SSH 端口，默认 22。

.PARAMETER RemotePath
    服务器上的站点根目录，默认 /var/www/kunkundy。

.PARAMETER SetupNginx
    首次部署时加上：安装 Nginx（已装则跳过）、写入站点配置、删除默认站点、启动服务。
    只需执行一次，之后发版不要再带这个参数。

.PARAMETER SkipBuild
    跳过构建，直接上传 simpleweb/dist 里已有的产物。

.EXAMPLE
    # 第一次（配置 Nginx + 上传）
    .\scripts\deploy-aliyun.ps1 -SetupNginx

.EXAMPLE
    # 之后每次发版
    .\scripts\deploy-aliyun.ps1
#>
param(
    [string]$ServerIp = "43.103.4.129",
    [string]$User = "admin",
    [int]$SshPort = 22,
    [string]$RemotePath = "/var/www/kunkundy",
    [switch]$SetupNginx,
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
    $text = ($Content -replace "`r`n", "`n") -replace "__REMOTE_PATH__", $RemotePath
    [IO.File]::WriteAllText($path, $text, $utf8NoBom)
    return $path
}

function Invoke-Remote([string]$LocalScript) {
    $remotePath = "/tmp/" + (Split-Path -Leaf $LocalScript)
    scp -P $SshPort -o StrictHostKeyChecking=accept-new $LocalScript "${target}:$remotePath"
    if ($LASTEXITCODE -ne 0) { throw "上传脚本到服务器失败：$LocalScript" }

    # -t 分配伪终端：非 root 用户执行 sudo 时才能交互输入密码
    ssh -t -p $SshPort -o StrictHostKeyChecking=accept-new $target "bash $remotePath"
    if ($LASTEXITCODE -ne 0) { throw "远程脚本执行失败：$LocalScript" }
}

Assert-Command pnpm
Assert-Command ssh
Assert-Command scp
Assert-Command tar

# ---------- 1. 构建 ----------
if ($SkipBuild) {
    Write-Host "[1/5] 跳过构建，使用现有 dist" -ForegroundColor Cyan
    if (-not (Test-Path (Join-Path $distDir "index.html"))) {
        throw "simpleweb/dist 不存在或不完整，请去掉 -SkipBuild 重新构建"
    }
}
else {
    Write-Host "[1/5] 构建 simpleweb（base=/，用于根路径部署）" -ForegroundColor Cyan
    if (Test-Path $distDir) { Remove-Item $distDir -Recurse -Force }
    $env:VITE_BASE_PATH = "/"
    pnpm -C $simplewebDir build
    if ($LASTEXITCODE -ne 0) { throw "构建失败（pnpm exit $LASTEXITCODE）" }
    if (-not (Test-Path (Join-Path $distDir "index.html"))) {
        throw "构建完成后未找到 simpleweb/dist/index.html"
    }
}

# ---------- 2. 打包 ----------
Write-Host "[2/5] 打包构建产物" -ForegroundColor Cyan
if (Test-Path $archiveLocal) { Remove-Item $archiveLocal -Force }
tar -czf $archiveLocal -C $distDir .
if ($LASTEXITCODE -ne 0) { throw "打包失败" }
$sizeKb = [math]::Round((Get-Item $archiveLocal).Length / 1KB, 1)
Write-Host "    包大小：$sizeKb KB"

# ---------- 3. 首次初始化 Nginx ----------
if ($SetupNginx) {
    Write-Host "[3/5] 初始化服务器：配置 Nginx 站点" -ForegroundColor Cyan
    $setup = @'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

SUDO=""
if [ "$(id -u)" -ne 0 ]; then SUDO="sudo"; fi

$SUDO apt-get update
$SUDO apt-get install -y nginx

$SUDO tee /etc/nginx/sites-available/kunkundy >/dev/null <<'NGINX_CONF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    root __REMOTE_PATH__;
    index index.html;

    charset utf-8;

    gzip on;
    gzip_comp_level 5;
    gzip_min_length 1024;
    gzip_types text/plain text/css application/javascript application/json image/svg+xml font/woff2;

    # 带 hash 的静态资源长缓存
    location /assets/ {
        expires 30d;
        add_header Cache-Control "public, immutable";
    }

    # 入口文件不缓存，保证发版后立即生效
    location = /index.html {
        add_header Cache-Control "no-cache";
    }

    # hash 路由本身不需要 fallback，这里兜底刷新/直接访问
    location / {
        try_files $uri $uri/ /index.html;
    }
}
NGINX_CONF

$SUDO ln -sf /etc/nginx/sites-available/kunkundy /etc/nginx/sites-enabled/kunkundy
$SUDO rm -f /etc/nginx/sites-enabled/default
$SUDO nginx -t
$SUDO systemctl enable nginx
$SUDO systemctl restart nginx
echo "nginx 已就绪"
'@
    Invoke-Remote (New-RemoteShell $setup "kunkundy-setup.sh")
}
else {
    Write-Host "[3/5] 跳过 Nginx 初始化（首次部署请加 -SetupNginx）" -ForegroundColor DarkGray
}

# ---------- 4. 上传 ----------
Write-Host "[4/5] 上传到 $target" -ForegroundColor Cyan
scp -P $SshPort -o StrictHostKeyChecking=accept-new $archiveLocal "${target}:$archiveRemote"
if ($LASTEXITCODE -ne 0) { throw "上传失败，请检查网络、IP、SSH 端口与登录凭据" }

# ---------- 5. 服务器解压并生效 ----------
Write-Host "[5/5] 服务器解压并重载 Nginx" -ForegroundColor Cyan
$deploy = @'
set -euo pipefail

REMOTE_PATH="__REMOTE_PATH__"
ARCHIVE="/tmp/kunkundy-dist.tar.gz"

SUDO=""
if [ "$(id -u)" -ne 0 ]; then SUDO="sudo"; fi

# 备份旧版本，便于回滚
if [ -d "$REMOTE_PATH" ] && [ -n "$(ls -A "$REMOTE_PATH" 2>/dev/null || true)" ]; then
    $SUDO rm -rf "${REMOTE_PATH}.bak"
    $SUDO mv "$REMOTE_PATH" "${REMOTE_PATH}.bak"
fi

$SUDO mkdir -p "$REMOTE_PATH"
$SUDO tar -xzf "$ARCHIVE" -C "$REMOTE_PATH"
$SUDO chown -R www-data:www-data "$REMOTE_PATH"

if command -v nginx >/dev/null 2>&1; then
    $SUDO nginx -t
    $SUDO systemctl reload nginx
    echo "nginx 已重载"
else
    echo "警告：服务器未安装 nginx，文件已就位但没有对外服务"
fi

rm -f "$ARCHIVE" "$0"
echo "已部署到 $REMOTE_PATH"
'@
Invoke-Remote (New-RemoteShell $deploy "kunkundy-deploy.sh")

if (Test-Path $archiveLocal) { Remove-Item $archiveLocal -Force }

Write-Host ""
Write-Host "部署完成：http://$ServerIp/" -ForegroundColor Green
Write-Host "如果打不开，检查阿里云安全组是否放行 80 端口（入方向 TCP 80）。" -ForegroundColor Yellow
