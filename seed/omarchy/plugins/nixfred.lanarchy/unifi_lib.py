"""Local UniFi OS / Network Application collector. No extra packages."""
from __future__ import annotations

import hashlib
import http.client
import http.cookiejar
import ipaddress
import json
import os
import re
import socket
import ssl
import urllib.error
import urllib.request
from dataclasses import dataclass, replace
from datetime import datetime, timezone
from typing import Any
from urllib.parse import urlparse

from plugin_paths import (
    SECRETS_FILE_MODE,
    assert_private_secrets_file,
    atomic_write_json,
    load_json_or,
    unifi_ca_path,
    unifi_secrets_path,
    unifi_tls_pin_path,
)

DEFAULT_URL = "https://192.168.1.1"
TIMEOUT_S = 8.0
# UniFi site/device JSON is small; a compromised endpoint must not fill the collector.
MAX_RESPONSE_BYTES = 2 * 1024 * 1024

# UniFi OS shortname → display. Unknowns fall back to the shortname itself.
MODEL_NAMES = {
    "UDRULT": "UCG Ultra",
    "UDMPRO": "UDM Pro",
    "UDMSE": "UDM SE",
    "UDM": "UDM",
    "UCGMAX": "UCG Max",
    "UXGPRO": "UXG Pro",
    "UCKP": "Cloud Key+",
}


def unifi_config(inv: dict | None) -> dict[str, Any]:
    settings = inv.get("settings") if isinstance(inv, dict) else None
    raw = settings.get("unifi") if isinstance(settings, dict) else None
    raw = raw if isinstance(raw, dict) else {}
    url = str(raw.get("url") or os.environ.get("UNIFI_URL") or DEFAULT_URL).rstrip("/")
    ca = str(raw.get("ca") or raw.get("caFile") or os.environ.get("UNIFI_CA") or "").strip()
    fingerprint = normalize_fingerprint(
        str(raw.get("fingerprint") or raw.get("sha256") or os.environ.get("UNIFI_FINGERPRINT") or "")
    )
    return {
        "url": url,
        "site": str(raw.get("site") or "default"),
        # TLS verification is never optional for credentialed calls. Leftover
        # inventory `verify: false` is ignored.
        "verify": True,
        "ca": ca,
        "fingerprint": fingerprint,
    }


def load_secrets() -> dict[str, str]:
    """JSON object or dotenv lines. Do not use load_json_or — a KEY= file is not corrupt."""
    data = _read_secrets_file(unifi_secrets_path())
    key = str(
        data.get("apiKey")
        or data.get("api_key")
        or data.get("UNIFI_KEY")
        or data.get("UNIFI_API_KEY")
        or os.environ.get("UNIFI_KEY")
        or os.environ.get("UNIFI_API_KEY")
        or ""
    ).strip()
    user = str(data.get("username") or data.get("UNIFI_USER") or os.environ.get("UNIFI_USER") or "").strip()
    password = str(data.get("password") or data.get("UNIFI_PASS") or os.environ.get("UNIFI_PASS") or "")
    out: dict[str, str] = {}
    if key:
        out["apiKey"] = key
    if user:
        out["username"] = user
    if password:
        out["password"] = password
    return out


def _read_secrets_file(path) -> dict[str, str]:
    try:
        assert_private_secrets_file(path)
    except PermissionError:
        return {}
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError:
        return {}
    raw = raw.strip()
    if not raw:
        return {}
    if raw.startswith("{") or raw.startswith("["):
        try:
            parsed = json.loads(raw)
        except ValueError:
            return {}
        if isinstance(parsed, dict):
            return {str(k): "" if v is None else str(v) for k, v in parsed.items()}
        return {}
    out: dict[str, str] = {}
    for line in raw.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        name, value = line.split("=", 1)
        out[name.strip()] = value.strip().strip("\"'")
    return out


def _read_limited(resp, *, max_bytes: int = MAX_RESPONSE_BYTES) -> bytes:
    """Read at most max_bytes; reject a body that would exceed the ceiling."""
    data = resp.read(max_bytes + 1)
    if len(data) > max_bytes:
        raise RuntimeError(f"unifi response exceeds {max_bytes} bytes")
    return data


