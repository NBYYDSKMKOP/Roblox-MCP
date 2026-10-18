#!/usr/bin/env bash
#
# 一键部署 Roblox Executor MCP Server 到 GitHub Codespaces
#
# 用法：
#   bash deploy-codespaces.sh
#
# 部署后打印 Roblox 客户端 loader 连接地址（含 Codespaces 端口转发 URL）。
# 在 Codespace 里运行本脚本即可，其余自动完成。
#
set -euo pipefail

REPO_URL="https://github.com/Potato5466794/Roblox-MCP.git"
APP_DIR="${HOME}/roblox-mcp"
NODE_REQUIRED_MAJOR=20
PORT=16384

log() { printf '\033[1;36m[deploy]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[deploy!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[deploy!]\033[0m %s\n' "$*"; exit 1; }

# 在 Codespaces 里加载 nvm（不同镜像位置不同）
source_nvm() {
  if [ -s "$NVM_DIR/nvm.sh" ]; then
    . "$NVM_DIR/nvm.sh"
  elif [ -s "${HOME}/.nvm/nvm.sh" ]; then
    . "${HOME}/.nvm/nvm.sh"
  elif [ -s "/usr/local/share/nvm/nvm.sh" ]; then
    . "/usr/local/share/nvm/nvm.sh"
  elif [ -s "/usr/local/nvm/nvm.sh" ]; then
    . "/usr/local/nvm/nvm.sh"
  fi
}

# ---------- 1. 获取源码 ----------
if [ -d "$APP_DIR/.git" ]; then
  log "源码已存在，拉取最新（$APP_DIR）"
  git -C "$APP_DIR" pull --ff-only || warn "git pull 失败，继续使用现有代码"
else
  log "克隆仓库到 $APP_DIR"
  git clone --depth 1 "$REPO_URL" "$APP_DIR"
fi
cd "$APP_DIR"

# ---------- 2. 确认 Node >= 20 ----------
if command -v node >/dev/null 2>&1; then
  node_major=$(node -v | sed 's/v\([0-9]*\).*/\1/')
  log "检测到 Node $(node -v)"
  if [ "$node_major" -lt "$NODE_REQUIRED_MAJOR" ]; then
    warn "Node 版本过低（需 >= $NODE_REQUIRED_MAJOR），尝试用 nvm 升级"
    source_nvm
    if command -v nvm >/dev/null 2>&1; then
      nvm install 22 && nvm use 22
    else
      die "未找到 nvm，请先手动安装 Node >= 20 后重跑"
    fi
  fi
else
  warn "未检测到 node，尝试用 nvm 安装"
  source_nvm
  nvm install 22 && nvm use 22
fi
node -v

# ---------- 3. 安装依赖并构建 ----------
log "安装依赖（npm install）"
npm install --no-audit --no-fund

log "构建（npm run build）"
npm run build

# ---------- 4. 启动 server（后台常驻，监听 ${PORT}） ----------
if pgrep -f "dist/index.js" >/dev/null 2>&1; then
  warn "server 已在运行，跳过启动"
else
  log "启动 server：node dist/index.js （端口 ${PORT}）"
  nohup node dist/index.js > /tmp/roblox-mcp.log 2>&1 &
  # 等待就绪
  for i in $(seq 1 20); do
    if curl -s -m 2 "http://localhost:${PORT}/status" | grep -q "Running"; then
      break
    fi
    sleep 1
  done
  if curl -s -m 2 "http://localhost:${PORT}/status" | grep -q "Running"; then
    log "server 启动成功，状态：$(curl -s -m 2 http://localhost:${PORT}/status)"
  else
    warn "server 可能启动失败，日志见 /tmp/roblox-mcp.log"
    tail -20 /tmp/roblox-mcp.log 2>/dev/null || true
  fi
fi

# ---------- 5. 打印 Roblox loader 连接地址 ----------
log ""
log "============================================================"
log " Roblox 客户端连接方式（客户端跑在本机 Windows/Mac）"
log "============================================================"
# 端口转发 URL：Codespaces 会给端口 ${PORT} 分配一个公网 https 地址
# 尝试自动获取 Codespaces 端口转发地址（用 gh CLI，需已登录）
forward=""
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  forward="$(gh codespace ports 2>/dev/null | awk -v p="$PORT" '$1==p {print $3; exit}' | head -1)"
fi
if [ -n "${forward:-}" ]; then
  log "  自动检测到 Codespaces 转发地址："
  log "      ${forward}"
else
  warn "  未能自动检测转发地址，请按下面步骤手动获取："
  warn "    ① 在 Codespaces 底部打开『端口 / Ports』面板"
  warn "    ② 找到端口 ${PORT} 那行的『Forwarded Address / 转发地址』"
  warn "    ③ 复制那个 https://xxx.app.github.dev 链接"
  warn "   （本机 Roblox 执行器必须能联网访问该地址）"
fi

log ""
log "  在本机 Roblox 执行器里运行以下 loader（粘贴即可）："
log "  ------------------------------------------------------------"
if [ -n "$forward" ]; then
  log "  getgenv().BridgeURL = \"${forward#https://}\""
  log "  loadstring(game:HttpGet(\"${forward}/script.luau\"))()"
else
  log "  local bridgeUrl = getgenv().BridgeURL or \"localhost:16384\""
  log "  loadstring(game:HttpGet(\"http://\" .. bridgeUrl .. \"/script.luau\"))()"
fi
log "  ------------------------------------------------------------"
log ""
log "  Web Dashboard（在 Codespace 里打开此端口）："
log "      http://localhost:${PORT}/"
log "============================================================"

exit 0