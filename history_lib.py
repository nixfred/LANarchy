"""Local RTT ring + status events (OmarPlugs-5oy.9 / 5oy.6)."""
from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

from plugin_paths import atomic_write_json, history_path, load_json_or

HISTORY_SCHEMA = 1
DEFAULT_RETENTION_H = 24


def _parse_ts(ts: str) -> datetime | None:
    try:
        return datetime.fromisoformat(ts)
    except (TypeError, ValueError):
        return None


def _now_iso() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def empty_history(*, retention_hours: int = DEFAULT_RETENTION_H, probe_interval_sec: int = 15) -> dict:
    return {
        "schemaVersion": HISTORY_SCHEMA,
        "retentionHours": retention_hours,
        "probeIntervalSec": probe_interval_sec,
        "series": {},
        "events": [],
    }


def load_history(path: Path | None = None) -> dict:
    p = path or history_path()
    raw = load_json_or(p, None)
    if not isinstance(raw, dict):
        return empty_history()
    raw.setdefault("schemaVersion", HISTORY_SCHEMA)
    raw.setdefault("series", {})
    raw.setdefault("events", [])
    return raw


def _max_samples(retention_hours: int, probe_interval_sec: int) -> int:
    cap = (retention_hours * 3600) // max(1, probe_interval_sec)
    return max(96, cap)


def _trim(history: dict) -> None:
    retention = int(history.get("retentionHours") or DEFAULT_RETENTION_H)
    cutoff = datetime.now(timezone.utc).astimezone() - timedelta(hours=retention)
    series = history.get("series")
    if isinstance(series, dict):
        for nid, block in list(series.items()):
            if not isinstance(block, dict):
                del series[nid]
                continue
            samples = block.get("samples")
            if not isinstance(samples, list):
                block["samples"] = []
                samples = block["samples"]
            kept = []
            for s in samples:
                if not isinstance(s, dict):
                    continue
                ts = _parse_ts(str(s.get("ts") or ""))
                if ts and ts >= cutoff:
                    kept.append(s)
            max_n = _max_samples(retention, int(history.get("probeIntervalSec") or 15))
            if len(kept) > max_n:
                kept = kept[-max_n:]
            block["samples"] = kept
    events = history.get("events")
    if isinstance(events, list):
        kept_ev = []
        for ev in events:
            if not isinstance(ev, dict):
                continue
            ts = _parse_ts(str(ev.get("ts") or ""))
            if ts and ts >= cutoff:
                kept_ev.append(ev)
        history["events"] = kept_ev[-500:]


def _block(history: dict, node_id: str) -> dict:
    series = history.setdefault("series", {})
    return series.setdefault(str(node_id), {"samples": []})


def last_counters(history: dict, node_id: str) -> dict | None:
    block = _block(history, node_id)
    c = block.get("counters")
    return c if isinstance(c, dict) else None


def set_last_counters(history: dict, node_id: str, counters: dict) -> None:
    _block(history, node_id)["counters"] = dict(counters)


def node_meta(history: dict, node_id: str) -> dict:
    m = _block(history, node_id).get("meta")
    return m if isinstance(m, dict) else {}


def set_node_meta(history: dict, node_id: str, patch: dict) -> None:
    block = _block(history, node_id)
    meta = block.get("meta") if isinstance(block.get("meta"), dict) else {}
    meta.update(patch)
    block["meta"] = meta


def append_probe_sample(
    history: dict,
    node_id: str,
    *,
    status: str,
    rtt_ms: float | None,
    ts: str | None = None,
    extra: dict | None = None,
) -> str | None:
    """Append sample; return previous status if transition."""
    nid = str(node_id or "")
    if not nid:
        return None
    block = _block(history, nid)
    samples = block.setdefault("samples", [])
    prev = samples[-1].get("status") if samples else None
    sample: dict[str, Any] = {"ts": ts or _now_iso(), "status": status}
    if rtt_ms is not None:
        sample["rtt_ms"] = rtt_ms
    if extra:
        rates = extra.get("rates")
        if isinstance(rates, dict):
            sample["rx_bps"] = rates.get("rx_bps")
            sample["tx_bps"] = rates.get("tx_bps")
    samples.append(sample)
    if prev is not None and prev != status:
        history.setdefault("events", []).append(
            {"ts": sample["ts"], "id": nid, "from": prev, "to": status}
        )
    _trim(history)
    return str(prev) if prev is not None else None


