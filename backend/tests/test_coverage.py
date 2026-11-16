"""Coverage math with synthetic masks."""

import numpy as np

from app.coverage import compute_coverage, filter_predictions, severity
from tests.conftest import rect_mask

SHAPE = (100, 100)


def pred(name, mask, conf=0.9):
    return {"class_name": name, "confidence": conf, "mask": mask}


def test_overlapping_disease_masks_counted_once():
    leaf = rect_mask(SHAPE, 0, 10, 0, 10)  # 100 px
    result = compute_coverage(
        [
            pred("leaf", leaf),
            pred("leaf_spot", rect_mask(SHAPE, 0, 2, 0, 10)),  # 20 px
            pred("leaf_spot", rect_mask(SHAPE, 1, 3, 0, 10)),  # overlaps 10 px → union 30 px
            pred("powdery_mildew", rect_mask(SHAPE, 2, 4, 0, 10)),  # 20 px, overlaps spot by 10 px
        ]
    )
    p = result["primary"]
    assert p["leaf_spot_pct"] == 30
    assert p["powdery_mildew_pct"] == 20
    assert p["healthy_pct"] == 60  # union of both diseases = rows 0–3 = 40 px


def test_disease_far_from_leaf_ignored():
    result = compute_coverage(
        [
            pred("leaf", rect_mask(SHAPE, 0, 10, 0, 10)),
            pred("powdery_mildew", rect_mask(SHAPE, 5, 10, 5, 10)),  # 25 px inside the leaf
            pred("powdery_mildew", rect_mask(SHAPE, 60, 90, 60, 90)),  # far away: not this leaf's
        ]
    )
    assert result["primary"]["powdery_mildew_pct"] == 25
    assert result["primary"]["healthy_pct"] == 75


def test_lesion_holes_in_leaf_mask_are_counted():
    # YOLO trained with overlap_mask=True predicts leaves with holes where the lesions are.
    leaf = rect_mask(SHAPE, 0, 20, 0, 20)  # 400 px
    spot = rect_mask(SHAPE, 5, 9, 5, 9)  # 16 px, inside
    result = compute_coverage([pred("leaf", leaf & ~spot), pred("leaf_spot", spot)])
    assert result["primary"]["leaf_spot_pct"] == 4  # 16 / 400, not 0
    assert result["primary"]["healthy_pct"] == 96


def test_lesion_notch_on_leaf_edge_is_counted():
    leaf = rect_mask(SHAPE, 0, 20, 0, 20)
    spot = rect_mask(SHAPE, 0, 4, 8, 12)  # 16 px on the top edge: a notch, not a hole
    result = compute_coverage([pred("leaf", leaf & ~spot), pred("leaf_spot", spot)])
    assert result["primary"]["leaf_spot_pct"] == 4


def test_no_leaf_detected():
    result = compute_coverage([pred("leaf_spot", rect_mask(SHAPE, 0, 5, 0, 5))])
    assert result == {"status": "no_leaf_detected", "primary": None, "leaves": [], "framing": None}
    assert compute_coverage([pred("leaf", np.zeros(SHAPE, bool))])["status"] == "no_leaf_detected"


def test_primary_leaf_is_largest():
    small = rect_mask(SHAPE, 0, 10, 0, 10)
    big = rect_mask(SHAPE, 50, 100, 50, 100)
    result = compute_coverage(
        [pred("leaf", small), pred("leaf", big), pred("leaf_spot", rect_mask(SHAPE, 0, 10, 0, 5))]
    )
    assert result["leaves"] == [result["primary"]]  # only the main leaf is reported
    assert result["primary"]["leaf_spot_pct"] == 0  # the spot is on the small leaf, not the main one


def test_framing_one_dominant_leaf_is_ok():
    big = rect_mask(SHAPE, 10, 90, 10, 90)  # 64 % of the photo
    small = rect_mask(SHAPE, 0, 5, 0, 5)  # a corner of a background leaf
    framing = compute_coverage([pred("leaf", big), pred("leaf", small)])["framing"]
    assert framing == {"ok": True, "issue": None, "leaf_frac": 0.64, "dominance": 256.0}


def test_framing_single_leaf_has_no_dominance():
    framing = compute_coverage([pred("leaf", rect_mask(SHAPE, 0, 50, 0, 50))])["framing"]
    assert framing["ok"] and framing["dominance"] is None


def test_framing_flags_two_similar_leaves():
    a = rect_mask(SHAPE, 0, 50, 0, 50)  # 2500 px
    b = rect_mask(SHAPE, 50, 100, 50, 90)  # 2000 px: 0.8 of the main leaf
    framing = compute_coverage([pred("leaf", a), pred("leaf", b)])["framing"]
    assert framing["ok"] is False and framing["issue"] == "several_leaves" and framing["dominance"] == 1.25


def test_framing_flags_a_small_leaf():
    framing = compute_coverage([pred("leaf", rect_mask(SHAPE, 40, 60, 40, 60))])["framing"]  # 4 % of the photo
    assert framing["ok"] is False and framing["issue"] == "small_leaf"


def test_severity_bands():
    assert severity(0) == "none"
    assert severity(0.1) == "mild"
    assert severity(4.99) == "mild"
    assert severity(5) == "moderate"
    assert severity(24.9) == "moderate"
    assert severity(25) == "severe"
    assert severity(100) == "severe"


def test_filter_predictions_per_class_thresholds(monkeypatch):
    from app.config import settings

    monkeypatch.setattr(settings, "leaf_confidence", 0.5)
    monkeypatch.setattr(settings, "disease_confidence", 0.4)
    monkeypatch.setattr(settings, "leaf_spot_confidence", None)
    monkeypatch.setattr(settings, "powdery_mildew_confidence", None)
    m = np.ones(SHAPE, bool)
    kept = filter_predictions(
        [
            pred("leaf", m, 0.45),  # below leaf_confidence 0.5
            pred("leaf", m, 0.6),
            pred("leaf_spot", m, 0.45),  # above disease_confidence 0.4
            pred("_superclass", m, 0.99),
        ]
    )
    assert [(p["class_name"], p["confidence"]) for p in kept] == [("leaf", 0.6), ("leaf_spot", 0.45)]


def test_filter_predictions_per_disease_thresholds(monkeypatch):
    from app.config import settings

    monkeypatch.setattr(settings, "disease_confidence", 0.4)
    monkeypatch.setattr(settings, "leaf_spot_confidence", 0.25)
    monkeypatch.setattr(settings, "powdery_mildew_confidence", 0.3)
    m = np.ones(SHAPE, bool)
    kept = filter_predictions(
        [
            pred("leaf_spot", m, 0.26),  # above its own 0.25 (below disease_confidence 0.4)
            pred("leaf_spot", m, 0.2),
            pred("powdery_mildew", m, 0.31),
            pred("powdery_mildew", m, 0.29),
        ]
    )
    assert [(p["class_name"], p["confidence"]) for p in kept] == [("leaf_spot", 0.26), ("powdery_mildew", 0.31)]
