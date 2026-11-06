"""Shared fixtures: TestClient, auth override, synthetic masks."""

import io
from datetime import datetime, timezone

import numpy as np
import pytest
from fastapi.testclient import TestClient
from PIL import Image

from app.auth import get_current_uid
from app.config import settings
from app.main import app
from app.routes.scans import get_model, get_store

UID = "test-user"


def rect_mask(shape, y0, y1, x0, x1) -> np.ndarray:
    m = np.zeros(shape, bool)
    m[y0:y1, x0:x1] = True
    return m


class FakeModel:
    """One 100×100 leaf with a 10×10 leaf spot, scaled to whatever image comes in."""

    version = "fake"

    def predict(self, image: np.ndarray, min_confidence: float = 0.25) -> list[dict]:
        h, w = image.shape[:2]
        return [
            {"class_name": "leaf", "confidence": 0.9, "mask": rect_mask((h, w), 0, h // 2, 0, w // 2)},
            {"class_name": "leaf_spot", "confidence": 0.8, "mask": rect_mask((h, w), 0, h // 20, 0, w // 20)},
        ]


class FakeStorage:
    def __init__(self):
        self.scans: dict[str, dict] = {}

    def save_scan(self, uid, image_bytes, overlay_jpeg, result, model_version):
        scan_id = f"scan{len(self.scans)}"
        self.scans[scan_id] = {
            "id": scan_id,
            "created_at": datetime.now(timezone.utc),
            "model_version": model_version,
            **result,
            "image_url": f"https://example.com/{scan_id}/original.jpg",
            "overlay_url": f"https://example.com/{scan_id}/overlay.jpg",
        }
        return self.scans[scan_id]

    def list_scans(self, uid, limit, cursor):
        return list(reversed(self.scans.values()))[:limit]

    def get_scan(self, uid, scan_id):
        return self.scans.get(scan_id)

    def delete_scan(self, uid, scan_id):
        return self.scans.pop(scan_id, None) is not None


@pytest.fixture
def fake_storage() -> FakeStorage:
    return FakeStorage()


@pytest.fixture
def client(fake_storage):
    """Signed in as UID, with the fake model and storage. No lifespan, so no Firebase or ONNX is touched."""
    app.dependency_overrides[get_current_uid] = lambda: UID
    app.dependency_overrides[get_model] = lambda: FakeModel()
    app.dependency_overrides[get_store] = lambda: fake_storage
    yield TestClient(app)
    app.dependency_overrides.clear()


@pytest.fixture
def firebase_mode(monkeypatch):
    monkeypatch.setattr(settings, "firebase_project_id", "test-project")


@pytest.fixture
def local_mode(monkeypatch, tmp_path):
    """Real local storage in a temp dir, fake model, no auth."""
    monkeypatch.setattr(settings, "firebase_project_id", "")
    monkeypatch.setattr(settings, "local_data_dir", str(tmp_path))
    app.dependency_overrides[get_model] = lambda: FakeModel()
    yield TestClient(app)
    app.dependency_overrides.clear()


@pytest.fixture
def anon_client():
    return TestClient(app)


@pytest.fixture
def jpeg_bytes() -> bytes:
    buf = io.BytesIO()
    Image.new("RGB", (200, 200), (60, 140, 60)).save(buf, format="JPEG")
    return buf.getvalue()
