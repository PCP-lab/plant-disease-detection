"""AI-assisted relabelling, used by 12_relabel.ipynb.

Per image, starting from the existing (human) labels:
- leaf: each labelled leaf is redrawn by SAM 2 from its box; kept only if SAM agrees with the old outline (IoU),
  otherwise the old outline stays and the image is flagged. Leaves the trained model finds with no label are added
  (flagged for review).
- leaf_spot: each spot is redrawn by SAM 2 from its padded box (same agreement check, and SAM may not grow it much);
  a colour check flags "spots" that are not darker / browner than the leaf around them; spots off every leaf are
  flagged; confident model spots with no label are added (flagged).
- powdery_mildew (default, mildew_mode="keep"): the human labels, cleaned (clipped to leaves, specks removed, spot
  pixels cut out) and checked by flags (whole-leaf labels, labels with nothing whitish or speckled inside, which may
  be leaf spot or healthy tissue). Experimental mildew_mode="classifier": a pixel classifier (random forest on colour /
  texture relative to the leaf's healthy colour) searches every leaf that has mildew; on glossy, quilted hydrangea
  leaves it marks bump highlights and misses real blotches, so it is off by default.
Test images never use the model (only the human labels), so test labels carry no model bias.
"""

from dataclasses import dataclass, field

import cv2
import numpy as np

from eval_utils import fill_holes, mask_to_polygons
from semseg import image_coverage, paint_class_map

COLOR_FEATURES = ("dL", "dC", "da", "db", "C", "tophat11", "tophat31", "std7", "std21", "edge_dist")


def feature_names(dino=None):
    return COLOR_FEATURES + (tuple(f"dino{i}" for i in range(dino.n)) if dino is not None else ())


class DinoFeatures:
    """Dense DINOv2 patch features (appearance / texture learned from 142 M images), reduced by PCA and upsampled to
    pixels. They separate dry white powder from glossy glare and pale veins far better than colour alone."""

    def __init__(self, name="vit_small_patch14_dinov2.lvd142m", n_components=12, side=1022, device="cuda"):
        import timm
        import torch

        self.torch, self.side, self.device, self.n = torch, side, device, n_components
        self.model = timm.create_model(name, pretrained=True, dynamic_img_size=True, num_classes=0).to(device).eval()
        cfg = self.model.pretrained_cfg
        self.norm = (torch.tensor(cfg["mean"]).view(3, 1, 1), torch.tensor(cfg["std"]).view(3, 1, 1))
        self.patch = self.model.patch_embed.patch_size[0]
        self.pca_mean = self.pca_axes = None

    def tokens(self, rgb):
        torch = self.torch
        x = torch.from_numpy(cv2.resize(rgb, (self.side, self.side), interpolation=cv2.INTER_AREA)).permute(2, 0, 1)
        x = (x.float() / 255 - self.norm[0]) / self.norm[1]
        with torch.no_grad(), torch.autocast("cuda", dtype=torch.bfloat16):
            f = self.model.forward_features(x[None].to(self.device))
        g = self.side // self.patch
        return f[0, self.model.num_prefix_tokens:].float().reshape(g, g, -1)

    def fit(self, rgbs):
        """PCA axes from the patch features of a few training images."""
        X = self.torch.cat([self.tokens(r).flatten(0, 1) for r in rgbs])
        self.pca_mean = X.mean(0)
        _, _, V = self.torch.pca_lowrank(X - self.pca_mean, q=self.n, center=False)
        self.pca_axes = V[:, : self.n]
        return self

    def __call__(self, rgb):
        torch = self.torch
        p = (self.tokens(rgb) - self.pca_mean) @ self.pca_axes  # [g, g, n]
        h, w = rgb.shape[:2]
        up = torch.nn.functional.interpolate(p.permute(2, 0, 1)[None], size=(h, w), mode="bilinear", align_corners=False)
        return up[0].permute(1, 2, 0).cpu().numpy().astype(np.float32)


