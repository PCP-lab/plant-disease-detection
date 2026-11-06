"""API tests via FastAPI TestClient."""

import base64
import io

import numpy as np
from PIL import Image

from app.overlay import render_overlay
from app.routes.scans import load_image
from tests.conftest import FakeModel


def test_health(anon_client):
    assert anon_client.get("/health").json()["status"] == "ok"


def test_requires_token(firebase_mode, anon_client, jpeg_bytes):
    assert anon_client.get("/scans").status_code == 401
    assert anon_client.get("/scans", headers={"Authorization": "Basic abc"}).status_code == 401
    assert anon_client.post("/scans", files={"image": ("leaf.jpg", jpeg_bytes, "image/jpeg")}).status_code == 401


def test_create_scan(client, fake_storage, jpeg_bytes):
    res = client.post("/scans", files={"image": ("leaf.jpg", jpeg_bytes, "image/jpeg")})
    assert res.status_code == 200, res.text
    body = res.json()
    assert body["status"] == "ok"
    # Leaf = top-left quarter, spot = 10×10 of its 100×100 → 1%.
    assert body["primary"]["leaf_spot_pct"] == 1.0
    assert body["primary"]["severity"] == {"powdery_mildew": "none", "leaf_spot": "mild"}
    assert body["overlay_url"].startswith("https://")
    assert len(fake_storage.scans) == 1
    # Both images come back for the app to keep on the device.
    assert base64.b64decode(body["overlay_jpeg_b64"]).startswith(b"\xff\xd8")
    assert base64.b64decode(body["image_jpeg_b64"]).startswith(b"\xff\xd8")


def test_list_omits_inline_images(client, jpeg_bytes):
    client.post("/scans", files={"image": ("leaf.jpg", jpeg_bytes, "image/jpeg")})
    assert client.get("/scans").json()[0]["overlay_jpeg_b64"] is None


def test_create_scan_rejects_non_image(client):
    res = client.post("/scans", files={"image": ("leaf.jpg", b"not an image", "image/jpeg")})
    assert res.status_code == 400


def test_get_list_delete(client, jpeg_bytes):
    scan_id = client.post("/scans", files={"image": ("leaf.jpg", jpeg_bytes, "image/jpeg")}).json()["id"]

    assert [s["id"] for s in client.get("/scans").json()] == [scan_id]
    assert client.get(f"/scans/{scan_id}").json()["id"] == scan_id
    assert client.delete(f"/scans/{scan_id}").status_code == 204
    assert client.get(f"/scans/{scan_id}").status_code == 404
    assert client.delete(f"/scans/{scan_id}").status_code == 404


def test_local_mode_round_trip(local_mode, jpeg_bytes):
    """No token, files written to disk and served at /files."""
    scan = local_mode.post("/scans", files={"image": ("leaf.jpg", jpeg_bytes, "image/jpeg")}).json()
    assert scan["model_version"] == "fake"
    assert scan["overlay_url"].startswith("/files/")
    assert local_mode.get(scan["overlay_url"]).headers["content-type"] == "image/jpeg"
    assert local_mode.get(scan["image_url"]).headers["content-type"] == "image/jpeg"

    assert [s["id"] for s in local_mode.get("/scans").json()] == [scan["id"]]
    assert local_mode.get(f"/scans/{scan['id']}").json()["primary"] == scan["primary"]
    assert local_mode.get("/scans/..%2F..%2Fetc").status_code == 404
    assert local_mode.get("/files/..%2F..%2Fapp%2Fmain.py").status_code == 404
    assert local_mode.delete(f"/scans/{scan['id']}").status_code == 204
    assert local_mode.get("/scans").json() == []


def test_load_image_applies_exif_and_caps_size():
    buf = io.BytesIO()
    exif = Image.Exif()
    exif[0x0112] = 6  # orientation: rotate 90° CW
    Image.new("RGB", (4000, 2000)).save(buf, format="JPEG", exif=exif)
    img = load_image(buf.getvalue())
    assert img.size == (640, 1280)  # portrait after rotation, long side capped


def test_overlay_is_jpeg():
    pixels = np.zeros((50, 60, 3), np.uint8)
    jpeg = render_overlay(pixels, FakeModel().predict(pixels))
    assert jpeg.startswith(b"\xff\xd8")
    assert Image.open(io.BytesIO(jpeg)).size == (60, 50)
