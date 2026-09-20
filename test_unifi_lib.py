#!/usr/bin/env python3
"""unifi_lib: project system/clients without talking to a controller."""
from __future__ import annotations

import hashlib
import http.server
import os
import shutil
import ssl
import subprocess
import tempfile
import threading
from pathlib import Path

from unifi_lib import (
    TlsTrust,
    _context_for,
    _discover,
    _host_known,
    _json_get,
    _read_limited,
    capture_peer_fingerprint,
    cert_sha256,
    classify_client,
    client_stem,
    fmt_mac,
    load_stored_pin,
    normalize_fingerprint,
    persist_tofu_pin,
    _project_client,
    _project_device,
    _project_system,
    _read_secrets_file,
    tls_origin,
    tls_trust_for,
    unifi_config,
)


SYSTEM = {
    "hardware": {"shortname": "UDRULT"},
    "name": "redUltra",
    "mac": "1C6A1B18B4D9",
}


def test_project_system() -> None:
    out = _project_system(SYSTEM)
    assert out["name"] == "redUltra"
    assert out["model"] == "UCG Ultra"
    assert out["mac"] == "1c:6a:1b:18:b4:d9"


def test_project_device_and_client() -> None:
    ap = _project_device({"name": "office", "type": "uap", "mac": "aabbccddeeff", "state": 1, "ip": "192.168.1.8"})
    assert ap["kind"] == "ap" and ap["state"] == "up"
    sta = _project_client({"hostname": "tv", "ip": "192.168.1.40", "mac": "112233445566", "is_wired": False})
    assert sta["wireless"] is True
    assert sta["name"] == "tv"
    # UniFi OS local API uses macAddress / ipAddress
    os_cli = _project_client(
        {"name": "homeassistant be:b6", "type": "WIRED", "ipAddress": "192.168.1.178", "macAddress": "dc:a6:32:27:be:b6"}
    )
    assert os_cli["ip"] == "192.168.1.178"
    assert os_cli["mac"] == "dc:a6:32:27:be:b6"
    assert os_cli["wireless"] is False


def test_client_stem_and_classify() -> None:
    assert client_stem("homeassistant be:b6") == "homeassistant"
    assert client_stem("yanagiba 09:ac") == "yanagiba"
    assert classify_client({"name": "yanagiba 09:ac", "wireless": False}) == "machine"
    assert classify_client({"name": "homeassistant be:b6", "wireless": False}) == "machine"
    assert classify_client({"name": "Wyze Cam 81:4f", "wireless": False}) is None
    assert classify_client({"name": "aka ee:af", "wireless": True}) == "host"


def test_discover_skips_known_and_noise() -> None:
    unifi = {
        "url": "https://192.168.1.1",
        "name": "redUltra",
        "mac": "1c:6a:1b:18:b4:d9",
        "clients": [
            {"name": "deba 2e:a6", "ip": "192.168.1.10", "mac": "aa:bb:cc:dd:ee:ff", "wireless": False},
            {"name": "Living TV", "ip": "192.168.1.77", "mac": "11:22:33:44:55:66", "wireless": True},
            {"name": "homeassistant be:b6", "ip": "192.168.1.178", "mac": "dc:a6:32:27:be:b6", "wireless": False},
            {"name": "yanagiba 09:ac", "ip": "192.168.1.92", "mac": "8c:dc:d4:4e:09:ac", "wireless": False},
        ],
    }
    known = {
        "ips": {"192.168.1.1", "192.168.1.10"},
        "macs": set(),
        "hosts": {"deba"},
    }
    found = _discover(unifi, known)
    labels = [x["label"] for x in found]
    assert "redUltra" not in labels
    assert "deba" not in labels
    assert "Living TV" not in labels
    assert "homeassistant" in labels
    assert "yanagiba" in labels
    ha = next(x for x in found if x["label"] == "homeassistant")
    assert ha["type"] == "machine" and ha["ip"] == "192.168.1.178"
    assert _host_known("aka ee:ae", {"hosts": {"aka"}}) is True


def test_config_default_url() -> None:
    assert unifi_config({})["url"] == "https://192.168.1.1"
    assert unifi_config({"settings": {"unifi": {"url": "https://udm.lan"}}})["url"] == "https://udm.lan"
    cfg = unifi_config({"settings": {"unifi": {"verify": False, "fingerprint": "sha256:" + ("ab" * 32)}}})
    assert cfg["verify"] is True
    assert cfg["fingerprint"] == "ab" * 32


def test_normalize_fingerprint() -> None:
    raw = "SHA256:" + ":".join(["ab"] * 32)
    assert normalize_fingerprint(raw) == "ab" * 32
    assert normalize_fingerprint("nope") == ""
    assert tls_origin("https://192.168.1.1/api") == "https://192.168.1.1:443"


def test_trust_defaults_to_system_tofu() -> None:
    with tempfile.TemporaryDirectory() as td:
        os.environ["XDG_STATE_HOME"] = td
        try:
            trust = tls_trust_for({"url": "https://192.168.1.1"})
            assert trust.mode == "system" and trust.tofu is True
            ctx = _context_for(trust)
            assert ctx.verify_mode == ssl.CERT_REQUIRED
        finally:
            os.environ.pop("XDG_STATE_HOME", None)


def test_trust_prefers_ca_and_pin() -> None:
    trust = tls_trust_for({"url": "https://udm.lan", "ca": "/tmp/unifi-ca.pem"})
    assert trust.mode == "ca" and trust.ca_file == "/tmp/unifi-ca.pem"
    pin = "cd" * 32
    trust = tls_trust_for({"url": "https://udm.lan", "fingerprint": pin})
    assert trust.mode == "pin" and trust.fingerprint == pin


