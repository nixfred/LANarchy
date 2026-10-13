"""One-shot LAN speedtest. Curl first. iperf3 only if the binary is already there.

Result:
  ok: bool
  method: "curl" | "iperf3" | None
  mbps: float | None
  bytes: int | None
  seconds: float | None
  url: str | None
  host: str | None
  error: str | None
  tried: list[str]
"""
from __future__ import annotations

import json
import subprocess
import time
from typing import Any, Callable, NamedTuple

from telemetry_lib import is_local_host

DEFAULT_SPEEDTEST_URL = "https://files.lan/"
CURL_TIMEOUT_S = 20.0
IPERF_TIMEOUT_S = 8.0
FILES_LAN = "files.lan"

RunFn = Callable[..., "RunResult"]
SpawnFn = Callable[[list[str]], Any]


class RunResult(NamedTuple):
    returncode: int
    stdout: str
    stderr: str = ""


def default_run(args: list[str], timeout: float, stdin: str | None = None) -> RunResult:
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=timeout, check=False, input=stdin)
        return RunResult(p.returncode, p.stdout or "", p.stderr or "")
    except FileNotFoundError:
        return RunResult(127, "", "not found")
    except subprocess.TimeoutExpired:
        return RunResult(124, "", "timeout")
    except OSError as e:
        return RunResult(1, "", str(e)[:160])


def default_spawn(args: list[str]) -> subprocess.Popen:
    return subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)


def _stop(proc: Any) -> None:
    if proc is None:
        return
    try:
        if getattr(proc, "poll", lambda: 0)() is None:
            proc.terminate()
            try:
                proc.wait(timeout=2)
            except (subprocess.TimeoutExpired, TypeError):
                kill = getattr(proc, "kill", None)
                if kill:
                    kill()
    except OSError:
        pass


def _fail(error: str, *, method: str | None = None, url: str | None = None, host: str | None = None) -> dict:
    return {
        "ok": False,
        "method": method,
        "mbps": None,
        "bytes": None,
        "seconds": None,
        "url": url,
        "host": host,
        "error": error,
        "tried": [method] if method else [],
    }


def resolve_speedtest_url(inv: dict | None) -> str:
    settings = (inv or {}).get("settings") if isinstance(inv, dict) else None
    if isinstance(settings, dict):
        raw = settings.get("speedtestUrl")
        if isinstance(raw, str) and raw.strip():
            return raw.strip()
    nodes = (inv or {}).get("nodes") if isinstance(inv, dict) else None
    if isinstance(nodes, list):
        for node in nodes:
            if not isinstance(node, dict):
                continue
            if str(node.get("id") or "") == FILES_LAN or str(node.get("dns") or "") == FILES_LAN:
                return DEFAULT_SPEEDTEST_URL
    return DEFAULT_SPEEDTEST_URL


def parse_curl_writeout(text: str) -> dict | None:
    parts = (text or "").strip().split()
    if len(parts) != 4:
        return None
    try:
        code = int(parts[0])
        size = int(float(parts[1]))
        seconds = float(parts[2])
        bps = float(parts[3])
    except ValueError:
        return None
    return {"http_code": code, "bytes": size, "seconds": seconds, "mbps": bps * 8 / 1_000_000}


def parse_iperf3_json(text: str) -> dict | None:
    try:
        data = json.loads(text or "")
    except ValueError:
        return None
    end = data.get("end") if isinstance(data, dict) else None
    if not isinstance(end, dict):
        return None
    for key in ("sum_received", "sum_sent", "sum"):
        block = end.get(key)
        if not isinstance(block, dict) or block.get("bits_per_second") is None:
            continue
        try:
            bps = float(block["bits_per_second"])
            seconds = float(block.get("seconds") or 0)
        except (TypeError, ValueError):
            return None
        return {"mbps": bps / 1_000_000, "seconds": seconds, "bytes": None}
    return None