@dataclass
class Settings:
    leaf_keep_iou: float = 0.7  # SAM leaf outline replaces the old one only if they overlap at least this much
    leaf_new_conf: float = 0.6  # model leaves above this, not covered by any label, are added
    leaf_new_max_overlap: float = 0.2  # ... "not covered" = at most this fraction under existing leaves
    leaf_new_min_frac: float = 0.002  # ... and at least this fraction of the image
    leaf_min_px: int = 100  # labelled "leaves" smaller than this are specks and are dropped
    spot_keep_iou: float = 0.6
    spot_max_growth: float = 1.6  # SAM spot may be at most this many times the old area (stops it taking the halo)
    spot_min_sam_px: int = 80  # smaller spots keep their hand outline (SAM is unreliable on a few pixels)
    spot_flag_px: int = 300  # only spots at least this big are flagged when SAM disagrees
    spot_box_pad: float = 0.2
    spot_new_conf: float = 0.5
    spot_brown_da: float = 2.0  # colour check: spot a* (red-green) above the ring around it by this much ...
    spot_dark_dL: float = -8.0  # ... or darker than the ring by this much (Lab L* units, 0-255 scale)
    # "keep": the human mildew labels, cleaned (clipped to leaves, specks removed, spots cut out) and checked by flags.
    # "classifier": the experimental pixel classifier. On glossy, quilted hydrangea leaves it confuses bump highlights
    # with powder and misses real blotches (checked at full resolution), so it is off by default.
    mildew_mode: str = "keep"
    mildew_model_conf: float = 0.15
    mildew_grow_px: int = 15
    mildew_whole_leaf_px: int = 30  # a leaf with at least this much mildew (label or model) is searched in full
    mildew_cutoff: float = 0.5  # classifier probability for "mildew"
    min_disease_px: int = 12
    max_hole_px: int = 30
    model_conf: float = 0.1


@dataclass
class Result:
    leaves: list = field(default_factory=list)  # bool masks
    spots: list = field(default_factory=list)
    mildew: np.ndarray = None  # one bool mask (split into parts when written)
    flags: dict = field(default_factory=dict)
    mildew_prob: np.ndarray = None  # float32, NaN outside the search region (for calibration pictures)


# ---------- small mask helpers ----------

def iou(a, b):
    u = (a | b).sum()
    return float((a & b).sum() / u) if u else 0.0


def box_of(mask, pad=0.0, shape=None, min_size=4):
    ys, xs = np.nonzero(mask)
    x0, y0, x1, y1 = xs.min(), ys.min(), xs.max() + 1, ys.max() + 1
    px = max(pad * (x1 - x0) + 2 * (pad > 0), (min_size - (x1 - x0)) / 2)
    py = max(pad * (y1 - y0) + 2 * (pad > 0), (min_size - (y1 - y0)) / 2)
    h, w = shape if shape is not None else mask.shape
    return [max(0.0, x0 - px), max(0.0, y0 - py), min(float(w), x1 + px), min(float(h), y1 + py)]


def dilate(mask, px):
    k = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * px + 1, 2 * px + 1))
    return cv2.dilate(mask.astype(np.uint8), k).astype(bool)


def largest_part(mask):
    n, lab, stats, _ = cv2.connectedComponentsWithStats(mask.astype(np.uint8), connectivity=8)
    if n <= 2:
        return mask
    return lab == 1 + int(np.argmax(stats[1:, cv2.CC_STAT_AREA]))


def clean_disease(mask, min_px, max_hole_px, smooth=False):
    m = mask.astype(np.uint8)
    if smooth:
        k = np.ones((3, 3), np.uint8)
        m = cv2.morphologyEx(cv2.morphologyEx(m, cv2.MORPH_OPEN, k), cv2.MORPH_CLOSE, k)
    n, lab, stats, _ = cv2.connectedComponentsWithStats(m, connectivity=8)
    keep = np.zeros(n, bool)
    keep[1:] = stats[1:, cv2.CC_STAT_AREA] >= min_px
    m = keep[lab]
    # fill small holes (background components that don't touch the border)
    n, lab, stats, _ = cv2.connectedComponentsWithStats((~m).astype(np.uint8), connectivity=4)
    h, w = m.shape
    for i in range(1, n):
        x, y, bw, bh, area = stats[i]
        if area < max_hole_px and x > 0 and y > 0 and x + bw < w and y + bh < h:
            m[lab == i] = True
    return m