def normalize_fingerprint(raw: str) -> str:
    """Accept `sha256:aa:bb:…` / bare hex; return 64 lowercase hex chars or ''."""
    text = str(raw or "").strip().lower()
    if text.startswith("sha256:"):
        text = text[7:]
    hexes = "".join(ch for ch in text if ch in "0123456789abcdef")
    return hexes if len(hexes) == 64 else ""


def cert_sha256(der: bytes) -> str:
    return hashlib.sha256(der).hexdigest()


def tls_origin(url: str) -> str:
    parsed = urlparse(url)
    host = parsed.hostname or ""
    scheme = parsed.scheme or "https"
    port = parsed.port or (443 if scheme == "https" else 80)
    return f"{scheme}://{host}:{port}"


def _host_is_ip(host: str) -> bool:
    try:
        ipaddress.ip_address(host)
        return True
    except ValueError:
        return False


@dataclass(frozen=True)
class TlsTrust:
    """How an HTTPS call proves it is talking to the UniFi controller."""

    mode: str  # system | ca | pin
    ca_file: str | None = None
    fingerprint: str | None = None
    tofu: bool = False
    origin: str = ""


def tls_trust_for(cfg: dict[str, Any]) -> TlsTrust:
    """Resolve CA / explicit pin / stored TOFU pin. Never returns 'off'."""
    origin = tls_origin(str(cfg.get("url") or ""))
    explicit_ca = str(cfg.get("ca") or "").strip()
    explicit_fp = normalize_fingerprint(str(cfg.get("fingerprint") or ""))
    if explicit_ca:
        return TlsTrust(mode="ca", ca_file=explicit_ca, origin=origin)
    if explicit_fp:
        return TlsTrust(mode="pin", fingerprint=explicit_fp, origin=origin)
    shipped = unifi_ca_path()
    if shipped.is_file():
        return TlsTrust(mode="ca", ca_file=str(shipped), origin=origin)
    stored = load_stored_pin(origin)
    if stored:
        return TlsTrust(mode="pin", fingerprint=stored, origin=origin)
    return TlsTrust(mode="system", tofu=True, origin=origin)


def load_stored_pin(origin: str) -> str:
    path = unifi_tls_pin_path()
    if not path.exists():
        return ""
    assert_private_secrets_file(path)
    data = load_json_or(path, {})
    if not isinstance(data, dict):
        return ""
    row = data.get(origin)
    if isinstance(row, dict):
        return normalize_fingerprint(str(row.get("sha256") or ""))
    return normalize_fingerprint(str(row or ""))