def recent_events(history: dict, limit: int = 6) -> list[dict]:
    """Newest-first status transitions, for a "what just changed" strip.

    The events ring already records every flap; nothing surfaced it, so a box
    bouncing up and down every few minutes looked identical to a healthy one.
    """
    events = history.get("events") if isinstance(history, dict) else None
    if not isinstance(events, list):
        return []
    rows = [e for e in events if isinstance(e, dict) and e.get("id") and e.get("to")]
    rows.sort(key=lambda e: str(e.get("ts") or ""), reverse=True)
    return [
        {
            "ts": str(e.get("ts") or ""),
            "id": str(e.get("id") or ""),
            "from": str(e.get("from") or "unknown"),
            "to": str(e.get("to") or "unknown"),
        }
        for e in rows[: max(0, int(limit))]
    ]


def flap_counts(history: dict, within_hours: float = 1.0) -> dict[str, int]:
    """Transitions per node in the recent window. A high count is instability."""
    events = history.get("events") if isinstance(history, dict) else None
    if not isinstance(events, list):
        return {}
    cutoff = datetime.now(timezone.utc) - timedelta(hours=float(within_hours))
    counts: dict[str, int] = {}
    for e in events:
        if not isinstance(e, dict) or not e.get("id"):
            continue
        when = _parse_ts(str(e.get("ts") or ""))
        if when is None or when < cutoff:
            continue
        counts[str(e["id"])] = counts.get(str(e["id"]), 0) + 1
    return counts


def sparkline_batch(history: dict, node_ids: list[str], n: int = 32) -> dict:
    """Every series the panel needs, in one read of the history we already hold.

    Each Sparkline used to launch `history_cli.py` every four seconds and parse
    the whole history file again, so a lab of forty rows meant roughly ten
    Python processes a second to draw some lines.
    """
    out: dict[str, dict] = {}
    for node_id in node_ids or []:
        nid = str(node_id or "")
        if not nid or nid in out:
            continue
        payload = sparkline_payload(history, nid, n)
        if any(v is not None for v in payload["values"]) or any(
            v is not None for v in payload["rx_bps"]
        ):
            out[nid] = {"values": payload["values"], "rx_bps": payload["rx_bps"]}
    return out


def save_history(history: dict, path: Path | None = None) -> Path:
    return atomic_write_json(path or history_path(), history, indent=None)


def _num_or_none(raw: Any) -> float | None:
    if raw is None:
        return None
    try:
        return float(raw)
    except (TypeError, ValueError):
        return None


def _tail_samples(history: dict, node_id: str, n: int) -> list[dict]:
    series = history.get("series") if isinstance(history.get("series"), dict) else {}
    block = series.get(str(node_id)) or {}
    samples = block.get("samples") if isinstance(block, dict) else []
    if not isinstance(samples, list):
        return []
    return [s for s in samples[-max(0, n):] if isinstance(s, dict)]


def sparkline_values(history: dict, node_id: str, n: int = 32) -> list[float | None]:
    return [_num_or_none(s.get("rtt_ms")) for s in _tail_samples(history, node_id, n)]


def sparkline_payload(history: dict, node_id: str, n: int = 32) -> dict:
    """Last n samples. values is rtt_ms. rx_bps is omitted-as-null, never invented."""
    tail = _tail_samples(history, node_id, n)
    return {
        "id": str(node_id),
        "values": [_num_or_none(s.get("rtt_ms")) for s in tail],
        "rx_bps": [_num_or_none(s.get("rx_bps")) for s in tail],
    }
