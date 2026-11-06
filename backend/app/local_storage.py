"""Local stand-in for app.storage while Firebase isn't set up: files under settings.local_data_dir,
served by the app at /files. Same functions as app.storage. Image URLs are relative to the API.
"""

import json
import re
import shutil
import uuid
from datetime import datetime, timezone
from pathlib import Path

from app.config import settings

_SAFE_ID = re.compile(r"^[A-Za-z0-9_-]{1,64}$")


def _user_dir(uid: str) -> Path:
    return Path(settings.local_data_dir) / "scans" / uid


def _scan_dir(uid: str, scan_id: str) -> Path | None:
    return _user_dir(uid) / scan_id if _SAFE_ID.match(scan_id) else None


def _to_response(uid: str, scan_id: str, doc: dict) -> dict:
    base = f"/files/scans/{uid}/{scan_id}"
    return {"id": scan_id, **doc, "image_url": f"{base}/original.jpg", "overlay_url": f"{base}/overlay.jpg"}


def _read(uid: str, scan_id: str) -> dict | None:
    d = _scan_dir(uid, scan_id)
    if d is None or not (d / "scan.json").exists():
        return None
    return json.loads((d / "scan.json").read_text())


def save_scan(uid: str, image_bytes: bytes, overlay_jpeg: bytes, result: dict, model_version: str) -> dict:
    scan_id = uuid.uuid4().hex[:20]
    d = _scan_dir(uid, scan_id)
    d.mkdir(parents=True)
    (d / "original.jpg").write_bytes(image_bytes)
    (d / "overlay.jpg").write_bytes(overlay_jpeg)
    doc = {
        "created_at": datetime.now(timezone.utc).isoformat(),
        "model_version": model_version,
        "status": result["status"],
        "primary": result["primary"],
        "leaves": result["leaves"],
    }
    (d / "scan.json").write_text(json.dumps(doc))
    return _to_response(uid, scan_id, doc)


def list_scans(uid: str, limit: int, cursor: str | None) -> list[dict] | None:
    docs = [(p.parent.name, json.loads(p.read_text())) for p in _user_dir(uid).glob("*/scan.json")]
    docs.sort(key=lambda item: item[1]["created_at"], reverse=True)
    if cursor:
        ids = [scan_id for scan_id, _ in docs]
        if cursor not in ids:
            return None
        docs = docs[ids.index(cursor) + 1 :]
    return [_to_response(uid, scan_id, doc) for scan_id, doc in docs[:limit]]


def get_scan(uid: str, scan_id: str) -> dict | None:
    doc = _read(uid, scan_id)
    return _to_response(uid, scan_id, doc) if doc else None


def delete_scan(uid: str, scan_id: str) -> bool:
    if _read(uid, scan_id) is None:
        return False
    shutil.rmtree(_scan_dir(uid, scan_id))
    return True