def persist_tofu_pin(origin: str, fingerprint: str) -> None:
    path = unifi_tls_pin_path()
    existing: dict[str, Any] = {}
    if path.exists():
        assert_private_secrets_file(path)
        loaded = load_json_or(path, {})
        if isinstance(loaded, dict):
            existing = loaded
    prior = ""
    row = existing.get(origin)
    if isinstance(row, dict):
        prior = normalize_fingerprint(str(row.get("sha256") or ""))
    elif row:
        prior = normalize_fingerprint(str(row))
    if prior and prior != fingerprint:
        raise ssl.SSLCertVerificationError("unifi TLS pin mismatch")
    existing[origin] = {
        "sha256": fingerprint,
        "capturedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    atomic_write_json(path, existing)
    os.chmod(path, SECRETS_FILE_MODE)


def capture_peer_fingerprint(url: str) -> str:
    """TLS handshake only — no HTTP, no credentials."""
    parsed = urlparse(url)
    host = parsed.hostname or ""
    if not host:
        raise RuntimeError("unifi TLS: missing host")
    port = parsed.port or 443
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    with socket.create_connection((host, port), timeout=TIMEOUT_S) as sock:
        with ctx.wrap_socket(sock, server_hostname=host) as ssock:
            der = ssock.getpeercert(binary_form=True) or b""
    if not der:
        raise RuntimeError("unifi TLS: peer sent no certificate")
    return cert_sha256(der)


def _is_verify_error(exc: BaseException) -> bool:
    if isinstance(exc, ssl.SSLCertVerificationError):
        return True
    if isinstance(exc, urllib.error.URLError) and isinstance(exc.reason, ssl.SSLError):
        return True
    return isinstance(exc, ssl.SSLError) and "CERTIFICATE" in str(exc).upper()


def _context_for(trust: TlsTrust) -> ssl.SSLContext:
    """Public-CA or user-CA context. Pin mode uses _PinnedHTTPSHandler instead."""
    if trust.mode == "ca":
        ctx = ssl.create_default_context(cafile=trust.ca_file)
    else:
        ctx = ssl.create_default_context()
    ctx.verify_mode = ssl.CERT_REQUIRED
    host = urlparse(trust.origin).hostname or ""
    ctx.check_hostname = bool(host) and not _host_is_ip(host)
    return ctx


class _PinnedHTTPSHandler(urllib.request.HTTPSHandler):
    """Handshake, then require the leaf SHA-256 before any HTTP bytes go out."""

    def __init__(self, fingerprint: str):
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        super().__init__(context=ctx)
        self._fingerprint = fingerprint

    def https_open(self, req):
        return self.do_open(self._pinned_connection, req)

    def _pinned_connection(self, host, **kwargs):
        kwargs["context"] = self._context
        conn = http.client.HTTPSConnection(host, **kwargs)
        orig_connect = conn.connect

        def connect_and_pin() -> None:
            orig_connect()
            der = (conn.sock.getpeercert(binary_form=True) if conn.sock else b"") or b""
            got = cert_sha256(der)
            if got != self._fingerprint:
                raise ssl.SSLCertVerificationError(
                    f"unifi TLS pin mismatch (got {got[:16]}…)"
                )

        conn.connect = connect_and_pin  # type: ignore[method-assign]
        return conn


def _opener_for(trust: TlsTrust, *extra: urllib.request.BaseHandler) -> urllib.request.OpenerDirector:
    if trust.mode == "pin":
        if not trust.fingerprint:
            raise RuntimeError("unifi TLS pin is empty")
        handlers: list[urllib.request.BaseHandler] = [_PinnedHTTPSHandler(trust.fingerprint)]
    else:
        handlers = [urllib.request.HTTPSHandler(context=_context_for(trust))]
    handlers.extend(extra)
    return urllib.request.build_opener(*handlers)


def _tofu_upgrade(trust: TlsTrust, url: str) -> TlsTrust:
    fingerprint = capture_peer_fingerprint(url)
    persist_tofu_pin(trust.origin or tls_origin(url), fingerprint)
    return replace(trust, mode="pin", fingerprint=fingerprint, tofu=False)


def collect_unifi(inv: dict | None, nodes: list[dict] | None = None) -> dict[str, Any]:
    """Soft-fail snapshot block. Never writes inventory."""
    cfg = unifi_config(inv)
    secrets = load_secrets()
    trust = tls_trust_for(cfg)
    if secrets and urlparse(cfg["url"]).scheme != "https":
        system = None
        auth_error = "unifi credentials require https"
    else:
        system = fetch_system(cfg["url"], trust=trust)
        trust = tls_trust_for(cfg)
        auth_error = None
    out: dict[str, Any] = {
        "ok": bool(system),
        "auth": "none",
        "url": cfg["url"],
        "name": None,
        "model": None,
        "shortname": None,
        "mac": None,
        "devices": [],
        "clients": [],
        "discover": [],
        "error": auth_error or (None if system else "unreachable"),
    }
    if system:
        out.update(_project_system(system))
        if not auth_error:
            out["error"] = None
    try:
        if auth_error:
            raise RuntimeError(auth_error)
        if secrets.get("apiKey"):
            devices, clients = _via_apikey(cfg, secrets["apiKey"], trust)
            out["auth"] = "apikey"
            out["devices"] = devices
            out["clients"] = clients
            out["ok"] = True
            out["error"] = None
        elif secrets.get("username") and secrets.get("password"):
            devices, clients = _via_login(cfg, secrets["username"], secrets["password"], trust)
            out["auth"] = "login"
            out["devices"] = devices
            out["clients"] = clients
            out["ok"] = True
            out["error"] = None
    except Exception as e:
        out["error"] = str(e)[:160]
    known = known_from(nodes or [])
    out["discover"] = _discover(out, known)
    return out


def fetch_system(base: str, *, trust: TlsTrust) -> dict | None:
    try:
        payload = _json_get(f"{base.rstrip('/')}/api/system", trust=trust)
    except Exception:
        return None
    return payload if isinstance(payload, dict) else None


def _project_system(system: dict) -> dict[str, Any]:
    hardware = system.get("hardware") if isinstance(system.get("hardware"), dict) else {}
    short = str(hardware.get("shortname") or system.get("shortname") or "") or None
    model = None
    if short:
        model = MODEL_NAMES.get(short, short)
    mac = str(system.get("mac") or "").strip() or None
    if mac:
        mac = fmt_mac(mac)
    return {
        "name": str(system.get("name") or system.get("hostname") or "") or None,
        "model": model,
        "shortname": short,
        "mac": mac,
    }


def _via_apikey(cfg: dict, key: str, trust: TlsTrust) -> tuple[list[dict], list[dict]]:
    headers = {"X-API-KEY": key, "Accept": "application/json"}
    base = cfg["url"]
    sites = _json_get(f"{base}/proxy/network/integration/v1/sites", headers=headers, trust=trust)
    site_id = _pick_site_id(sites, cfg["site"])
    if site_id:
        try:
            devices = _items(
                _json_get(
                    f"{base}/proxy/network/integration/v1/sites/{site_id}/devices",
                    headers=headers,
                    trust=trust,
                )
            )
            clients = _items(
                _json_get(
                    f"{base}/proxy/network/integration/v1/sites/{site_id}/clients",
                    headers=headers,
                    trust=trust,
                )
            )
            return [_project_device(d) for d in devices], [_project_client(c) for c in clients]
        except Exception:
            pass
    # Official integration path missing or site-less — classic endpoints still accept the key on some builds.
    return _classic_stat(base, cfg["site"], headers=headers, trust=trust)


def _via_login(cfg: dict, username: str, password: str, trust: TlsTrust) -> tuple[list[dict], list[dict]]:
    opener, csrf = _login(cfg["url"], username, password, trust=trust)
    headers = {"Accept": "application/json"}
    if csrf:
        headers["X-CSRF-Token"] = csrf
    return _classic_stat(cfg["url"], cfg["site"], headers=headers, trust=trust, opener=opener)


def _classic_stat(
    base: str,
    site: str,
    *,
    headers: dict[str, str],
    trust: TlsTrust,
    opener: urllib.request.OpenerDirector | None = None,
) -> tuple[list[dict], list[dict]]:
    devices = _items(
        _json_get(
            f"{base}/proxy/network/api/s/{site}/stat/device",
            headers=headers,
            trust=trust,
            opener=opener,
        )
    )
    clients = _items(
        _json_get(
            f"{base}/proxy/network/api/s/{site}/stat/sta",
            headers=headers,
            trust=trust,
            opener=opener,
        )
    )
    return [_project_device(d) for d in devices], [_project_client(c) for c in clients]


def _login(
    base: str, username: str, password: str, *, trust: TlsTrust
) -> tuple[urllib.request.OpenerDirector, str | None]:
    jar = http.cookiejar.CookieJar()
    opener = _opener_for(trust, urllib.request.HTTPCookieProcessor(jar))
    req = urllib.request.Request(
        f"{base.rstrip('/')}/api/auth/login",
        data=json.dumps({"username": username, "password": password}).encode(),
        headers={"Content-Type": "application/json", "Accept": "application/json"},
        method="POST",
    )
    try:
        with opener.open(req, timeout=TIMEOUT_S) as resp:
            token = resp.headers.get("X-CSRF-Token") or resp.headers.get("X-Updated-CSRF-Token")
            body = _read_limited(resp)
    except Exception as e:
        if trust.tofu and _is_verify_error(e):
            trust = _tofu_upgrade(trust, base)
            opener = _opener_for(trust, urllib.request.HTTPCookieProcessor(jar))
            with opener.open(req, timeout=TIMEOUT_S) as resp:
                token = resp.headers.get("X-CSRF-Token") or resp.headers.get("X-Updated-CSRF-Token")
                body = _read_limited(resp)
        else:
            raise
    if not token:
        try:
            parsed = json.loads(body.decode() or "{}")
            if isinstance(parsed, dict):
                token = parsed.get("csrfToken") or parsed.get("token")
        except ValueError:
            token = None
    if not token:
        for cookie in jar:
            if cookie.name.upper() == "TOKEN":
                token = cookie.value
                break
    return opener, str(token) if token else None


def _json_get(
    url: str,
    *,
    headers: dict[str, str] | None = None,
    trust: TlsTrust,
    opener: urllib.request.OpenerDirector | None = None,
) -> Any:
    hdrs = {"Accept": "application/json"}
    if headers:
        hdrs.update(headers)
    req = urllib.request.Request(url, headers=hdrs, method="GET")
    live_trust = trust
    live_opener = opener if opener is not None else _opener_for(live_trust)
    try:
        with live_opener.open(req, timeout=TIMEOUT_S) as resp:
            raw = _read_limited(resp).decode("utf-8", errors="replace")
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"unifi {e.code}") from e
    except Exception as e:
        if opener is None and live_trust.tofu and _is_verify_error(e):
            live_trust = _tofu_upgrade(live_trust, url)
            live_opener = _opener_for(live_trust)
            with live_opener.open(req, timeout=TIMEOUT_S) as resp:
                raw = _read_limited(resp).decode("utf-8", errors="replace")
        else:
            raise
    if not raw:
        return {}
    return json.loads(raw)