def leaf_index_map(leaves):
    """1-based leaf index per pixel; larger leaves first, smaller painted last where leaves overlap."""
    shape = leaves[0].shape if leaves else None
    idx = np.zeros(shape, np.int32)
    for i in sorted(range(len(leaves)), key=lambda k: -int(leaves[k].sum())):
        idx[leaves[i]] = i + 1
    return idx


# ---------- mildew pixel features ----------

def lab_planes(rgb):
    lab = cv2.cvtColor(rgb, cv2.COLOR_RGB2LAB).astype(np.float32)
    return lab[..., 0], lab[..., 1] - 128, lab[..., 2] - 128


def pixel_features(rgb, leaves, dino=None):
    """[H, W, len(feature_names(dino))] float32: colour relative to each pixel's own leaf (median), local brightness
    detail (white top-hat: bright fine structure on a darker background, i.e. powder), local texture (std), distance to
    the leaf edge (shiny rims), and optionally DINOv2 appearance features."""
    L, a, b = lab_planes(rgb)
    C = np.hypot(a, b)
    rel = {k: np.zeros_like(L) for k in ("dL", "dC", "da", "db")}
    if leaves:
        # Reference = the leaf's healthy colour: the median of its darker half. (The plain median fails on heavily
        # coated leaves, where most of the leaf is already whitish and the powder no longer stands out.)
        idx = leaf_index_map(leaves)
        any_leaf = idx > 0

        def healthy_ref(sel):
            Lv = L[sel]
            dark = Lv <= np.median(Lv)
            return {k: float(np.median(v[sel][dark])) for k, v in (("L", L), ("C", C), ("a", a), ("b", b))}

        ref = healthy_ref(any_leaf)
        base = {k: np.full_like(L, ref[k]) for k in ref}
        for i in np.unique(idx[any_leaf]):
            sel = idx == i
            for k, v in healthy_ref(sel).items():
                base[k][sel] = v
        rel = {"dL": L - base["L"], "dC": C - base["C"], "da": a - base["a"], "db": b - base["b"]}
    L8 = np.clip(L, 0, 255).astype(np.uint8)
    tophat = [cv2.morphologyEx(L8, cv2.MORPH_TOPHAT, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (k, k)))
              .astype(np.float32) for k in (11, 31)]
    stds = []
    for k in (7, 21):
        mean = cv2.blur(L, (k, k))
        stds.append(np.sqrt(np.maximum(cv2.blur(L * L, (k, k)) - mean * mean, 0)))
    leaf = np.logical_or.reduce(leaves) if leaves else np.zeros(L.shape, bool)
    edge = np.minimum(cv2.distanceTransform(leaf.astype(np.uint8), cv2.DIST_L2, 5), 50).astype(np.float32)
    planes = [rel["dL"], rel["dC"], rel["da"], rel["db"], C, *tophat, *stds, edge]
    if dino is not None:
        planes += list(np.moveaxis(dino(rgb), -1, 0))
    return np.stack(planes, -1)


SPOT_RED_DA = 8.0  # a* gain over the healthy leaf above which tissue looks reddish-brown (leaf spot), not mildew


