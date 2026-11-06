"""Model-agnostic evaluation helpers shared by 03_evaluate.ipynb and 06_backbone_study.ipynb.

Every model is wrapped as predict(PIL image) → (masks [N, H, W] bool at full image size, class names [N], confidences [N]).
"""

from pathlib import Path

import cv2
import numpy as np
import torch

import semseg
from semseg import CLASSES, DISEASES, image_coverage, iou_from_confusion, paint_class_map  # noqa: F401 (re-exported)

SEVERITY_BANDS = ((5, "mild"), (25, "moderate"), (float("inf"), "severe"))  # same bands as the backend


def load_predictor(checkpoint, cat_names):
    """→ (kind, predict, model). kind: "yolo" (.pt), "semseg" (05_biotrove_semseg) or "rfdetr" (other .pth).
    cat_names maps COCO category id → name (needed for RF-DETR class ids)."""
    checkpoint = Path(checkpoint)
    if checkpoint.suffix == ".pt":
        from ultralytics import YOLO

        model = YOLO(checkpoint)

        def predict(image):
            # retina_masks=True returns masks at the original image size, needed for pixel coverage
            r = model.predict(image, conf=0.01, retina_masks=True, verbose=False)[0]
            if r.masks is None:
                return np.zeros((0, image.height, image.width), bool), np.array([]), np.array([])
            names = np.array([r.names[int(c)] for c in r.boxes.cls])
            return r.masks.data.cpu().numpy().astype(bool), names, r.boxes.conf.cpu().numpy()

        return "yolo", predict, model

    meta = torch.load(checkpoint, map_location="cpu", weights_only=False)
    if isinstance(meta, dict) and meta.get("kind") == "semseg":
        del meta
        model = semseg.load_model(checkpoint)
        return "semseg", lambda image: semseg.predict_instances(model, image), model

    import rfdetr

    del meta
    model = rfdetr.RFDETR.from_checkpoint(checkpoint)  # model size and resolution come from the checkpoint

    def predict(image):
        det = model.predict(image, threshold=0.01)
        if det.mask is None:
            return np.zeros((0, image.height, image.width), bool), np.array([]), np.array([])
        names = np.array([cat_names[int(c)] for c in det.class_id])
        return det.mask.astype(bool), names, det.confidence

    return "rfdetr", predict, model


ATTACH_DISTANCE = 0.03  # same as backend/app/coverage.py


def _fill_holes(mask):
    ys, xs = np.nonzero(mask)
    y0, y1, x0, x1 = ys.min(), ys.max() + 1, xs.min(), xs.max() + 1
    outside = np.ascontiguousarray(np.pad(mask[y0:y1, x0:x1], 1), np.uint8)  # pycocotools masks are Fortran-ordered
    cv2.floodFill(outside, None, (0, 0), 1)
    filled = mask.copy()
    filled[y0:y1, x0:x1] |= (outside == 0)[1:-1, 1:-1]
    return filled


def fill_holes(mask):
    """Mask with every enclosed hole filled (empty masks are returned unchanged)."""
    mask = np.asarray(mask, bool)
    return _fill_holes(mask) if mask.any() else mask.copy()


def _bridge(outer, hole):
    # Join a hole to its outer ring with a zero-width cut at their closest points, so a single ring keeps the hole
    d = ((outer[:, None, :] - hole[None, :, :]) ** 2).sum(-1)
    i, j = np.unravel_index(d.argmin(), d.shape)
    return np.concatenate([outer[:i + 1], hole[j:], hole[:j + 1], outer[i:]])


def mask_to_polygons(mask, epsilon=1.0, min_area=1.0, min_hole_area=4.0, keep_holes=True):
    """Binary mask → [(polygon [x1, y1, x2, y2, ...], area_px)], one per connected part, largest first.

    Holes are kept by a zero-width cut to the outer edge: COCO / YOLO / Roboflow polygons have no holes, but an
    even-odd fill (cv2.fillPoly, pycocotools) of the cut ring leaves the hole empty."""
    m = np.ascontiguousarray(mask, np.uint8)
    contours, hierarchy = cv2.findContours(m, cv2.RETR_CCOMP, cv2.CHAIN_APPROX_NONE)
    if hierarchy is None:
        return []
    hierarchy = hierarchy[0]
    out = []
    for i, c in enumerate(contours):
        if hierarchy[i][3] != -1 or cv2.contourArea(c) < min_area:
            continue  # holes are handled with their parent
        ring = cv2.approxPolyDP(c, epsilon, True).reshape(-1, 2)
        if len(ring) < 3:
            continue
        area = cv2.contourArea(c)
        j = hierarchy[i][2]
        while keep_holes and j != -1:
            if cv2.contourArea(contours[j]) >= min_hole_area:
                hole = cv2.approxPolyDP(contours[j], epsilon, True).reshape(-1, 2)
                if len(hole) >= 3:
                    ring = _bridge(ring, hole)
                    area -= cv2.contourArea(contours[j])
            j = hierarchy[j][0]
        out.append((ring.astype(float).ravel().tolist(), float(area)))
    return sorted(out, key=lambda p: -p[1])


