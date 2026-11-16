"""API tests via FastAPI TestClient."""

import base64
import io

import numpy as np
from PIL import Image

from app.config import settings
from app.main import app
from app.overlay import render_overlay
from app.routes.scans import get_model, load_image
from tests.conftest import FakeModel, rect_mask


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


def test_create_scan_reports_framing(client, jpeg_bytes):
    body = client.post("/scans", files={"image": ("leaf.jpg", jpeg_bytes, "image/jpeg")}).json()
    # FakeModel's leaf is the top-left quarter of the photo, the only leaf.
    assert body["framing"] == {"ok": True, "issue": None, "leaf_frac": 0.25, "dominance": None}


def test_create_scan_crops_to_the_box(client, jpeg_bytes):
    res = client.post("/scans", files={"image": ("leaf.jpg", jpeg_bytes, "image/jpeg")}, data={"crop": "0.25,0,0.75,0.5"})
    assert res.status_code == 200, res.text
    stored = Image.open(io.BytesIO(base64.b64decode(res.json()["image_jpeg_b64"])))
    assert stored.size == (100, 100)  # half the width and half the height of the 200 x 200 photo


def test_create_scan_rejects_bad_crops(client, jpeg_bytes):
    for crop in ("0.5,0,0.4,1", "0,0,1.2,1", "0,0,0.01,0.01", "a,b,c,d", "0,0,1"):
        res = client.post("/scans", files={"image": ("leaf.jpg", jpeg_bytes, "image/jpeg")}, data={"crop": crop})
        assert res.status_code == 400, crop


def test_load_image_crops_after_exif_rotation():
    buf = io.BytesIO()
    exif = Image.Exif()
    exif[0x0112] = 6  # stored landscape, shown portrait (rotate 90° CW)
    Image.new("RGB", (400, 200)).save(buf, format="JPEG", exif=exif)
    img = load_image(buf.getvalue(), (0.0, 0.0, 1.0, 0.5))  # top half of the upright (200 x 400) photo
    assert img.size == (200, 200)


class TwoLeafModel:
    """Main leaf (top-left quarter) with a spot, plus a background leaf (bottom-right corner) with mildew. Like a real
    model, it finds nothing where the photo has been greyed out."""

    version = "fake2"

    def __init__(self):
        self.inputs = []

    def predict(self, image, min_confidence=0.25):
        self.inputs.append(image.copy())
        h, w = image.shape[:2]
        out = [
            {"class_name": "leaf", "confidence": 0.9, "mask": rect_mask((h, w), 0, h // 2, 0, w // 2)},
            {"class_name": "leaf_spot", "confidence": 0.8, "mask": rect_mask((h, w), 0, h // 20, 0, w // 20)},
        ]
        background = rect_mask((h, w), 3 * h // 4, h, 3 * w // 4, w)
        # a small sliver of a neighbouring leaf right next to the main leaf (inside the kept margin)
        out.append({"class_name": "leaf", "confidence": 0.5, "mask": rect_mask((h, w), 0, 10, w // 2 - 2, w // 2 + 1)})
        if not (image[background] == 114).all():
            out += [
                {"class_name": "leaf", "confidence": 0.9, "mask": background},
                {"class_name": "powdery_mildew", "confidence": 0.8, "mask": rect_mask((h, w), 4 * h // 5, 9 * h // 10, 4 * w // 5, 9 * w // 10)},
            ]
        return out


def test_background_leaves_are_not_analysed(client, jpeg_bytes):
    model = TwoLeafModel()
    app.dependency_overrides[get_model] = lambda: model
    body = client.post("/scans", files={"image": ("leaf.jpg", jpeg_bytes, "image/jpeg")}).json()
    assert len(model.inputs) == 2  # find the main leaf, then analyse it alone
    assert (model.inputs[1][150:, 150:] == 114).all()  # everything but the main leaf greyed out
    assert len(body["leaves"]) == 1
    assert body["primary"]["leaf_spot_pct"] == 1.0
    assert body["primary"]["powdery_mildew_pct"] == 0  # the background leaf's mildew never reaches the result
    # The photo check is still judged on the whole photo: main leaf 100×100 vs background leaf 50×50.
    assert body["framing"]["dominance"] == 4.0


def test_isolation_can_be_switched_off(client, jpeg_bytes, monkeypatch):
    monkeypatch.setattr(settings, "isolate_main_leaf", False)
    model = TwoLeafModel()
    app.dependency_overrides[get_model] = lambda: model
    body = client.post("/scans", files={"image": ("leaf.jpg", jpeg_bytes, "image/jpeg")}).json()
    assert len(model.inputs) == 1  # one pass
    assert body["framing"]["dominance"] == 4.0 and len(body["leaves"]) == 1


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
