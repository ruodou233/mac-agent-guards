# Mac Agent 守护脚本｜Mac Agent Guards

**Three small macOS scripts for running AI coding agents (Claude Code, Codex and the like) for hours on a Mac.**

> 拔电合盖也要让 Agent 接着跑；可一旦断了网，就该让电脑睡下，别在包里白白耗电。网络出毛病时，先分清是翻墙断了、组网断了，还是 DNS 炸了。

Unplug, close the lid, and the agent should keep working. But once the network is gone, the Mac should go to sleep instead of burning battery in your bag. And when the network acts up, you want to know in seconds whether the proxy, the Tailscale network or DNS is at fault.

| Script | What it does |
|---|---|
| `network-sleep-guard/network-sleep-guard.py` | Lid closed + on battery + Keepresso keeping the Mac awake + offline for 5 minutes → stop Keepresso and put the Mac to sleep. |
| `net-guard/net-status.sh` | Read-only network check: Clash Verge core, TUN, Tailscale, DNS, real connectivity. |
| `net-guard/net-restore.sh` | One-shot repair: turn off system proxies, fix the shell proxy, bring Tailscale up, then run the check. |

[中文说明](#中文说明)

## network-sleep-guard

Every 30 seconds, and only while the lid is closed, the Mac is on battery and Keepresso is keeping it awake, it checks the internet. After 5 minutes offline it runs `keepresso stop` and `pmset sleepnow`, and posts a notification. Opening the lid, plugging in or getting back online cancels the countdown.

### Requirements

- [Keepresso](https://github.com/gyorgysh/keepresso), a third-party keep-awake app (macOS 14 or newer), installed in `/Applications`. In its settings, turn on **Keep awake with lid closed** and keep **Only while brewing** checked; without it, stopping Keepresso does not release the closed-lid override and the Mac stays awake.
- `/usr/bin/python3` (comes with the Xcode Command Line Tools). Standard library only.

### Install

```bash
git clone https://github.com/ruodou233/mac-agent-guards.git
cd mac-agent-guards
dir="$HOME/Library/Application Support/NetworkSleepGuard"
mkdir -p "$dir"
cp network-sleep-guard/network-sleep-guard.py "$dir/"
sed "s|__INSTALL_DIR__|$dir|g" network-sleep-guard/io.github.ruodou233.network-sleep-guard.plist \
  > ~/Library/LaunchAgents/io.github.ruodou233.network-sleep-guard.plist
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/io.github.ruodou233.network-sleep-guard.plist
```

The log is `guard.log` in the same folder. After editing the installed script, restart it:

```bash
launchctl kickstart -k "gui/$(id -u)/io.github.ruodou233.network-sleep-guard"
```

To remove it:

```bash
launchctl bootout "gui/$(id -u)/io.github.ruodou233.network-sleep-guard"
rm ~/Library/LaunchAgents/io.github.ruodou233.network-sleep-guard.plist
```

### Adjust for your setup

At the top of `network-sleep-guard.py`:

| Setting | Default | Meaning |
|---|---|---|
| `KEEPRESSO_CLI` (environment variable) | `/Applications/Keepresso.app/Contents/Helpers/keepresso` | Keepresso's command-line tool. To set it from launchd, add it under `EnvironmentVariables` in the plist. |
| `INTERVAL` | `30` | Seconds between checks. Keep it well under 90: a longer gap is treated as a sleep and restarts the countdown. |
| `OFFLINE_SECONDS` | `300` | Seconds offline before it acts. |

"Online" means Apple's `https://www.apple.com/library/test/success.html` or Cloudflare's `https://cp.cloudflare.com/generate_204` answers, without any proxy. Change the URLs in `online()` if neither is reachable directly where you are.

### Self-test

```bash
/usr/bin/python3 network-sleep-guard/network-sleep-guard.py --self-test   # countdown logic with stubs; never stops Keepresso or sleeps
/usr/bin/python3 network-sleep-guard/network-sleep-guard.py --check       # prints lid, battery, Keepresso and internet state as JSON; changes nothing
```

## net-guard

- `net-status.sh` changes nothing. It checks: the Clash Verge core (mihomo) answers on its socket; the mixed port is listening; TUN has taken over routing; the Tailscale route `100.64/10` exists and `100.64.0.0/10` is excluded from TUN in both the running config and `Merge.yaml`; Tailscale is online; DNS resolves; a direct site and a proxied site are reachable; no proxy is left on the Tailscale network service; `~/.zshrc` does not use an old proxy port.
- `net-restore.sh` first saves a snapshot (system proxy, routes, DNS, `~/.zshrc`, Tailscale status) to `~/.net-guard/backups/<time>/`, then turns off the web, secure web and SOCKS proxies on every network service, restores `~/.zshrc` from a known-good copy if its proxy port is wrong, runs `tailscale up` if Tailscale is stopped, and finally runs `net-status.sh`. `--reload-clash` also restarts the Clash Verge app (the connection drops briefly). It does not restore Clash Verge's own config; use Clash Verge's built-in scheduled backup for that.

Script output is in Chinese.

### Requirements

- [Clash Verge Rev](https://github.com/clash-verge-rev/clash-verge-rev) with the service installed and **TUN mode** on. The scripts expect TUN to carry the traffic, with the system proxy off.
- [Tailscale](https://tailscale.com) for macOS.
- The Tailscale ranges excluded from TUN, in Clash Verge's global Merge config (`profiles/Merge.yaml`):

  ```yaml
  tun:
    route-exclude-address:
      - 100.64.0.0/10
      - fd7a:115c:a1e0::/48
  ```

### Install

From the repo folder:

```bash
mkdir -p ~/.local/bin
ln -s "$PWD/net-guard/net-status.sh" ~/.local/bin/net-status
ln -s "$PWD/net-guard/net-restore.sh" ~/.local/bin/net-restore
```

Optional: save a `~/.zshrc` you know works as `~/.net-guard/dot-zshrc`, so `net-restore` can put it back.

### Adjust for your setup

Each variable has a default at the top of the script and can be overridden by an environment variable of the same name.

| Variable | Default | Used by |
|---|---|---|
| `TAILSCALE_CLI` | `/Applications/Tailscale.app/Contents/MacOS/Tailscale` | both |
| `CLASH_SOCK` | `/var/run/clash-verge-service/users/$(id -u)/verge-mihomo.sock` | both |
| `CLASH_MIXED_PORT` | `7897` (Clash Verge default) | both |
| `CLASH_TUN_GATEWAY` | `198.18.0.1` (mihomo default) | `net-status` |
| `OLD_PROXY_PORT` | `7890` | `net-status`: warns if `~/.zshrc` still uses it |
| `DIRECT_HOST` | `www.baidu.com` | `net-status`: should load without the proxy |
| `ABROAD_HOST` | `www.google.com` | `net-status`: should load only through the proxy |
| `CLASH_MERGE_YAML` | `~/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/profiles/Merge.yaml` | `net-status` |
| `NET_GUARD_DIR` | `~/.net-guard` | `net-restore`: snapshots go to `backups/` here |
| `GOOD_ZSHRC` | `$NET_GUARD_DIR/dot-zshrc` | `net-restore` |
| `NET_STATUS` | `net-status.sh` next to the real path of `net-restore.sh` | `net-restore` |
| `CLASH_APP` | `Clash Verge` | `net-restore --reload-clash` |

The socket path differs between Clash Verge versions. If the core check fails while Clash Verge is running, find yours with `find /var/run /tmp -name '*mihomo*.sock' 2>/dev/null`.

### Self-check

```bash
net-status                        # read-only, safe to run any time
bash -n net-guard/net-restore.sh  # syntax check without running it
```

## Known limitations

- `keepresso stop` also pauses Keepresso's triggers until Keepresso restarts. After the guard has acted, automatic keep-awake stays off until you click **Resume Triggers** in Keepresso's menu or relaunch it.
- The guard only acts when all three hold: lid closed, on battery, Keepresso keeping the Mac awake. With the lid open or on power it does nothing.
- `net-restore` turns the system proxy off everywhere. If you rely on Clash Verge's system proxy instead of TUN, do not run it.
- The net-guard scripts are written for Clash Verge Rev + Tailscale on macOS and will not fit other proxy setups without edits.

## License

[MIT](LICENSE)

## Feedback

Issues and pull requests are welcome.

---

## 中文说明

三件 macOS 小脚本，服务"在 Mac 上长时间跑 AI 编码 Agent（Claude Code、Codex 等）"这个场景。

| 脚本 | 干什么 |
|---|---|
| `network-sleep-guard/network-sleep-guard.py` | 合盖、用电池、Keepresso 正在保活时，断网满 5 分钟就停保活并让电脑睡眠。 |
| `net-guard/net-status.sh` | 网络体检，只读：Clash Verge 内核、TUN、Tailscale、DNS、实际连通性。 |
| `net-guard/net-restore.sh` | 一键恢复：关系统代理、修 shell 代理、拉起 Tailscale，最后跑一遍体检。 |

### 断网守护 network-sleep-guard

只在合盖、用电池、Keepresso 正在保活这三个条件同时满足时，每 30 秒探一次外网。连续断网 5 分钟，就执行 `keepresso stop` 和 `pmset sleepnow`，并发一条系统通知。开盖、接电或网络恢复都会取消倒计时。

#### 依赖

- 第三方防睡眠工具 [Keepresso](https://github.com/gyorgysh/keepresso)（要 macOS 14 或更新），装在"应用程序"里。在它的设置里打开 **合盖时保持唤醒**（Keep awake with lid closed），并保持勾选 **仅在保持唤醒会话期间**（Only while brewing）；不勾的话，停掉保活也释放不了合盖覆盖，电脑睡不下去。
- `/usr/bin/python3`（随 Xcode 命令行工具安装），只用标准库。

#### 安装

```bash
git clone https://github.com/ruodou233/mac-agent-guards.git
cd mac-agent-guards
dir="$HOME/Library/Application Support/NetworkSleepGuard"
mkdir -p "$dir"
cp network-sleep-guard/network-sleep-guard.py "$dir/"
sed "s|__INSTALL_DIR__|$dir|g" network-sleep-guard/io.github.ruodou233.network-sleep-guard.plist \
  > ~/Library/LaunchAgents/io.github.ruodou233.network-sleep-guard.plist
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/io.github.ruodou233.network-sleep-guard.plist
```

日志是同目录下的 `guard.log`。改了安装好的脚本后重启它：

```bash
launchctl kickstart -k "gui/$(id -u)/io.github.ruodou233.network-sleep-guard"
```

卸载：

```bash
launchctl bootout "gui/$(id -u)/io.github.ruodou233.network-sleep-guard"
rm ~/Library/LaunchAgents/io.github.ruodou233.network-sleep-guard.plist
```

#### 按自己环境要改的地方

都在 `network-sleep-guard.py` 开头：

| 设置 | 默认值 | 含义 |
|---|---|---|
| `KEEPRESSO_CLI`（环境变量） | `/Applications/Keepresso.app/Contents/Helpers/keepresso` | Keepresso 的命令行工具。要从 launchd 传，就加在 plist 的 `EnvironmentVariables` 里。 |
| `INTERVAL` | `30` | 每隔多少秒检查一次。要远小于 90：两次检查隔太久会被当成睡过一觉，倒计时重来。 |
| `OFFLINE_SECONDS` | `300` | 连续断网多少秒后动手。 |

"在线"的判定是：不走代理，能打开苹果的 `https://www.apple.com/library/test/success.html` 或 Cloudflare 的 `https://cp.cloudflare.com/generate_204` 之一。你那里两个都直连不了的话，改 `online()` 里的网址。

#### 自测

```bash
/usr/bin/python3 network-sleep-guard/network-sleep-guard.py --self-test   # 用假数据测倒计时逻辑，不会停保活，也不会睡眠
/usr/bin/python3 network-sleep-guard/network-sleep-guard.py --check       # 以 JSON 打印合盖、电池、Keepresso、外网状态，什么都不改
```

### 网络体检和一键恢复 net-guard

- `net-status.sh` 什么都不改。它查：Clash Verge 内核（mihomo）在套接字上有响应；混合端口在监听；TUN 接管了路由；Tailscale 网段路由 `100.64/10` 在位，运行中的配置和 `Merge.yaml` 都把 `100.64.0.0/10` 从 TUN 排除；Tailscale 在线；DNS 能解析；直连站点和走代理的站点都能打开；Tailscale 网络服务上没留代理；`~/.zshrc` 没用旧代理端口。
- `net-restore.sh` 先把系统代理、路由、DNS、`~/.zshrc`、Tailscale 状态快照到 `~/.net-guard/backups/<时间>/`，然后关掉所有网络服务上的网页代理、安全网页代理和 SOCKS 代理；`~/.zshrc` 的代理端口不对时，从一份确认可用的副本还原；Tailscale 停着就执行 `tailscale up`；最后跑 `net-status.sh`。加 `--reload-clash` 会再重启 Clash Verge（会短暂断网）。它不还原 Clash Verge 自己的配置，那部分用 Clash Verge 自带的定时备份。

脚本输出是中文。

#### 依赖

- [Clash Verge Rev](https://github.com/clash-verge-rev/clash-verge-rev)，装好服务模式并打开 **TUN 模式**（虚拟网卡模式）。脚本按"系统代理关、靠 TUN 走流量"来判断。
- macOS 版 [Tailscale](https://tailscale.com)（组网工具）。
- 在 Clash Verge 的全局扩展配置（`profiles/Merge.yaml`）里把 Tailscale 网段从 TUN 排除：

  ```yaml
  tun:
    route-exclude-address:
      - 100.64.0.0/10
      - fd7a:115c:a1e0::/48
  ```

#### 安装

在仓库目录里执行：

```bash
mkdir -p ~/.local/bin
ln -s "$PWD/net-guard/net-status.sh" ~/.local/bin/net-status
ln -s "$PWD/net-guard/net-restore.sh" ~/.local/bin/net-restore
```

可选：把一份确认能用的 `~/.zshrc` 存成 `~/.net-guard/dot-zshrc`，`net-restore` 需要时会拿它还原。

#### 按自己环境要改的地方

每个变量在脚本开头都有默认值，也可以用同名环境变量覆盖。

| 变量 | 默认值 | 用在 |
|---|---|---|
| `TAILSCALE_CLI` | `/Applications/Tailscale.app/Contents/MacOS/Tailscale` | 两个都用 |
| `CLASH_SOCK` | `/var/run/clash-verge-service/users/$(id -u)/verge-mihomo.sock` | 两个都用 |
| `CLASH_MIXED_PORT` | `7897`（Clash Verge 默认值） | 两个都用 |
| `CLASH_TUN_GATEWAY` | `198.18.0.1`（mihomo 默认值） | `net-status` |
| `OLD_PROXY_PORT` | `7890` | `net-status`：`~/.zshrc` 还在用它就报警 |
| `DIRECT_HOST` | `www.baidu.com` | `net-status`：不走代理就该能打开 |
| `ABROAD_HOST` | `www.google.com` | `net-status`：要走代理才能打开 |
| `CLASH_MERGE_YAML` | `~/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/profiles/Merge.yaml` | `net-status` |
| `NET_GUARD_DIR` | `~/.net-guard` | `net-restore`：快照放在这里的 `backups/` 下 |
| `GOOD_ZSHRC` | `$NET_GUARD_DIR/dot-zshrc` | `net-restore` |
| `NET_STATUS` | `net-restore.sh` 实际所在目录里的 `net-status.sh` | `net-restore` |
| `CLASH_APP` | `Clash Verge` | `net-restore --reload-clash` |

不同版本的 Clash Verge 套接字路径不一样。Clash Verge 开着、体检却说内核没响应时，用 `find /var/run /tmp -name '*mihomo*.sock' 2>/dev/null` 找到自己的路径。

#### 自测

```bash
net-status                        # 只读，随时可以跑
bash -n net-guard/net-restore.sh  # 只查语法，不执行
```

### 已知限制

- `keepresso stop` 会让 Keepresso 的触发器一直暂停，直到 Keepresso 重启。守护动过手之后，自动保活就一直停着，要在 Keepresso 菜单里点 **恢复触发条件**（Resume Triggers）或重开 Keepresso 才恢复。
- 断网守护只在合盖、用电池、保活中三个条件同时满足时才工作；开着盖或接着电时什么都不做。
- `net-restore` 会关掉所有网络服务上的系统代理。靠 Clash Verge 系统代理而不是 TUN 上网的，别运行它。
- net-guard 两个脚本是照 Clash Verge Rev + Tailscale 的组合写的，别的代理方案要自己改。

### 许可证

[MIT](LICENSE)

### 反馈

发现问题或有改进方案，欢迎在本仓提交 issue 或 PR。
