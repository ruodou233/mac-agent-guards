#!/bin/bash
# net-guard 网络体检 —— 纯只读，不修改任何配置
# 用途：出问题时先跑这个，30 秒定位是「翻墙断了」还是「组网断了」还是「DNS 炸了」

# 按自己的环境改默认值，或用 ${...:-} 里的环境变量覆盖
TS="${TAILSCALE_CLI:-/Applications/Tailscale.app/Contents/MacOS/Tailscale}"
SOCK="${CLASH_SOCK:-/var/run/clash-verge-service/users/$(id -u)/verge-mihomo.sock}"
MIXED_PORT="${CLASH_MIXED_PORT:-7897}"   # Clash Verge 的混合端口（HTTP + SOCKS）
TUN_GATEWAY="${CLASH_TUN_GATEWAY:-198.18.0.1}"  # TUN 网关，mihomo 默认 198.18.0.1
OLD_PORT="${OLD_PROXY_PORT:-7890}"       # 以前用过、现在不该再生效的代理端口（7890 是很多 Clash 客户端的老默认值）
DIRECT_HOST="${DIRECT_HOST:-www.baidu.com}"    # 不走代理就该能访问的站点
ABROAD_HOST="${ABROAD_HOST:-www.google.com}"   # 要走代理才能访问的站点
MERGE="${CLASH_MERGE_YAML:-$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/profiles/Merge.yaml}"

ok()   { printf "  [OK]   %s\n" "$1"; }
bad()  { printf "  [FAIL] %s\n" "$1"; }
warn() { printf "  [WARN] %s\n" "$1"; }
info() { printf "  [INFO] %s\n" "$1"; }

# Tailscale 状态：BackendState 为 Running 才算在线
ts_backend=""
[ -x "$TS" ] && ts_backend=$("$TS" status --json 2>/dev/null \
  | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("BackendState",""))' 2>/dev/null)

echo "=============================================="
echo " 网络体检  $(date '+%Y-%m-%d %H:%M:%S')"
echo "=============================================="

echo
echo "1) Clash 内核 (verge-mihomo)"
if curl -sS -m 3 --unix-socket "$SOCK" http://localhost/version >/dev/null 2>&1; then
  ver=$(curl -sS -m 3 --unix-socket "$SOCK" http://localhost/version 2>/dev/null)
  ok "内核在跑 $ver"
else
  bad "内核没响应（Clash Verge 可能没启动，也可能是 Clash 换了套接字路径）"
fi
if nc -z -G 1 127.0.0.1 "$MIXED_PORT" 2>/dev/null; then
  ok "混合端口 $MIXED_PORT 在监听"
else
  bad "混合端口 $MIXED_PORT 没监听 —— 走代理的程序会全部超时"
fi

echo
echo "2) TUN 模式与路由"
if netstat -rn -f inet 2>/dev/null | grep -qF "$TUN_GATEWAY"; then
  ok "TUN 已接管流量 ($TUN_GATEWAY)"
else
  warn "TUN 未接管（可能是关掉了，也可能没起来）"
fi
if [ "$ts_backend" != "Running" ]; then
  info "Tailscale 未运行，跳过组网路由检查"
elif netstat -rn -f inet 2>/dev/null | grep -q "^100\.64/10"; then
  ok "Tailscale 网段路由 100.64/10 正常"
else
  bad "Tailscale 网段路由缺失 —— 组网会连不上"
fi
# Tailscale 网段要从 TUN 排除，否则 TUN 会抢走 100.64/10 的流量：运行中的配置和 Merge.yaml 都要有
# （只改运行中的配置，Clash Verge 重启或换订阅后就没了；只改 Merge.yaml，要重启 Clash Verge 才生效）
ts_exclude_hint="Tailscale 网段没有从 TUN 排除，组网会连不上；在 Merge.yaml 的 tun.route-exclude-address 里加上 100.64.0.0/10"
cfg=$(curl -sS -m 3 --unix-socket "$SOCK" http://localhost/configs 2>/dev/null)
if [ -z "$cfg" ]; then
  warn "读不到运行中的 Clash 配置，跳过排除项检查（见第 1 项）"
elif printf '%s' "$cfg" | /usr/bin/python3 -c 'import json,sys; sys.exit("100.64.0.0/10" not in json.load(sys.stdin).get("tun",{}).get("route-exclude-address",[]))' 2>/dev/null; then
  ok "运行中的 Clash 配置已排除 100.64.0.0/10"
else
  bad "运行中的 Clash 配置没有排除 100.64.0.0/10 —— $ts_exclude_hint"
fi
merge_body=$(grep -v '^[[:space:]]*#' "$MERGE" 2>/dev/null)
if printf '%s\n' "$merge_body" | grep -q "route-exclude-address:" \
   && printf '%s\n' "$merge_body" | grep -qE -- '-[[:space:]]*100\.64\.0\.0/10'; then
  ok "Merge.yaml 已排除 100.64.0.0/10"
else
  bad "Merge.yaml 没有排除 100.64.0.0/10 —— $ts_exclude_hint"
fi

echo
echo "3) Tailscale 组网"
if [ -x "$TS" ]; then
  case "$ts_backend" in
    Running)
      n=$("$TS" status 2>&1 | grep -c "100\.")
      ok "Tailscale 在线，可见 $n 个设备" ;;
    Stopped) bad "Tailscale 已停止" ;;
    "")      warn "读不到 Tailscale 状态" ;;
    *)       bad "Tailscale 状态：$ts_backend" ;;
  esac
  ip=$("$TS" ip -4 2>/dev/null | head -1)
  [ -n "$ip" ] && ok "本机组网 IP: $ip"