def _items(payload: Any) -> list[dict]:
    if isinstance(payload, list):
        return [x for x in payload if isinstance(x, dict)]
    if isinstance(payload, dict):
        for key in ("data", "items"):
            val = payload.get(key)
            if isinstance(val, list):
                return [x for x in val if isinstance(x, dict)]
    return []


def _pick_site_id(payload: Any, wanted: str) -> str | None:
    items = _items(payload)
    if not items:
        return None
    for site in items:
        names = {
            str(site.get("id") or ""),
            str(site.get("internalReference") or ""),
            str(site.get("name") or ""),
        }
        if wanted in names:
            return str(site.get("id") or "") or None
    return str(items[0].get("id") or "") or None


def _project_device(row: dict) -> dict[str, Any]:
    # This firmware reports OFFLINE for gear that is demonstrably reachable, so a
    # reported state is only believed when it says something is up. "down" from
    # the controller becomes "unknown" and the collector's own probe decides:
    # drawing a working access point as dead is worse than saying we are unsure.
    state_raw = row.get("state") if "state" in row else row.get("status")
    if state_raw in (1, "1", "CONNECTED", "connected", "online", "up", "ONLINE"):
        state = "up"
    elif row.get("adopted") is False:
        state = "unknown"
    else:
        state = "unknown"
    name = str(row.get("name") or row.get("model") or row.get("mac") or "device")
    # The integration API states the role outright; fall back to the model name.
    features = row.get("features")
    if isinstance(features, list) and features:
        feats = {str(f).lower() for f in features}
        if "gateway" in feats or "switching" in feats and "accesspoint" in feats:
            kind = "gateway"
        elif "accesspoint" in feats:
            kind = "ap"
        elif "switching" in feats:
            kind = "switch"
        else:
            kind = str(row.get("model") or "device").lower()
    else:
        kind = str(row.get("type") or row.get("model") or "device").lower()
    if "uap" in kind or "ap" in kind:
        kind = "ap"
    elif "usw" in kind or "switch" in kind:
        kind = "switch"
    elif any(x in kind for x in ("ugw", "udm", "ucg", "uxg", "gateway")):
        kind = "gateway"
    mac = fmt_mac(str(row.get("mac") or row.get("macAddress") or ""))
    ip = str(row.get("ip") or row.get("ipAddress") or row.get("ip_address") or "") or None
    return {
        "id": str(row.get("id") or row.get("mac") or name),
        "name": name,
        "model": str(row.get("model") or "") or None,
        "kind": kind,
        "mac": mac,
        "ip": ip,
        "state": state,
    }