def test_tofu_pin_roundtrip_and_mismatch() -> None:
    with tempfile.TemporaryDirectory() as td:
        os.environ["XDG_STATE_HOME"] = td
        try:
            origin = "https://192.168.1.1:443"
            persist_tofu_pin(origin, "ab" * 32)
            assert load_stored_pin(origin) == "ab" * 32
            try:
                persist_tofu_pin(origin, "cd" * 32)
                raise AssertionError("expected pin mismatch")
            except ssl.SSLCertVerificationError:
                pass
            trust = tls_trust_for({"url": "https://192.168.1.1"})
            assert trust.mode == "pin" and trust.fingerprint == "ab" * 32
        finally:
            os.environ.pop("XDG_STATE_HOME", None)


def _self_signed_pair(directory: Path) -> tuple[Path, Path, str]:
    key = directory / "key.pem"
    cert = directory / "cert.pem"
    subprocess.run(
        [
            "openssl",
            "req",
            "-x509",
            "-newkey",
            "rsa:2048",
            "-keyout",
            str(key),
            "-out",
            str(cert),
            "-days",
            "1",
            "-nodes",
            "-subj",
            "/CN=127.0.0.1",
        ],
        check=True,
        capture_output=True,
    )
    der = subprocess.check_output(["openssl", "x509", "-in", str(cert), "-outform", "DER"])
    return key, cert, hashlib.sha256(der).hexdigest()


class _JsonHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802
        body = b'{"name":"redUltra"}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt: str, *args: object) -> None:
        return


def test_pinned_https_accepts_and_rejects() -> None:
    if shutil.which("openssl") is None:
        return
    with tempfile.TemporaryDirectory() as td:
        base = Path(td)
        key, cert, fingerprint = _self_signed_pair(base)
        assert fingerprint == cert_sha256(
            subprocess.check_output(["openssl", "x509", "-in", str(cert), "-outform", "DER"])
        )
        httpd = http.server.HTTPServer(("127.0.0.1", 0), _JsonHandler)
        httpd.handle_error = lambda *args, **kwargs: None  # pin-mismatch closes the socket
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(str(cert), str(key))
        httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
        port = httpd.server_address[1]
        thread = threading.Thread(target=httpd.serve_forever, daemon=True)
        thread.start()
        try:
            url = f"https://127.0.0.1:{port}/api/system"
            assert capture_peer_fingerprint(url) == fingerprint
            payload = _json_get(url, trust=TlsTrust(mode="pin", fingerprint=fingerprint, origin=tls_origin(url)))
            assert payload["name"] == "redUltra"
            try:
                _json_get(url, trust=TlsTrust(mode="pin", fingerprint="ab" * 32, origin=tls_origin(url)))
                raise AssertionError("expected pin mismatch")
            except ssl.SSLCertVerificationError:
                pass
            except Exception as e:
                assert "pin mismatch" in str(e).lower() or isinstance(
                    getattr(e, "reason", None), ssl.SSLCertVerificationError
                )
        finally:
            httpd.shutdown()
            httpd.server_close()


def test_fmt_mac() -> None:
    assert fmt_mac("1C6A1B18B4D9") == "1c:6a:1b:18:b4:d9"


def test_read_secrets_dotenv_and_json() -> None:
    with tempfile.TemporaryDirectory() as td:
        base = Path(td)
        envf = base / "unifi.env"
        envf.write_text("UNIFI_KEY=abc123\n", encoding="utf-8")
        envf.chmod(0o600)
        assert _read_secrets_file(envf)["UNIFI_KEY"] == "abc123"
        jsf = base / "unifi.json"
        jsf.write_text('{"apiKey":"xyz"}', encoding="utf-8")
        jsf.chmod(0o600)
        assert _read_secrets_file(jsf)["apiKey"] == "xyz"


def test_read_secrets_rejects_world_readable_and_symlink() -> None:
    with tempfile.TemporaryDirectory() as td:
        base = Path(td)
        open_file = base / "open.json"
        open_file.write_text('{"apiKey":"leak"}', encoding="utf-8")
        open_file.chmod(0o644)
        assert _read_secrets_file(open_file) == {}

        real = base / "real.json"
        real.write_text('{"apiKey":"ok"}', encoding="utf-8")
        real.chmod(0o600)
        link = base / "link.json"
        link.symlink_to(real)
        assert _read_secrets_file(link) == {}


def test_read_limited_rejects_overflow() -> None:
    class FakeResp:
        def __init__(self, payload: bytes):
            self._payload = payload

        def read(self, n: int = -1) -> bytes:
            if n < 0:
                return self._payload
            return self._payload[:n]

    assert _read_limited(FakeResp(b"abc"), max_bytes=3) == b"abc"
    try:
        _read_limited(FakeResp(b"abcd"), max_bytes=3)
        raise AssertionError("expected overflow rejection")
    except RuntimeError as e:
        assert "exceeds" in str(e)


if __name__ == "__main__":
    test_project_system()
    test_project_device_and_client()
    test_client_stem_and_classify()
    test_discover_skips_known_and_noise()
    test_config_default_url()
    test_normalize_fingerprint()
    test_trust_defaults_to_system_tofu()
    test_trust_prefers_ca_and_pin()
    test_tofu_pin_roundtrip_and_mismatch()
    test_pinned_https_accepts_and_rejects()
    test_fmt_mac()
    test_read_secrets_dotenv_and_json()
    test_read_secrets_rejects_world_readable_and_symlink()
    test_read_limited_rejects_overflow()
    print("ok")
