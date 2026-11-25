#!/usr/bin/python3
"""Release Keepresso and sleep after 5 minutes offline, only closed/on battery."""
import concurrent.futures
import datetime
import json
import os
import re
import subprocess
import sys
import time
import urllib.request

CLI = os.environ.get('KEEPRESSO_CLI', '/Applications/Keepresso.app/Contents/Helpers/keepresso')
# 按自己的需要改
INTERVAL = 30           # 每隔多少秒检查一次；要远小于 90 秒，否则两次检查的间隔会被当成睡眠空档
OFFLINE_SECONDS = 300   # 连续断网多少秒后停保活并睡眠


def run(*args):
    return subprocess.run(args, capture_output=True, text=True, timeout=15)


def hardware():
    power = run('/usr/bin/pmset', '-g', 'batt')
    root = run('/usr/sbin/ioreg', '-r', '-c', 'IOPMrootDomain', '-d', '1')
    if power.returncode or root.returncode:
        raise RuntimeError('Cannot read power/lid state')
    return {
        'battery': "Now drawing from 'Battery Power'" in power.stdout,
        'closed': bool(re.search(r'"AppleClamshellState"\s*=\s*Yes', root.stdout)),
        'sleep_disabled': bool(re.search(r'"SleepDisabled"\s*=\s*Yes', root.stdout)),
    }


def active():
    r = run(CLI, 'status', '--json')
    d = json.loads(r.stdout)
    return d.get('appRunning') is True and d.get('status', {}).get('isActive') is True


def probe(url, token=None):
    # Public connectivity checks only; no cookies, credentials, or task data.
    try:
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(url, timeout=8) as response:
            body = response.read(4096)
            return (response.status == 200 and token in body) if token else response.status == 204
    except Exception:
        return False


def online():
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        checks = [
            pool.submit(probe, 'https://www.apple.com/library/test/success.html', b'<TITLE>Success</TITLE>'),
            pool.submit(probe, 'https://cp.cloudflare.com/generate_204'),
        ]
        return any([check.result() for check in checks])


def advance(since, previous, now, eligible, connected):
    # A long observation gap (sleep, shutdown, stalled process) is not proof
    # of continuous disconnection; start a fresh grace period.
    if not eligible or connected:
        return None, False
    if since is None or previous is None or now - previous > 90:
        return now, False
    return since, now - since >= OFFLINE_SECONDS


def log(message):
    print(datetime.datetime.now().astimezone().isoformat(timespec='seconds'), message, flush=True)


def notify(message, title):
    # 文字作为 osascript 参数传入，不用管转义；失败只写日志，不影响睡眠
    try:
        r = subprocess.run(
            ['/usr/bin/osascript', '-e', 'on run argv',
             '-e', 'display notification (item 1 of argv) with title (item 2 of argv)',
             '-e', 'end run', message, title],
            capture_output=True, text=True, timeout=5)
        if r.returncode:
            log('Notification failed: ' + r.stderr.strip())
    except Exception as e:
        log('Notification failed: ' + str(e))


def request_sleep():
    # Recheck after the probes: opening the lid or plugging in cancels it.
    h = hardware()
    if not (h['battery'] and h['closed'] and active()):
        return
    if online():
        log('Network recovered before sleep; cancelled')
        return
    h = hardware()
    if not (h['battery'] and h['closed'] and active()):
        return
    r = run(CLI, 'stop')
    if r.returncode:
        raise RuntimeError('Keepresso stop failed: ' + r.stderr.strip())
    # The app releases its privileged closed-lid override asynchronously.
    for i in range(15):
        time.sleep(1)
        h = hardware()
        if not (h['battery'] and h['closed']):
            log('Lid opened or power connected; sleep cancelled,保活已关闭')
            return
        # status.json is refreshed asynchronously (1 Hz), so for the first 3
        # seconds after stop it can still say active.
        if i >= 3 and active():
            log('A new keep-awake session started; sleep cancelled')
            return
        if not h['sleep_disabled']:
            log('Offline for %ds: Keepresso stopped; requesting system sleep' % OFFLINE_SECONDS)
            notify('断网 %d 分钟，已停止保活并让电脑睡眠' % round(OFFLINE_SECONDS / 60), 'NetworkSleepGuard')
            r = run('/usr/bin/pmset', 'sleepnow')
            if r.returncode:
                raise RuntimeError('Sleep request failed: ' + r.stderr.strip())
            return
    raise RuntimeError('Keepresso stopped but closed-lid override did not release')


def self_test():
    # 断言按默认的 300 秒写；自测进程跑完就退出，改全局值不影响守护本身
    global OFFLINE_SECONDS
    OFFLINE_SECONDS = 300
    assert advance(None, None, 0, True, False) == (0, False)
    assert advance(0, 270, 299, True, False) == (0, False)
    assert advance(0, 270, 300, True, False) == (0, True)
    assert advance(0, 270, 300, True, True) == (None, False)
    assert advance(0, 270, 300, False, False) == (None, False)
    assert advance(0, 100, 301, True, False) == (301, False)
    assert advance(None, 300, 330, True, False) == (330, False)
    # After stop, a stale "active" in the first 3 seconds must not cancel sleep;
    # a session that is still active after that must.
    from unittest import mock
    for stale_ticks, sleep_disabled_ticks, expect_sleep in ((3, 2, True), (99, 6, False)):
        ticks, calls = [], []
        with mock.patch.multiple(
                sys.modules[__name__],
                run=lambda *a: calls.append(a) or subprocess.CompletedProcess(a, 0, '', ''),
                log=lambda m: None,
                notify=lambda message, title: None,
                online=lambda: False,
                hardware=lambda: {'battery': True, 'closed': True, 'sleep_disabled': len(ticks) < sleep_disabled_ticks},
                active=lambda: len(ticks) <= stale_ticks), \
                mock.patch.object(time, 'sleep', ticks.append):
            request_sleep()
        assert (('/usr/bin/pmset', 'sleepnow') in calls) == expect_sleep, (stale_ticks, calls)
    print('PASS: grace boundary, recovery, eligibility, observation gap, fresh countdown and post-stop settle window')


def main():
    if '--self-test' in sys.argv:
        self_test()
        return
    if '--check' in sys.argv:
        print(json.dumps(dict(hardware(), keepresso_active=active(), internet=online()), indent=2))
        return
    log('Network guard started: closed lid + battery + active Keepresso; %ds offline grace' % OFFLINE_SECONDS)
    since = previous = None
    last_state = None
    while True:
        try:
            h = hardware()
            eligible = h['battery'] and h['closed'] and active()
            connected = online() if eligible else None
            # time.monotonic() stops during sleep on macOS (mach_absolute_time);
            # CLOCK_MONOTONIC keeps running, so the 90 s gap check sees a sleep.
            now = time.clock_gettime(time.CLOCK_MONOTONIC)
            since, due = advance(since, previous, now, eligible, connected)
            previous = now
            state = 'online' if eligible and connected else 'offline-countdown' if eligible else 'inactive'
            if state != last_state:
                log(state)
                last_state = state
            if due:
                request_sleep()
                since = previous = None
                last_state = None
        except Exception as e:
            log('Check failed (no forced sleep): ' + str(e))
            since = previous = None
        time.sleep(INTERVAL)


if __name__ == '__main__':
    main()
