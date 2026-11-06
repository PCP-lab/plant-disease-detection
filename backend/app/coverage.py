"""Leaf coverage computation.

Per leaf: region = leaf mask with holes filled, plus nearby disease pixels that no leaf covers;
pct = disease_px in region / region_px × 100. healthy_pct = 100 − |mildew ∪ spot| / region_px × 100.
Primary leaf = largest leaf. No leaf detected → status "no_leaf_detected".

Why regions and not the raw leaf masks: YOLO-seg trained with overlap_mask=True (the Ultralytics
default) learns leaf masks with holes where the lesions are, so disease ∩ leaf misses most lesions
and every leaf looks ~100 % healthy.
"""

import cv2
import numpy as np

from app.config import settings

DISEASE_CLASSES = ("powdery_mildew", "leaf_spot")
# Disease pixels outside every leaf mask go to the nearest leaf within this fraction of the image side
# (lesions on a leaf's edge cut notches into its mask; farther away they're likely on an undetected leaf).
ATTACH_DISTANCE = 0.03


def filter_predictions(predictions: list[dict]) -> list[dict]:
    """Keep each prediction at or above its class threshold (settings.class_confidence); drop other classes."""
    thresholds = settings.class_confidence
    return [
        p
        for p in predictions
        if p["class_name"] in thresholds and p["confidence"] >= thresholds[p["class_name"]]
    ]


def compute_coverage(predictions: list[dict]) -> dict:
    """→ {"status", "primary", "leaves"}; leaves sorted largest first, primary = leaves[0]."""
    leaf_masks = [p["mask"] for p in predictions if p["class_name"] == "leaf" and p["mask"].any()]
    if not leaf_masks:
        return {"status": "no_leaf_detected", "primary": None, "leaves": []}

    shape = leaf_masks[0].shape
    disease_union = {d: np.zeros(shape, bool) for d in DISEASE_CLASSES}
    for p in predictions:
        if p["class_name"] in disease_union:
            disease_union[p["class_name"]] |= p["mask"]
    any_disease = disease_union["powdery_mildew"] | disease_union["leaf_spot"]

    leaves = []
    for leaf in leaf_regions(leaf_masks, any_disease):
        leaf_px = int(leaf.sum())
        pct = {d: 100 * int((disease_union[d] & leaf).sum()) / leaf_px for d in DISEASE_CLASSES}
        diseased_pct = 100 * int((any_disease & leaf).sum()) / leaf_px
        leaves.append(
            {
                "powdery_mildew_pct": round(pct["powdery_mildew"], 2),
                "leaf_spot_pct": round(pct["leaf_spot"], 2),
                "healthy_pct": round(100 - diseased_pct, 2),
                "severity": {d: severity(pct[d]) for d in DISEASE_CLASSES},
            }
        )
    return {"status": "ok", "primary": leaves[0], "leaves": leaves}


def fill_holes(mask: np.ndarray) -> np.ndarray:
    """Fill enclosed holes (flood fill from the border of the mask's padded bounding box)."""
    ys, xs = np.nonzero(mask)
    y0, y1, x0, x1 = ys.min(), ys.max() + 1, xs.min(), xs.max() + 1
    crop = np.pad(mask[y0:y1, x0:x1], 1).astype(np.uint8)
    outside = crop.copy()
    cv2.floodFill(outside, None, (0, 0), 1)  # marks everything reachable from outside
    filled = mask.copy()
    filled[y0:y1, x0:x1] |= (outside == 0)[1:-1, 1:-1]
    return filled


def leaf_regions(leaf_masks: list[np.ndarray], any_disease: np.ndarray) -> list[np.ndarray]:
    """One region per leaf, largest leaf first: hole-filled mask plus the uncovered disease pixels nearest to it."""
    regions = sorted((fill_holes(m) for m in leaf_masks), key=lambda m: int(m.sum()), reverse=True)
    covered = np.zeros(any_disease.shape, bool)
    index = np.zeros(any_disease.shape, np.int32)  # 1-based; smaller leaves painted last where leaves overlap
    for i, r in enumerate(regions, 1):
        index[r] = i
        covered |= r
    orphans = any_disease & ~covered
    if not orphans.any():
        return regions

    # For every pixel: distance to, and label of, the nearest leaf pixel.
    dist, labels = cv2.distanceTransformWithLabels(
        (~covered).astype(np.uint8), cv2.DIST_L2, 5, labelType=cv2.DIST_LABEL_PIXEL
    )
    lut = np.zeros(labels.max() + 1, np.int32)
    lut[labels[covered]] = index[covered]
    nearest = lut[labels]
    attach = orphans & (dist <= ATTACH_DISTANCE * max(any_disease.shape))
    return [r | (attach & (nearest == i)) for i, r in enumerate(regions, 1)]


def severity(pct: float) -> str:
    if pct <= 0:
        return "none"
    if pct < settings.severity_mild_max:
        return "mild"
    if pct < settings.severity_moderate_max:
        return "moderate"
    return "severe"
