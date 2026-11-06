"""The colour-threshold placeholder finds a synthetic leaf and its lesions."""

import cv2
import numpy as np

from app.coverage import compute_coverage, filter_predictions
from app.placeholder_model import ColorHeuristicModel


def test_finds_leaf_spot_and_mildew():
    img = np.full((400, 400, 3), 128, np.uint8)  # grey background
    cv2.circle(img, (200, 200), 150, (60, 150, 50), -1)  # green leaf, ~70 700 px
    cv2.circle(img, (150, 170), 30, (130, 75, 25), -1)  # brown spot, ~2 800 px
    cv2.circle(img, (260, 240), 30, (235, 235, 230), -1)  # whitish mildew, ~2 800 px

    result = compute_coverage(filter_predictions(ColorHeuristicModel().predict(img)))

    assert result["status"] == "ok"
    p = result["primary"]
    assert 3 < p["leaf_spot_pct"] < 5
    assert 3 < p["powdery_mildew_pct"] < 5
    assert 90 < p["healthy_pct"] < 94


def test_no_leaf_on_plain_background():
    img = np.full((200, 200, 3), 128, np.uint8)
    assert compute_coverage(ColorHeuristicModel().predict(img))["status"] == "no_leaf_detected"
