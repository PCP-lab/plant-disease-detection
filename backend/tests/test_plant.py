"""Whole-plant scans: aggregate_plant() and POST /scans/plant."""

import base64
import io

import numpy as np
import pytest
from PIL import Image

from app import advice
from app.coverage import aggregate_plant
from app.main import app
from app.routes.scans import get_model
from tests.conftest import FakeModel


def leaf(mildew=0.0, spot=0.0):
    return {"powdery_mildew_pct": mildew, "leaf_spot_pct": spot, "healthy_pct": 100 - mildew - spot,
            "severity": {}}


def jpeg(color) -> bytes:
    buf = io.BytesIO()
    Image.new("RGB", (200, 200), color).save(buf, format="JPEG")
    return buf.getvalue()


GREEN, DARK = jpeg((60, 140, 60)), jpeg((0, 0, 0))


class NoLeafInDarkPhotos(FakeModel):
    """FakeModel, except a (near-)black photo has no leaf."""

    def predict(self, image, min_confidence=0.25):
        return [] if image.mean() < 20 else super().predict(image, min_confidence)


def post_plant(client, photos, crops=None):
    files = [("images", (f"leaf{i}.jpg", p, "image/jpeg")) for i, p in enumerate(photos)]
    data = {"crops": crops} if crops is not None else None
    return client.post("/scans/plant", files=files, data=data)


# --- aggregate_plant ---------------------------------------------------------------------------------------------

def test_average_is_graded_with_the_leaf_bands():
    out = aggregate_plant([leaf(mildew=30), leaf(), leaf(), leaf()])  # avg 7.5 → moderate; 1 of 4 → no spread
    assert out["primary"]["powdery_mildew_pct"] == 7.5
    assert out["primary"]["severity"] == {"powdery_mildew": "moderate", "leaf_spot": "none"}
    assert out["plant"]["leaves_affected"] == {"powdery_mildew": 1, "leaf_spot": 0}
    assert out["plant"]["raised"] == []


def test_spread_to_half_the_leaves_raises_the_level():
    out = aggregate_plant([leaf(spot=2), leaf(spot=2), leaf(), leaf()])  # avg 1 → mild; 2 of 4 → moderate
    assert out["primary"]["severity"]["leaf_spot"] == "moderate"
    assert out["plant"]["raised"] == ["leaf_spot"]
    assert out["plant"]["spread"]["leaf_spot"] == 0.5


def test_severe_stays_severe_and_healthy_stays_none():
    out = aggregate_plant([leaf(mildew=40), leaf(mildew=40), leaf(mildew=40)])
    assert out["primary"]["severity"] == {"powdery_mildew": "severe", "leaf_spot": "none"}
    assert out["plant"]["raised"] == []


def test_traces_below_the_affected_floor_do_not_count(monkeypatch):
    from app.config import settings

    monkeypatch.setattr(settings, "plant_affected_min_pct", 0.1)
    out = aggregate_plant([leaf(spot=2), leaf(spot=0.05), leaf(spot=0.05), leaf()])
    assert out["plant"]["leaves_affected"]["leaf_spot"] == 1
    assert out["primary"]["severity"]["leaf_spot"] == "mild"  # not raised: only 1 of 4 really affected


def test_leaves_count_equally():
    out = aggregate_plant([leaf(mildew=9), leaf(mildew=0), leaf(mildew=0)])
    assert out["primary"]["powdery_mildew_pct"] == 3.0
    assert out["primary"]["healthy_pct"] == 97.0


# --- POST /scans/plant -------------------------------------------------------------------------------------------

def test_plant_scan(client, fake_storage):
    res = post_plant(client, [GREEN] * 3)
    assert res.status_code == 200, res.text
    body = res.json()
    assert body["kind"] == "plant"
    assert [lf["index"] for lf in body["leaves"]] == [0, 1, 2]
    # Every FakeModel leaf has 1% leaf spot: avg 1% (mild), on 3 of 3 leaves → raised to moderate.
    assert body["primary"]["leaf_spot_pct"] == 1.0
    assert body["primary"]["severity"]["leaf_spot"] == "moderate"
    assert body["plant"]["leaves_analysed"] == 3 and body["plant"]["raised"] == ["leaf_spot"]
    assert body["plant"]["cover"] == 0 and body["plant"]["skipped"] == []
    assert body["leaves"][0]["framing"]["ok"] is True
    assert [img["index"] for img in body["leaf_images"]] == [0, 1, 2]
    assert base64.b64decode(body["leaf_images"][2]["overlay_jpeg_b64"]).startswith(b"\xff\xd8")
    assert len(fake_storage.scans) == 1