def training_pixels(rgb, leaves, mildew, spots, rng, n_pos=1500, n_neg=3000, n_spot=1500, white_quantile=0.5,
                    neg_dist=40, dino=None):
    """Automatic training pixels from existing labels.

    Positives = pixels inside mildew labels that look like mildew at any stage: greyer than the healthy leaf (chroma
    drop at least the label's median), not reddish-brown (that is leaf-spot tissue), and either brighter (white powder)
    or finely speckled (white top-hat; dark, dry, purplish-grey severe mildew keeps a fine powdery speckle). Pale veins
    and green caught inside loose outlines fail these tests.
    Negatives = leaf pixels far from any mildew label (healthy green, veins, glare, rims) and leaf-spot pixels, so the
    classifier learns that reddish-brown, smooth, sharp-edged spot tissue is not mildew."""
    if not leaves:
        return None, None
    feats = pixel_features(rgb, leaves, dino)
    leaf = np.logical_or.reduce(leaves)
    X, y = [], []
    pos_area = mildew & leaf & ~spots
    if pos_area.sum() >= 50:
        dL, dC, da, th = feats[..., 0], feats[..., 1], feats[..., 2], feats[..., 5]
        whiter = dL >= np.quantile(dL[pos_area], white_quantile)
        speckled = th >= np.quantile(th[pos_area], white_quantile)
        pos = np.argwhere(pos_area & (dC <= np.median(dC[pos_area])) & (da < SPOT_RED_DA) & (whiter | speckled))
        if len(pos):
            pick = pos[rng.choice(len(pos), min(n_pos, len(pos)), replace=False)]
            X.append(feats[pick[:, 0], pick[:, 1]]); y.append(np.ones(len(pick), np.uint8))
    far = cv2.distanceTransform((~mildew).astype(np.uint8), cv2.DIST_L2, 5) > neg_dist if mildew.any() else np.ones_like(leaf)
    for area, n in ((leaf & far & ~spots, n_neg), (spots & ~mildew, n_spot)):
        neg = np.argwhere(area)
        if len(neg):
            pick = neg[rng.choice(len(neg), min(n, len(neg)), replace=False)]
            X.append(feats[pick[:, 0], pick[:, 1]]); y.append(np.zeros(len(pick), np.uint8))
    return (np.concatenate(X), np.concatenate(y)) if X else (None, None)


# ---------- the per-image pipeline ----------

def model_predictions(model, path, conf):
    """Trained YOLO model → list of (class name, confidence, bool mask) at full image size."""
    r = model.predict(str(path), conf=conf, retina_masks=True, verbose=False)[0]
    if r.masks is None:
        return []
    masks = r.masks.data.cpu().numpy().astype(bool)
    return [(r.names[int(c)], float(s), m) for c, s, m in zip(r.boxes.cls, r.boxes.conf, masks)]


def sam_masks(sam, path, boxes):
    """One SAM mask per box, in box order (None where SAM gives nothing). All boxes go in one call (the image is
    encoded once); if SAM returns a different number of masks, the pairing can't be trusted and each box is redone."""
    if not boxes:
        return []
    r = sam(str(path), bboxes=boxes, verbose=False)[0]
    if r.masks is not None and len(r.masks.data) == len(boxes):
        return list(r.masks.data.cpu().numpy().astype(bool))
    out = []
    for b in boxes:
        r = sam(str(path), bboxes=[b], verbose=False)[0]
        out.append(r.masks.data[0].cpu().numpy().astype(bool) if r.masks is not None and len(r.masks.data) else None)
    return out


