#!/bin/bash
# net-guard 一键恢复 —— 关系统代理、修 shell 代理、拉起组网、体检
#
# Clash Verge 的配置不在这里还原：手工快照总追不上后来在 Clash Verge 里做的改动，还原旧快照反而会冲掉新的修复。
# 改用 Clash Verge 自带的定时备份（设置 → 备份）。
#
# 用法：
#   net-restore.sh                 关代理 + 拉起组网 + 体检（不动正在跑的内核，不会断你自己的网）
#   net-restore.sh --reload-clash  额外重启 Clash Verge 图形界面，让 Merge 改动立即生效（会短暂断网）
#
# 特性：动手前先自动快照，任何一步失败都会保留现场，可回滚。

set -uo pipefail

# 按自己的环境改默认值，或用 ${...:-} 里的环境变量覆盖
NET_GUARD_DIR="${NET_GUARD_DIR:-$HOME/.net-guard}"           # 快照备份放在这里的 backups/ 下
GOOD_ZSHRC="${GOOD_ZSHRC:-$NET_GUARD_DIR/dot-zshrc}"          # 可选：一份确认可用的 ~/.zshrc
NET_STATUS="${NET_STATUS:-$(dirname "$(readlink -f "$0")")/net-status.sh}"
TS="${TAILSCALE_CLI:-/Applications/Tailscale.app/Contents/MacOS/Tailscale}"
SOCK="${CLASH_SOCK:-/var/run/clash-verge-service/users/$(id -u)/verge-mihomo.sock}"
MIXED_PORT="${CLASH_MIXED_PORT:-7897}"
CLASH_APP="${CLASH_APP:-Clash Verge}"                       # /Applications 里的应用名
RELOAD_CLASH=0
[ "${1:-}" = "--reload-clash" ] && RELOAD_CLASH=1

ok()   { printf "  [OK]   %s\n" "$1"; }
warn() { printf "  [WARN] %s\n" "$1"; }
bad()  { printf "  [FAIL] %s\n" "$1"; }
step() { printf "\n==> %s\n" "$1"; }

TS_STAMP=$(date '+%Y%m%d-%H%M%S')
BK="$NET_GUARD_DIR/backups/$TS_STAMP"
mkdir -p "$BK"

step "0. 动手前先快照当前状态 → $BK"
scutil --proxy              > "$BK/system-proxy.txt" 2>&1
netstat -rn                 > "$BK/routes.txt" 2>&1
scutil --dns                > "$BK/dns.txt" 2>&1
cp "$HOME/.zshrc"                "$BK/dot-zshrc" 2>/dev/null
"$TS" status > "$BK/tailscale.txt" 2>&1 || true
ok "快照完成（Clash 配置不在这里，看 Clash Verge 自带备份）"

step "1. 确保 shell 代理配置正确（指向活的 $MIXED_PORT 端口）"
if grep -q "127.0.0.1:$MIXED_PORT" "$HOME/.zshrc" 2>/dev/null; then
  ok "~/.zshrc 已指向 $MIXED_PORT，无需改动"
elif [ -f "$GOOD_ZSHRC" ]; then
  cp "$HOME/.zshrc" "$BK/dot-zshrc.before-merge" 2>/dev/null
  cp "$GOOD_ZSHRC" "$HOME/.zshrc" && ok "~/.zshrc 已从 $GOOD_ZSHRC 还原（原文件已备份）"
else
  warn "无法判断 ~/.zshrc，跳过"
fi

step "2. 关闭所有网络服务上的系统代理（已知可用状态=全关，靠 TUN 走流量）"
while IFS= read -r s; do
  case "$s" in \**|"") continue;; esac
  networksetup -setwebproxystate      "$s" off 2>/dev/null
  networksetup -setsecurewebproxystate "$s" off 2>/dev/null
  networksetup -setsocksfirewallproxystate "$s" off 2>/dev/null
done < <(networksetup -listallnetworkservices 2>/dev/null | tail -n +2)
ok "系统代理已全部关闭"

step "3. 拉起 Tailscale 组网"
if "$TS" status 2>&1 | head -1 | grep -qi "stopped"; then
  "$TS" up >/dev/null 2>&1
  sleep 3
  if "$TS" status 2>&1 | head -1 | grep -qi "stopped"; then
    bad "Tailscale 仍处于 stopped，可能需要在图形界面里登录"
  else
    ok "Tailscale 已恢复"
  fi
else
  ok "Tailscale 本来就在线"
fi
if netstat -rn -f inet 2>/dev/null | grep -q "^100\.64/10"; then
  ok "100.64/10 组网路由在位"
else
  bad "组网路由仍缺失"
fi

if [ "$RELOAD_CLASH" = "1" ]; then
  step "4. 重启 Clash Verge（会短暂断网，让 Merge 改动生效）"
  osascript -e "quit app \"$CLASH_APP\"" >/dev/null 2>&1
  sleep 4
  open -a "$CLASH_APP" >/dev/null 2>&1
  echo "  等待内核启动..."
  for i in $(seq 1 20); do
    if curl -sS -m 2 --unix-socket "$SOCK" http://localhost/version >/dev/null 2>&1; then break; fi
    sleep 2
  done
  if curl -sS -m 3 --unix-socket "$SOCK" http://localhost/version >/dev/null 2>&1; then
    ok "Clash 内核已重新就绪"
    if curl -sS -m 5 --unix-socket "$SOCK" http://localhost/configs 2>/dev/null \
       | grep -q "route-exclude-address"; then
      ok "TUN 已排除 Tailscale 网段（永久加固生效）"
    else
      warn "路由排除项尚未出现在运行时配置里，可稍后重跑体检确认"
    fi
  else
    bad "Clash 内核未就绪，请手动打开 Clash Verge"
  fi
else
  step "4. 跳过重启 Clash（默认不重启，避免切断你当前正在用的连接）"
  echo "  如需让 Merge 改动立即生效：net-restore.sh --reload-clash"
fi

step "5. 体检结果"
bash "$NET_STATUS"

printf "\n本次快照备份在：%s\n" "$BK"