def curl_throughput(url: str, *, run: RunFn | None = None, timeout_s: float = CURL_TIMEOUT_S) -> dict:
    run = run or default_run
    if not url:
        return _fail("no speedtest URL", method="curl")
    got = run(
        [
            "curl",
            "-s",
            "--proto",
            "=http,https",
            "-o",
            "/dev/null",
            "--max-time",
            str(int(timeout_s)),
            "-w",
            "%{http_code} %{size_download} %{time_total} %{speed_download}",
            url,
        ],
        timeout_s + 1.0,
    )
    parsed = parse_curl_writeout(got.stdout)
    if not parsed:
        err = (got.stderr or "").strip() or "curl failed"
        return _fail(err[:160], method="curl", url=url)
    if not (200 <= parsed["http_code"] < 400):
        return _fail(f"HTTP {parsed['http_code']}", method="curl", url=url)
    if parsed["bytes"] <= 0:
        return _fail("empty download", method="curl", url=url)
    return {
        "ok": True,
        "method": "curl",
        "mbps": parsed["mbps"],
        "bytes": parsed["bytes"],
        "seconds": parsed["seconds"],
        "url": url,
        "host": None,
        "error": None,
        "tried": ["curl"],
    }


def _ssh_cmd(host: str, ssh_user: str | None, remote: str) -> list[str]:
    target = f"{ssh_user}@{host}" if ssh_user else host
    return [
        "ssh",
        "-o",
        "BatchMode=yes",
        "-o",
        "ConnectTimeout=3",
        "-o",
        "StrictHostKeyChecking=accept-new",
        "-o",
        "LogLevel=ERROR",
        target,
        remote,
    ]


def iperf3_oneshot(
    host: str,
    ssh_user: str | None = None,
    *,
    run: RunFn | None = None,
    spawn: SpawnFn | None = None,
    wait_s: float = 0.3,
) -> dict:
    run = run or default_run
    spawn = spawn or default_spawn
    if not host:
        return _fail("no host", method="iperf3")
    local = run(["iperf3", "--version"], 2.0)
    if local.returncode == 127:
        return _fail("iperf3 not local", method="iperf3", host=host)

    if is_local_host(host):
        server_cmd = ["iperf3", "-s", "-1"]
        client_host = "127.0.0.1"
    else:
        which = run(_ssh_cmd(host, ssh_user, "command -v iperf3"), 5.0)
        if which.returncode != 0 or not (which.stdout or "").strip():
            return _fail("iperf3 not on host", method="iperf3", host=host)
        server_cmd = _ssh_cmd(host, ssh_user, "iperf3 -s -1")
        client_host = host

    proc = None
    try:
        proc = spawn(server_cmd)
        if wait_s > 0:
            time.sleep(wait_s)
        client = run(["iperf3", "-c", client_host, "-t", "3", "-J"], IPERF_TIMEOUT_S)
    except OSError as e:
        return _fail(str(e)[:160], method="iperf3", host=host)
    finally:
        _stop(proc)
    parsed = parse_iperf3_json(client.stdout)
    if not parsed:
        err = ((client.stderr or client.stdout) or "iperf3 failed").strip()[:160]
        return _fail(err or "iperf3 failed", method="iperf3", host=host)
    return {
        "ok": True,
        "method": "iperf3",
        "mbps": parsed["mbps"],
        "bytes": parsed["bytes"],
        "seconds": parsed["seconds"],
        "url": None,
        "host": host,
        "error": None,
        "tried": ["iperf3"],
    }


def run_speedtest(
    *,
    url: str | None,
    host: str | None = None,
    ssh_user: str | None = None,
    run: RunFn | None = None,
    spawn: SpawnFn | None = None,
) -> dict:
    tried: list[str] = []
    errors: list[str] = []
    if url:
        tried.append("curl")
        got = curl_throughput(url, run=run)
        if got.get("ok"):
            got["tried"] = list(tried)
            return got
        if got.get("error"):
            errors.append(str(got["error"]))
    if host:
        tried.append("iperf3")
        got = iperf3_oneshot(host, ssh_user=ssh_user, run=run, spawn=spawn)
        if got.get("ok"):
            got["tried"] = list(tried)
            return got
        if got.get("error"):
            errors.append(str(got["error"]))
    if not tried:
        return _fail("no speedtest URL and no host")
    return {
        "ok": False,
        "method": None,
        "mbps": None,
        "bytes": None,
        "seconds": None,
        "url": url,
        "host": host,
        "error": " · ".join(errors) if errors else "speedtest failed",
        "tried": tried,
    }