def relabel_image(path, rgb, old, sam, clf, model=None, s=Settings(), keep_prob=False, dino=None):
    """old: {"leaf": [masks], "leaf_spot": [masks], "powdery_mildew": [masks]} (human labels).
    model: trained YOLO for proposals and the mildew search region (None for test images)."""
    h, w = rgb.shape[:2]
    flags = {}
    preds = model_predictions(model, path, s.model_conf) if model is not None else []
    old_leaves = [fill_holes(m) for m in old["leaf"] if m.sum() >= s.leaf_min_px]
    if len(old_leaves) < len(old["leaf"]):
        flags["leaf_speck_removed"] = len(old["leaf"]) - len(old_leaves)
    old_spots = [m for m in old["leaf_spot"] if m.any()]
    old_mildew = np.logical_or.reduce(old["powdery_mildew"]) if old["powdery_mildew"] else np.zeros((h, w), bool)

    # Leaves and spots: one SAM call with every box (the image is encoded once)
    spot_sam_idx = [i for i, m in enumerate(old_spots) if m.sum() >= s.spot_min_sam_px]
    boxes = [box_of(m) for m in old_leaves] + [box_of(old_spots[i], s.spot_box_pad) for i in spot_sam_idx]
    out = sam_masks(sam, path, boxes)
    sam_leaf, sam_spot = out[:len(old_leaves)], dict(zip(spot_sam_idx, out[len(old_leaves):]))

    leaves = []
    for m, sm in zip(old_leaves, sam_leaf):
        sm = fill_holes(largest_part(sm)) if sm is not None and sm.any() else None
        if sm is not None and iou(sm, m) >= s.leaf_keep_iou:
            leaves.append(sm)
        else:
            leaves.append(m)
            flags["leaf_sam_rejected"] = flags.get("leaf_sam_rejected", 0) + 1

    # New leaves the model sees but nobody labelled
    covered = np.logical_or.reduce(leaves) if leaves else np.zeros((h, w), bool)
    new_leaf_boxes, new_leaf_masks = [], []
    for name, conf, m in preds:
        if name == "leaf" and conf >= s.leaf_new_conf and m.sum() >= s.leaf_new_min_frac * h * w:
            if (m & covered).sum() / m.sum() <= s.leaf_new_max_overlap:
                new_leaf_boxes.append(box_of(m)); new_leaf_masks.append(m); covered |= m
    for m, sm in zip(new_leaf_masks, sam_masks(sam, path, new_leaf_boxes)):
        sm = fill_holes(largest_part(sm)) if sm is not None and sm.any() else None
        leaves.append(sm if sm is not None and iou(sm, m) >= 0.6 else fill_holes(m))
        flags["leaf_added"] = flags.get("leaf_added", 0) + 1
    leaf_union = np.logical_or.reduce(leaves) if leaves else np.zeros((h, w), bool)
    leaf_near = dilate(leaf_union, 5)

    # Spots
    L, a, _ = lab_planes(rgb)
    spots = []
    for i, m in enumerate(old_spots):
        sm = sam_spot.get(i)
        sm = fill_holes(largest_part(sm)) if sm is not None and sm.any() else None
        if sm is not None and iou(sm, m) >= s.spot_keep_iou and sm.sum() <= s.spot_max_growth * m.sum():
            spots.append(sm)
        else:
            spots.append(m)
            if i in sam_spot and m.sum() >= s.spot_flag_px:
                flags["spot_sam_rejected"] = flags.get("spot_sam_rejected", 0) + 1
    L8 = np.clip(L, 0, 255).astype(np.uint8)
    speckle = cv2.morphologyEx(L8, cv2.MORPH_TOPHAT, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (11, 11)))
    for m in spots:
        ring = dilate(m, 7) & ~m & leaf_union
        if ring.sum() >= 10:
            da_rel, dL_rel = a[m].mean() - a[ring].mean(), L[m].mean() - L[ring].mean()
            if not (da_rel > s.spot_brown_da or dL_rel < s.spot_dark_dL):
                flags["spot_colour"] = flags.get("spot_colour", 0) + 1
            # grey / purplish-grey, finely speckled and not darker-edged: looks like dark (severe) mildew, not a spot
            if da_rel < 3 and np.median(speckle[m]) >= 8 and dL_rel > -10:
                flags["spot_maybe_mildew"] = flags.get("spot_maybe_mildew", 0) + 1
        if (m & leaf_near).sum() < 0.3 * m.sum():
            flags["spot_off_leaf"] = flags.get("spot_off_leaf", 0) + 1
    spot_union = dilate(np.logical_or.reduce(spots), 3) if spots else np.zeros((h, w), bool)
    for name, conf, m in preds:
        if name == "leaf_spot" and conf >= s.spot_new_conf and not (m & spot_union).any() and (m & leaf_union).sum() >= 0.5 * m.sum():
            spots.append(m & leaf_union); spot_union |= dilate(m, 3)
            flags["spot_added"] = flags.get("spot_added", 0) + 1
    spots = [m for m in (clean_disease(m, s.min_disease_px, s.max_hole_px) for m in spots) if m.any()]
    spot_px = np.logical_or.reduce(spots) if spots else np.zeros((h, w), bool)

    # Mildew: pixel classifier inside the search region = every leaf that has any mildew (labels, or the model for
    # train / valid) in full, plus the mildew areas widened a little (lesions on a leaf edge). Searching whole leaves
    # catches faint films nobody outlined.
    seed = old_mildew.copy()
    for name, conf, m in preds:
        if name == "powdery_mildew" and conf >= s.mildew_model_conf:
            seed |= m
    region = np.zeros((h, w), bool)
    if s.mildew_mode == "classifier" and seed.any():
        region = dilate(seed, s.mildew_grow_px)
        for leaf in leaves:
            if (leaf & seed).sum() >= s.mildew_whole_leaf_px:
                region |= leaf
        region &= leaf_union & ~spot_px
    mildew = np.zeros((h, w), bool)
    prob = None
    if region.any() and clf is not None:
        feats = pixel_features(rgb, leaves, dino)
        p = clf.predict_proba(feats[region])[:, 1].astype(np.float32)
        mildew[region] = p >= s.mildew_cutoff
        mildew = clean_disease(mildew, s.min_disease_px, s.max_hole_px, smooth=True) & leaf_union & ~spot_px
        if keep_prob:
            prob = np.full((h, w), np.nan, np.float32)
            prob[region] = p
    if s.mildew_mode == "keep":
        mildew = clean_disease(old_mildew & leaf_near & ~spot_px, s.min_disease_px, s.max_hole_px)

    # Flags about mildew
    old_cov = image_coverage(paint_class_map([*old_leaves, *old_spots, *old["powdery_mildew"]],
                                             ["leaf"] * len(old_leaves) + ["leaf_spot"] * len(old_spots)
                                             + ["powdery_mildew"] * len(old["powdery_mildew"]), (h, w)))
    new_cov = image_coverage(paint_class_map([*leaves, *spots, mildew],
                                             ["leaf"] * len(leaves) + ["leaf_spot"] * len(spots) + ["powdery_mildew"], (h, w)))
    if old_cov and new_cov:
        if abs(new_cov["powdery_mildew"] - old_cov["powdery_mildew"]) > 2:
            flags["mildew_big_change"] = 1
        if abs(new_cov["leaf_spot"] - old_cov["leaf_spot"]) > 2:
            flags["spot_big_change"] = 1
    for m in old["powdery_mildew"]:
        if m.sum() <= 200:
            continue
        ring = dilate(m, 6) & ~m & leaf_union
        # nothing whitish or finely speckled inside: probably not mildew (or a mis-drawn outline)
        if ring.sum() >= 10 and L[m].mean() - L[ring].mean() < 3 and np.median(speckle[m]) < 6:
            flags["mildew_label_not_white"] = flags.get("mildew_label_not_white", 0) + 1
    for leaf in old_leaves:
        if leaf.sum() > 1000 and (leaf & old_mildew).sum() > 0.6 * leaf.sum():
            flags["mildew_whole_leaf"] = flags.get("mildew_whole_leaf", 0) + 1

    return Result(leaves=leaves, spots=spots, mildew=mildew, flags=flags, mildew_prob=prob), old_cov, new_cov


