#!/usr/bin/env bash
#
# Roblox-MCP 一键诊断 + 修复（Codespace 用）
#
# 作用：
#   1. 定位正在运行的 server 及其真实项目目录（/proc/<pid>/cwd）
#   2. 停掉旧 server（避免 16384 端口被旧进程占用导致路由 404）
#   3. 检查 dist 是否完整（缺 script.luau.js 则重新 npm run build）
#   4. 给 connector.luau 打 https 补丁（无则打，幂等）
#   5. 重启 server
#   6. 自验证 /script.luau 与 /api/status
#   7. 打印最终注入脚本
#
# 用法（在 Codespace 终端，任意目录）：
#   bash fix-roblox-mcp.sh
#
set -u
PORT=16384

say(){ printf '\033[1;36m[fix]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[fix!]\033[0m %s\n' "$*"; }
die(){ printf '\033[1;31m[fix!]\033[0m %s\n' "$*"; exit 1; }

# ---------- 0. 需要 node ----------
if ! command -v node >/dev/null 2>&1; then
  die "未找到 node。Codespace 需先启用 node（或 nvm use 一个 >=20 版本）。"
fi
say "node: $(node -v)"

# ---------- 1. 定位 server 项目目录 ----------
SRV_PID=$(pgrep -f 'dist/index.js' | head -1 || true)
APP_DIR=""
if [ -n "${SRV_PID:-}" ]; then
  APP_DIR=$(readlink -f /proc/$SRV_PID/cwd 2>/dev/null || true)
  say "发现运行中的 server (pid=$SRV_PID)，项目目录: ${APP_DIR:-?(无法读取)}"
fi
if [ -z "${APP_DIR:-}" ] || [ ! -d "$APP_DIR/src" ]; then
  # 回退：常见位置
  for d in "$HOME/roblox-mcp" "$HOME/Roblox-MCP" "$PWD"; do
    if [ -d "$d/src" ] && [ -f "$d/package.json" ]; then
      APP_DIR="$d"; break
    fi
  done
fi
if [ -z "${APP_DIR:-}" ] || [ ! -d "$APP_DIR/src" ]; then
  die "无法定位项目目录（未找到含 src/ + package.json 的目录）。请在项目根目录运行本脚本，或指定目录。"
fi
say "使用项目目录: $APP_DIR"
cd "$APP_DIR" || die "无法进入 $APP_DIR"

# ---------- 2. 停掉旧 server ----------
if [ -n "${SRV_PID:-}" ]; then
  say "停止旧 server (pid=$SRV_PID)..."
  kill "$SRV_PID" 2>/dev/null && sleep 2
  # 再补杀一次防残留
  for p in $(pgrep -f 'dist/index.js' || true); do kill "$p" 2>/dev/null; done
  sleep 1
fi

# ---------- 3. 确保 dist 完整 ----------
say "检查 dist 完整性..."
NEED_BUILD=0
if [ ! -f "dist/index.js" ]; then
  warn "dist/index.js 缺失，需要构建"; NEED_BUILD=1
elif [ ! -f "dist/http/routes/script.luau.js" ]; then
  warn "dist/http/routes/script.luau.js 缺失（这正是 /script.luau 404 的原因），需要重新构建"; NEED_BUILD=1
fi
if [ "$NEED_BUILD" -eq 1 ]; then
  if [ ! -d node_modules ]; then
    say "安装依赖（npm install）..."
    npm install --no-audit --no-fund || die "npm install 失败"
  fi
  say "重新构建（npm run build）..."
  npm run build || die "npm run build 失败"
  say "构建完成。"
fi

# ---------- 4. connector.luau https 补丁 ----------
say "检查 connector.luau https 补丁..."
if grep -q "HTTP_SCHEME" connector.luau; then
  say "补丁已存在，跳过。"
else
  python3 - <<'PY'
import io
s = io.open("connector.luau", encoding="utf-8").read()
anchor = 'local BridgeURL = getgenv().BridgeURL or ... or "localhost:16384"'
insert = """
--// Scheme detection: support https/wss for Codespaces & other TLS-forwarded hosts //--
local HTTP_SCHEME = "http://"
local WS_SCHEME = "ws://"
do
    local url = tostring(BridgeURL)
    local host, protocol = url, nil
    if url:sub(1, 8) == "https://" then
        protocol = "https"
        host = url:sub(9)
    elseif url:sub(1, 7) == "http://" then
        protocol = "http"
        host = url:sub(8)
    end
    if protocol == "https" then
        HTTP_SCHEME = "https://"
        WS_SCHEME = "wss://"
    elseif protocol == "http" then
        HTTP_SCHEME = "http://"
        WS_SCHEME = "ws://"
    end
    if protocol then
        BridgeURL = host
    end
end"""
assert anchor in s, "未找到 BridgeURL 锚点"
s = s.replace(anchor, anchor + insert, 1)
s = s.replace('"http://" .. BridgeURL', 'HTTP_SCHEME .. BridgeURL')
s = s.replace('WebSocket.connect("ws://" .. BridgeURL)', 'WebSocket.connect(WS_SCHEME .. BridgeURL)')
io.open("connector.luau", "w", encoding="utf-8").write(s)
print("补丁已应用")
PY
  say "connector.luau 补丁已应用。"
fi

# ---------- 5. 重启 server ----------
say "启动 server（后台，端口 $PORT）..."
nohup node dist/index.js > /tmp/roblox-mcp.log 2>&1 &
sleep 2

# ---------- 6. 自验证 ----------
say "验证 /api/status:"
curl -s -m 5 "http://localhost:$PORT/api/status" | head -c 200; echo
say "验证 /script.luau（应看到 connector 代码，且含补丁标记 HTTP_SCHEME）:"
SC=$(curl -s -m 8 "http://localhost:$PORT/script.luau" | grep -c "HTTP_SCHEME")
if [ "$SC" -ge 1 ]; then
  say "OK：/script.luau 返回正常，补丁标记 x$SC"
else
  warn "/script.luau 未含补丁标记（HTTP_SCHEME=0），可能读取的 connector 不是当前文件。检查 server 日志："
  tail -20 /tmp/roblox-mcp.log 2>/dev/null || true
fi

# ---------- 7. 端口转发地址 ----------
FWD=""
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  FWD=$(gh codespace ports 2>/dev/null | awk -v p="$PORT" '$1==p {print $3; exit}' | head -1)
fi
if [ -z "${FWD:-}" ]; then
  warn "未能自动获取转发地址，请从 Codespaces『端口』面板复制端口 $PORT 的 Forwarded Address。"
fi

say ""
say "============================================================"
say " 在 Roblox 执行器里粘贴以下注入脚本："
say "============================================================"
if [ -n "${FWD:-}" ]; then
  say "getgenv().DisableWebSocket = true"
  say "getgenv().BridgeURL = \"$FWD\""
  say "loadstring(game:HttpGet(\"$FWD/script.luau\"))()"
else
  say "  （先用上面步骤拿到转发地址后替换 <FWD>）"
  say "getgenv().DisableWebSocket = true"
  say "getgenv().BridgeURL = \"<FWD>\""
  say "loadstring(game:HttpGet(\"<FWD>/script.luau\"))()"
fi
say "============================================================"
say "完成。如果注入仍失败，执行器控制台报什么错，把内容发我。"