#!/usr/bin/env bash
#
# 在 Codespace 里给 connector.luau 打 https/wss 支持补丁
#
# 背景：connector.luau 原版硬编码 http:// 和 ws://，无法连 Codespaces 的 https 转发地址。
# 本补丁让它根据 getgenv().BridgeURL 是否带协议，自动选择 http/https + ws/wss。
#
# 用法（在 Codespace 的 roblox-mcp 项目根目录执行）：
#   bash patch-connector-https.sh
#
# 改完即时生效：server 的 /script.luau 路由每次都从磁盘读 connector.luau，无需重启。
#
set -euo pipefail

FILE="connector.luau"
[ -f "$FILE" ] || { echo "[patch] 未找到 $FILE，请在项目根目录运行"; exit 1; }

# 幂等：已打过补丁则跳过
if grep -q "HTTP_SCHEME" "$FILE"; then
  echo "[patch] $FILE 已含 HTTP_SCHEME，跳过（已打过补丁）"
  exit 0
fi

# 1) 在 BridgeURL 定义行后插入 scheme 解析块
INSERT='
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
end'

python3 - "$FILE" "$INSERT" <<'PY'
import sys, io
path, insert = sys.argv[1], sys.argv[2]
src = io.open(path, encoding="utf-8").read()
anchor = 'local BridgeURL = getgenv().BridgeURL or ... or "localhost:16384"'
if anchor not in src:
    print("[patch] 未找到 BridgeURL 定义锚点，文件可能已被修改"); sys.exit(1)
src = src.replace(anchor, anchor + insert, 1)
# 2) 替换 6 处硬编码
src = src.replace('"http://" .. BridgeURL', 'HTTP_SCHEME .. BridgeURL')
src = src.replace('WebSocket.connect("ws://" .. BridgeURL)', 'WebSocket.connect(WS_SCHEME .. BridgeURL)')
io.open(path, "w", encoding="utf-8").write(src)
print("[patch] 补丁已应用")
PY

echo "[patch] 验证："
grep -c "HTTP_SCHEME\|WS_SCHEME" "$FILE" | sed 's/^/  HTTP_SCHEME\/WS_SCHEME 引用数: /'
grep -c '"http://" .. BridgeURL\|"ws://" .. BridgeURL' "$FILE" | sed 's/^/  残留硬编码数(应为0): /'
echo "[patch] 完成。注入器用 https 的 BridgeURL 即可连通。"