def polygons_to_mask(polygons, shape):
    """Inverse of mask_to_polygons (even-odd fill), for checking the round trip."""
    m = np.zeros(shape, np.uint8)
    for poly in polygons:
        pts = np.round(np.asarray(poly, float).reshape(-1, 2)).astype(np.int32)
        cv2.fillPoly(m, [pts], 1)
    return m.astype(bool)


def coverage_primary_leaf(masks, names):
    """Backend rule (backend/app/coverage.py): primary leaf = largest leaf; its region = mask with holes filled plus
    the uncovered disease pixels nearest to it (YOLO trained with overlap_mask=True predicts leaves with holes where
    the lesions are); disease % = disease pixels in that region / region pixels × 100."""
    leaves = [_fill_holes(np.asarray(m, bool)) for m, n in zip(masks, names) if n == "leaf" and np.any(m)]
    if not leaves:
        return None
    shape = leaves[0].shape
    disease = {d: np.zeros(shape, bool) for d in DISEASES}
    for m, n in zip(masks, names):
        if n in disease:
            disease[n] |= np.asarray(m, bool)
    any_disease = np.logical_or.reduce(list(disease.values()))

    leaves.sort(key=lambda m: int(m.sum()), reverse=True)
    covered = np.logical_or.reduce(leaves)
    index = np.zeros(shape, np.int32)
    for i, r in enumerate(leaves, 1):
        index[r] = i
    region = leaves[0]
    orphans = any_disease & ~covered
    if orphans.any():
        dist, labels = cv2.distanceTransformWithLabels((~covered).astype(np.uint8), cv2.DIST_L2, 5,
                                                       labelType=cv2.DIST_LABEL_PIXEL)
        lut = np.zeros(labels.max() + 1, np.int32)
        lut[labels[covered]] = index[covered]
        region = region | (orphans & (lut[labels] == 1) & (dist <= ATTACH_DISTANCE * max(shape)))
    return {d: 100 * (disease[d] & region).sum() / region.sum() for d in DISEASES}


def ensure_dataset(root, project, version, api_key, workspace):
    """Download a Roboflow dataset version (COCO + YOLO polygons) into root/datasets/<project>-v<version>-{coco,yolo}
    unless it is there already, and point data.yaml at the local folders (splits a version lacks, e.g. a test-only
    project, fall back to the test images). Returns (coco_dir, yolo_data_yaml)."""
    import yaml

    name = f"{project}-v{version}"
    coco_dir, yolo_dir = Path(root) / "datasets" / f"{name}-coco", Path(root) / "datasets" / f"{name}-yolo"
    if not coco_dir.exists() or not yolo_dir.exists():
        from roboflow import Roboflow

        v = Roboflow(api_key=api_key).workspace(workspace).project(project).version(int(version))
        if not coco_dir.exists():
            v.download("coco-segmentation", location=str(coco_dir))
        if not yolo_dir.exists():
            v.download("yolov8", location=str(yolo_dir))
    data_yaml = yolo_dir / "data.yaml"
    data = yaml.safe_load(data_yaml.read_text())
    present = {s: f"{s}/images" for s in ("train", "valid", "test") if (yolo_dir / s / "images").exists()}
    fallback = present.get("test") or next(iter(present.values()))
    data.update(path=str(yolo_dir), train=present.get("train", fallback), val=present.get("valid", fallback),
                test=present.get("test", fallback))
    data_yaml.write_text(yaml.safe_dump(data, sort_keys=False))
    return coco_dir, data_yaml


def confusion(gt_map, pred_map, n=len(CLASSES)):
    return np.bincount(gt_map.ravel().astype(np.int64) * n + pred_map.ravel(), minlength=n * n).reshape(n, n)


def severity(pct):
    return next(name for limit, name in SEVERITY_BANDS if pct < limit)


def lins_ccc(x, y):
    """Lin's concordance correlation coefficient (agreement, not just correlation)."""
    x, y = np.asarray(x, float), np.asarray(y, float)
    if len(x) < 2:
        return float("nan")
    cov = np.mean((x - x.mean()) * (y - y.mean()))
    return float(2 * cov / (x.var() + y.var() + (x.mean() - y.mean()) ** 2))


def count_params(model):
    """Parameter count for YOLO, RF-DETR or semseg model objects (None if unknown)."""
    for obj in (model, getattr(model, "model", None), getattr(getattr(model, "model", None), "model", None)):
        if isinstance(obj, torch.nn.Module):
            return sum(p.numel() for p in obj.parameters())
    return None