else
  warn "未找到 Tailscale CLI"
fi

echo
echo "4) DNS"
ns=$(scutil --dns 2>/dev/null | grep -m1 "nameserver\[0\]" | awk '{print $3}')
ok "系统 DNS: ${ns:-未知}"
if dscacheutil -q host -a name "$DIRECT_HOST" 2>/dev/null | grep -q "ip_address"; then
  ok "域名解析正常"
else
  bad "域名解析失败"
fi

echo
echo "5) 实际连通性"
if env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u http_proxy -u https_proxy -u all_proxy \
   curl -sS -m 8 -o /dev/null "http://$DIRECT_HOST" 2>/dev/null; then
  ok "国内站点可达 ($DIRECT_HOST)"
else
  bad "国内站点不可达 —— 基础网络有问题"
fi
if curl -sS -m 12 -o /dev/null -x "http://127.0.0.1:$MIXED_PORT" "https://$ABROAD_HOST" 2>/dev/null; then
  ok "走代理出国 ($ABROAD_HOST) 通"
else
  bad "走代理不通 —— 代理/节点有问题"
fi
if env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u http_proxy -u https_proxy -u all_proxy \
   curl -sS -m 10 -o /dev/null "https://$ABROAD_HOST" 2>/dev/null; then
  ok "不开代理变量也能出国 (TUN 生效)"
else
  warn "不开代理变量出不了国（仅影响不读环境变量的程序）"
fi

echo
echo "6) 残留隐患检查"
ts_state=$(networksetup -getsocksfirewallproxy Tailscale 2>/dev/null | grep -m1 "^Enabled" | awk '{print $2}')
ts_srv=$(networksetup -getsocksfirewallproxy Tailscale 2>/dev/null | grep -m1 "^Server" | awk '{print $2}')
ts_port=$(networksetup -getsocksfirewallproxy Tailscale 2>/dev/null | grep -m1 "^Port" | awk '{print $2}')
if [ "$ts_state" = "Yes" ]; then
  bad "Tailscale 网络服务代理被打开（${ts_srv}:${ts_port}）—— 组网流量会被劫持，务必关掉"
elif [ -n "$ts_srv" ] && [ "$ts_srv" != "0.0.0.0" ]; then
  warn "Tailscale 网络服务留着未启用的僵尸代理 ${ts_srv}:${ts_port}（当前无害）"
else
  ok "无僵尸代理"
fi
if grep -qE "^[[:space:]]*[^#]*$OLD_PORT" "$HOME/.zshrc" 2>/dev/null; then
  warn "~/.zshrc 里有生效的旧代理端口 $OLD_PORT（当前混合端口是 $MIXED_PORT）"
else
  ok "~/.zshrc 代理端口干净（旧端口 $OLD_PORT 没有生效）"
fi

echo
echo "=============================================="
echo " 想一键恢复：net-restore.sh"
echo "=============================================="