def to_annotations(result, image_id, cat_ids, next_id, min_mildew_part=12):
    """Result → COCO annotations (leaves and spots: one polygon each, largest part; mildew: one annotation per
    connected patch, holes kept)."""
    anns = []

    def add(name, poly, mask_area, bbox):
        nonlocal next_id
        anns.append({"id": next_id, "image_id": image_id, "category_id": cat_ids[name], "segmentation": [poly],
                     "area": mask_area, "bbox": bbox, "iscrowd": 0})
        next_id += 1

    def bbox(m):
        x0, y0, x1, y1 = box_of(m)
        return [x0, y0, x1 - x0, y1 - y0]

    for name, masks in (("leaf", result.leaves), ("leaf_spot", result.spots)):
        for m in masks:
            polys = mask_to_polygons(m, keep_holes=False)
            if polys:
                add(name, polys[0][0], float(m.sum()), bbox(m))
    if result.mildew is not None and result.mildew.any():
        n, lab = cv2.connectedComponents(result.mildew.astype(np.uint8), connectivity=8)
        for i in range(1, n):
            part = lab == i
            if part.sum() < min_mildew_part:
                continue
            polys = mask_to_polygons(part)
            if polys:
                add("powdery_mildew", polys[0][0], float(part.sum()), bbox(part))
    return anns, next_id