_MAC_TAIL = re.compile(r"\s+[0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){1,5}\s*$")
_NOISE_CLIENT = re.compile(
    r"(iphone|ipad|ipod|android|pixel\b|galaxy\b|wyze|camera|\bcam\b|chromecast|"
    r"google\s*wifi|apple\s*watch|fire\s*tv|roku|\btv\b|sonos|echo\b|kindle)",
    re.I,
)


def client_stem(name: str) -> str:
    """UniFi often labels clients `hostname ab:cd` — strip the MAC tail for matching."""
    return _MAC_TAIL.sub("", str(name or "").strip()).strip() or str(name or "").strip()


def classify_client(client: dict) -> str | None:
    """Wired UniFi clients are the real boxes/VMs; skip phone/IoT noise; wireless leftovers stay hosts."""
    label = str(client.get("name") or client.get("hostname") or "")
    if _NOISE_CLIENT.search(label):
        return None
    if client.get("wireless"):
        return "host"
    return "machine"


def _project_client(row: dict) -> dict[str, Any]:
    link = str(row.get("type") or "").upper()
    wireless = link == "WIRELESS" or bool(
        row.get("is_wired") is False or row.get("wireless") or row.get("essid") or row.get("ap_mac")
    )
    if row.get("is_wired") is True or link == "WIRED":
        wireless = False
    name = str(row.get("name") or row.get("hostname") or row.get("ip") or row.get("ipAddress") or row.get("mac") or row.get("macAddress") or "client")
    return {
        "name": name,
        "hostname": str(row.get("hostname") or "") or None,
        "ip": str(row.get("ip") or row.get("ipAddress") or "") or None,
        "mac": fmt_mac(str(row.get("mac") or row.get("macAddress") or "")),
        "wireless": wireless,
        "network": str(row.get("network") or row.get("network_name") or "") or None,
    }