def test_plant_scan_crops_each_photo(client):
    res = post_plant(client, [GREEN] * 3, crops=["0,0,0.5,0.5", "", "0.25,0,0.75,0.5"])
    assert res.status_code == 200, res.text
    sizes = [Image.open(io.BytesIO(base64.b64decode(img["image_jpeg_b64"]))).size for img in res.json()["leaf_images"]]
    assert sizes == [(100, 100), (200, 200), (100, 100)]


@pytest.mark.parametrize("count", [1, 2, 7])
def test_plant_scan_needs_3_to_6_photos(client, count):
    assert post_plant(client, [GREEN] * count).status_code == 400


def test_plant_scan_rejects_bad_crops(client):
    assert post_plant(client, [GREEN] * 3, crops=["0,0,1,1", "0,0,1,1"]).status_code == 400  # one missing
    assert post_plant(client, [GREEN] * 3, crops=["0,0,1,1", "0,0,1,1", "a,b,c,d"]).status_code == 400


def test_photos_without_a_leaf_are_skipped(client):
    app.dependency_overrides[get_model] = lambda: NoLeafInDarkPhotos()
    body = post_plant(client, [GREEN, DARK, GREEN, GREEN]).json()
    assert [lf["index"] for lf in body["leaves"]] == [0, 2, 3]
    assert body["plant"]["skipped"] == [1] and body["plant"]["leaves_analysed"] == 3
    assert [img["index"] for img in body["leaf_images"]] == [0, 2, 3]


def test_too_few_leaves_found_is_422_with_the_photos_to_retake(client, fake_storage):
    app.dependency_overrides[get_model] = lambda: NoLeafInDarkPhotos()
    res = post_plant(client, [GREEN, DARK, GREEN])
    assert res.status_code == 422
    assert res.json()["detail"]["failed"] == [1]
    assert "photo 2" in res.json()["detail"]["message"]
    assert fake_storage.scans == {}


def test_most_affected_leaf_is_the_cover(client):
    class MoreSpotOnSecondPhoto(FakeModel):
        calls = 0

        def predict(self, image, min_confidence=0.25):
            out = super().predict(image, min_confidence)
            if image[0, 0, 0] > 150:  # the red photo: a bigger spot
                h, w = image.shape[:2]
                out[1]["mask"] = np.zeros((h, w), bool)
                out[1]["mask"][: h // 5, : w // 5] = True
            return out

    app.dependency_overrides[get_model] = lambda: MoreSpotOnSecondPhoto()
    body = post_plant(client, [GREEN, jpeg((200, 60, 60)), GREEN]).json()
    assert body["plant"]["cover"] == 1


def test_plant_scan_local_mode_round_trip(local_mode):
    scan = post_plant(local_mode, [GREEN] * 3).json()
    assert scan["overlay_url"].endswith("/leaf_0_overlay.jpg")
    for img in local_mode.get(f"/scans/{scan['id']}").json()["leaf_images"]:
        assert local_mode.get(img["overlay_url"]).headers["content-type"] == "image/jpeg"
        assert local_mode.get(img["image_url"]).headers["content-type"] == "image/jpeg"
    listed = local_mode.get("/scans").json()[0]
    assert listed["kind"] == "plant" and listed["plant"]["leaves_analysed"] == 3
    assert local_mode.delete(f"/scans/{scan['id']}").status_code == 204
    assert local_mode.get("/scans").json() == []


def test_advice_prompt_describes_the_whole_plant(client):
    scan = post_plant(client, [GREEN] * 4).json()
    report = advice._scan_report(scan)
    assert report["whole_plant"] is True
    assert report["leaves_affected"]["leaf_spot"] == "4 of 4"
    assert len(report["per_leaf"]) == 4