def known_from(nodes: list[dict]) -> dict[str, set[str]]:
    ips: set[str] = set()
    macs: set[str] = set()
    hosts: set[str] = set()
    for node in nodes:
        if node.get("ip"):
            ips.add(str(node["ip"]).strip())
        if node.get("mac"):
            macs.add(fmt_mac(str(node["mac"])) or "")
        for key in ("dns", "id", "label"):
            val = str(node.get(key) or "").strip().lower()
            if val:
                hosts.add(val)
                hosts.add(val.removesuffix(".lan"))
                hosts.add(val.removesuffix(".local"))
                stem = client_stem(val).lower()
                if stem:
                    hosts.add(stem)
                    hosts.add(stem.removesuffix(".lan"))
    macs.discard("")
    return {"ips": ips, "macs": macs, "hosts": hosts}


def _host_known(name: str, known: dict[str, set[str]]) -> bool:
    raw = str(name or "").strip().lower()
    if not raw:
        return False
    stem = client_stem(raw).lower()
    for cand in (raw, stem, raw.removesuffix(".lan"), stem.removesuffix(".lan"), stem.split()[0] if stem else ""):
        if cand and cand in known["hosts"]:
            return True
    return False


def _discover(unifi: dict, known: dict[str, set[str]]) -> list[dict]:
    out: list[dict] = []
    seen: set[str] = set()
    host = urlparse(str(unifi.get("url") or "")).hostname or ""
    if host and host not in known["ips"]:
        label = str(unifi.get("name") or "UniFi gateway")
        key = host
        seen.add(key)
        out.append(
            {
                "source": "unifi",
                "kind": "gateway",
                "type": "machine",
                "label": label,
                "host": None,
                "ip": host,
                "mac": unifi.get("mac"),
            }
        )
    for client in unifi.get("clients") or []:
        role = classify_client(client)
        if role is None:
            continue
        ip = str(client.get("ip") or "")
        mac = fmt_mac(str(client.get("mac") or "")) or ""
        hostn = str(client.get("hostname") or client.get("name") or "").strip()
        label = client_stem(str(client.get("name") or hostn or ip or mac))
        if ip and ip in known["ips"]:
            continue
        if mac and mac in known["macs"]:
            continue
        if _host_known(hostn, known) or _host_known(label, known):
            continue
        key = ip or mac or hostn.lower()
        if not key or key in seen:
            continue
        seen.add(key)
        out.append(
            {
                "source": "unifi",
                "kind": "client",
                "type": role,
                "label": label or ip or mac,
                "host": client.get("hostname") or None,
                "ip": ip or None,
                "mac": mac or None,
                "wireless": bool(client.get("wireless")),
            }
        )
        if len(out) >= 24:
            break
    return out


def fmt_mac(raw: str) -> str | None:
    hexes = "".join(ch for ch in raw.lower() if ch in "0123456789abcdef")
    if len(hexes) != 12:
        return raw.lower() if raw else None
    return ":".join(hexes[i : i + 2] for i in range(0, 12, 2))
