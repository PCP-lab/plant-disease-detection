"""Per-pixel (semantic) leaf-disease segmentation: a pretrained ViT backbone (BioTrove-CLIP by default) + a light decoder.

Shared by 05_biotrove_semseg.ipynb (training), 03_evaluate.ipynb and 06_backbone_study.ipynb.
Pixel classes: 0 background, 1 leaf, 2 leaf_spot, 3 powdery_mildew (disease pixels override leaf).
"""

import contextlib
import csv
import io
import json
import random
import time
from pathlib import Path

import numpy as np
import timm
import torch
import torch.nn as nn
import torch.nn.functional as F
from PIL import Image

CLASSES = ("background", "leaf", "leaf_spot", "powdery_mildew")
DISEASES = ("leaf_spot", "powdery_mildew")
PAINT_ORDER = ("leaf", "powdery_mildew", "leaf_spot")  # later classes win where masks overlap
FEATURE_BLOCKS = (3, 5, 7, 11)  # ViT blocks whose outputs feed the decoder

BACKBONES = {
    # BioTrove-CLIP ViT-B/16: OpenAI CLIP B/16 trained further on ~40M plant/animal images (MIT)
    "biotrove-b16": {
        "timm": "vit_base_patch16_clip_224.openai",
        "hf": ("BGLab/BioTrove-CLIP", "biotroveclip-vit-b-16-from-openai-epoch-40.pt"),
    },
    "clip-b16": {"timm": "vit_base_patch16_clip_224.openai"},
    "dinov2-b14": {"timm": "vit_base_patch14_dinov2.lvd142m"},
    "imagenet-b16": {"timm": "vit_base_patch16_224.augreg_in21k_ft_in1k"},
}


# ---------------------------------------------------------------- model


def _load_biotrove(model, repo, filename):
    from huggingface_hub import hf_hub_download
    from timm.models.vision_transformer import checkpoint_filter_fn

    sd = torch.load(hf_hub_download(repo, filename), map_location="cpu", weights_only=False)["state_dict"]
    sd = {k.removeprefix("module."): v for k, v in sd.items() if k.startswith("module.visual.")}
    missing, unexpected = model.load_state_dict(checkpoint_filter_fn(sd, model), strict=False)
    assert not missing, f"BioTrove weights missing for: {missing}"
    # Only CLIP's image-text projection is left over; segmentation doesn't use it
    assert set(unexpected) <= {"head.weight", "head.bias"}, f"unexpected BioTrove keys: {unexpected}"


def build_backbone(name, pretrained=True):
    cfg = BACKBONES[name]
    # dynamic_img_size interpolates the position embeddings to any input size (e.g. 1024 px)
    model = timm.create_model(cfg["timm"], pretrained=pretrained and "hf" not in cfg, num_classes=0, dynamic_img_size=True)
    if pretrained and "hf" in cfg:
        _load_biotrove(model, *cfg["hf"])
    return model


class _Fuse(nn.Module):
    def __init__(self, dim):
        super().__init__()
        self.body = nn.Sequential(
            nn.Conv2d(dim, dim, 3, padding=1, bias=False), nn.GroupNorm(32, dim), nn.ReLU(inplace=True),
            nn.Conv2d(dim, dim, 3, padding=1, bias=False), nn.GroupNorm(32, dim),
        )

    def forward(self, x):
        return F.relu(x + self.body(x))


class SemSegModel(nn.Module):
    """ViT backbone → 4 intermediate feature maps → DPT-style pyramid (strides 4/8/16/32 of the patch grid)
    → top-down fusion → per-pixel logits at input resolution."""

    def __init__(self, backbone="biotrove-b16", num_classes=len(CLASSES), dim=256, pretrained=True):
        super().__init__()
        self.backbone_name = backbone
        self.backbone = build_backbone(backbone, pretrained)
        cfg = self.backbone.pretrained_cfg
        self.register_buffer("mean", torch.tensor(cfg["mean"]).view(1, 3, 1, 1), persistent=False)
        self.register_buffer("std", torch.tensor(cfg["std"]).view(1, 3, 1, 1), persistent=False)
        self.patch = self.backbone.patch_embed.patch_size[0]
        c = self.backbone.embed_dim
        self.proj = nn.ModuleList(nn.Conv2d(c, dim, 1) for _ in FEATURE_BLOCKS)
        self.resample = nn.ModuleList([
            nn.ConvTranspose2d(dim, dim, 4, stride=4),
            nn.ConvTranspose2d(dim, dim, 2, stride=2),
            nn.Identity(),
            nn.Conv2d(dim, dim, 3, stride=2, padding=1),
        ])
        self.fuse = nn.ModuleList(_Fuse(dim) for _ in FEATURE_BLOCKS)
        self.head = nn.Sequential(
            nn.Conv2d(dim, dim, 3, padding=1, bias=False), nn.GroupNorm(32, dim), nn.ReLU(inplace=True),
            nn.Conv2d(dim, num_classes, 1),
        )

    def forward(self, x):
        """x: (B, 3, H, W) RGB in [0, 1] → logits (B, num_classes, H, W)."""
        h, w = x.shape[-2:]
        x = (x - self.mean) / self.std
        size = (round(h / self.patch) * self.patch, round(w / self.patch) * self.patch)  # e.g. 1022 for 14-px patches
        if size != (h, w):
            x = F.interpolate(x, size=size, mode="bilinear", align_corners=False)
        feats = self.backbone.forward_intermediates(
            x, indices=list(FEATURE_BLOCKS), output_fmt="NCHW", intermediates_only=True
        )
        feats = [r(p(f)) for f, p, r in zip(feats, self.proj, self.resample)]
        y = self.fuse[-1](feats[-1])
        for i in range(len(feats) - 2, -1, -1):
            y = F.interpolate(y, size=feats[i].shape[-2:], mode="bilinear", align_corners=False)
            y = self.fuse[i](y + feats[i])
        return F.interpolate(self.head(y), size=(h, w), mode="bilinear", align_corners=False)


def param_groups(model, backbone_lr, decoder_lr, layer_decay=0.75, weight_decay=0.05):
    """AdamW groups with layer-wise lr decay on the backbone: the last block gets backbone_lr,
    each earlier block layer_decay times less. No weight decay on norms, biases, embeddings."""
    depth = len(model.backbone.blocks)
    groups = {}
    for name, p in model.named_parameters():
        if not p.requires_grad:
            continue
        no_wd = p.ndim <= 1 or any(k in name for k in ("pos_embed", "cls_token", "reg_token"))
        if name.startswith("backbone."):
            n = name.removeprefix("backbone.")
            layer = int(n.split(".")[1]) + 1 if n.startswith("blocks.") else depth + 1 if n.startswith(("norm.", "fc_norm.")) else 0
            lr = backbone_lr * layer_decay ** (depth + 1 - layer)
        else:
            layer, lr = "decoder", decoder_lr
        groups.setdefault((layer, no_wd), {"params": [], "lr": lr, "weight_decay": 0.0 if no_wd else weight_decay})["params"].append(p)
    return list(groups.values())


# ---------------------------------------------------------------- labels and data


def paint_class_map(masks, names, shape):
    """Per-pixel class map from instance masks: leaves first, diseases painted on top."""
    out = np.zeros(shape, np.uint8)
    for cls in PAINT_ORDER:
        for m, n in zip(masks, names):
            if n == cls:
                out[np.asarray(m, bool)] = CLASSES.index(cls)
    return out


def ensure_label_cache(split_dir):
    """Write one class-map PNG per image to <split>/_semseg/ (only missing ones); return [(image, label_png)]."""
    from pycocotools.coco import COCO

    split_dir = Path(split_dir)
    out_dir = split_dir / "_semseg"
    out_dir.mkdir(exist_ok=True)
    with contextlib.redirect_stdout(io.StringIO()):
        coco = COCO(str(split_dir / "_annotations.coco.json"))
    names = {c["id"]: c["name"] for c in coco.loadCats(coco.getCatIds())}
    items = []
    for img in coco.loadImgs(coco.getImgIds()):
        target = out_dir / (Path(img["file_name"]).stem + ".png")
        if not target.exists():
            anns = coco.loadAnns(coco.getAnnIds(imgIds=img["id"]))
            masks = [coco.annToMask(a).astype(bool) for a in anns]
            cmap = paint_class_map(masks, [names[a["category_id"]] for a in anns], (img["height"], img["width"]))
            Image.fromarray(cmap).save(target)
        items.append((split_dir / img["file_name"], target))
    return items


class SemSegDataset(torch.utils.data.Dataset):
    """(image in [0, 1], class map) pairs; train=True adds flips and brightness jitter (no hue change)."""

    def __init__(self, items, imgsz, train=False):
        self.items, self.imgsz, self.train = list(items), imgsz, train

    def __len__(self):
        return len(self.items)

    def __getitem__(self, i):
        img_path, label_path = self.items[i]
        img, label = Image.open(img_path).convert("RGB"), Image.open(label_path)
        if img.size != (self.imgsz, self.imgsz):  # Roboflow export is already square at 1024
            img = img.resize((self.imgsz, self.imgsz), Image.BILINEAR)
            label = label.resize((self.imgsz, self.imgsz), Image.NEAREST)
        x = torch.from_numpy(np.array(img)).permute(2, 0, 1).float().div_(255)
        y = torch.from_numpy(np.array(label).astype(np.int64))
        if self.train:
            if random.random() < 0.5:
                x, y = x.flip(-1), y.flip(-1)
            if random.random() < 0.5:
                x, y = x.flip(-2), y.flip(-2)
            x = (x * random.uniform(0.85, 1.15)).clamp_(0, 1)
        return x, y


def class_pixel_weights(items):
    """Cross-entropy weights ∝ 1/sqrt(pixel frequency), normalized to mean 1 (rare spots/mildew count more)."""
    counts = np.zeros(len(CLASSES), np.int64)
    for _, label_path in items:
        counts += np.bincount(np.array(Image.open(label_path)).ravel(), minlength=len(CLASSES))[: len(CLASSES)]
    w = 1 / np.sqrt(np.maximum(counts / counts.sum(), 1e-8))
    return torch.tensor(w / w.mean(), dtype=torch.float32)


# ---------------------------------------------------------------- loss and metrics


def seg_loss(logits, target, class_weights):
    """Weighted cross-entropy + soft Dice over the leaf/disease classes."""
    ce = F.cross_entropy(logits, target, weight=class_weights)
    probs = logits.softmax(1)
    onehot = F.one_hot(target, logits.shape[1]).permute(0, 3, 1, 2).to(probs.dtype)
    inter = (probs * onehot).sum((0, 2, 3))
    total = probs.sum((0, 2, 3)) + onehot.sum((0, 2, 3))
    dice = 1 - (2 * inter + 1) / (total + 1)
    return ce + dice[1:].mean()


def image_coverage(cmap):
    """Disease % of all leaf pixels in a class map (leaf region = leaf + disease pixels); None if no leaf."""
    leaf = float((cmap > 0).sum())
    if leaf == 0:
        return None
    return {d: 100 * float((cmap == CLASSES.index(d)).sum()) / leaf for d in DISEASES}


def iou_from_confusion(conf):
    """IoU per class; NaN for a class absent from both ground truth and prediction (left out of means)."""
    conf = np.asarray(conf, np.float64)
    inter = np.diag(conf)
    union = conf.sum(0) + conf.sum(1) - inter
    iou = np.where(union > 0, inter / np.maximum(union, 1), np.nan)
    return {c: float(v) for c, v in zip(CLASSES, iou)}


@torch.no_grad()
def evaluate(model, loader, device):
    """Per-class IoU, mIoU (all classes and leaf/disease only) and image-level coverage MAE."""
    model.eval()
    n = len(CLASSES)
    conf = torch.zeros(n * n, dtype=torch.long, device=device)
    errors = {d: [] for d in DISEASES}
    for x, y in loader:
        x, y = x.to(device, non_blocking=True), y.to(device, non_blocking=True)
        with torch.autocast("cuda", dtype=torch.bfloat16):
            pred = model(x).argmax(1)
        conf += torch.bincount((y * n + pred).flatten(), minlength=n * n)
        for p, t in zip(pred, y):
            gt, pr = image_coverage(t), image_coverage(p)
            if gt is not None and pr is not None:
                for d in DISEASES:
                    errors[d].append(abs(pr[d] - gt[d]))
    iou = iou_from_confusion(conf.view(n, n).cpu().numpy())
    return {
        "iou": iou,
        "miou": float(np.nanmean(list(iou.values()))),
        "miou_fg": float(np.nanmean([iou[c] for c in CLASSES[1:]])),
        "coverage_mae": {d: float(np.mean(e)) if e else float("nan") for d, e in errors.items()},
    }


# ---------------------------------------------------------------- checkpoints


def save_checkpoint(run_dir, model, optimizer, scheduler, epoch, epochs, best, history, settings, is_best):
    """checkpoint_last.pth (resumable), checkpoint_best.pth (weights only), history.csv, state.json."""
    run_dir = Path(run_dir)
    meta = {"kind": "semseg", "backbone": model.backbone_name, "imgsz": settings["IMGSZ"], "classes": CLASSES, "settings": settings}

    def write(path, obj):
        tmp = path.with_suffix(".tmp")
        torch.save(obj, tmp)
        # Swap in atomically so an interrupted run never leaves a half-written checkpoint. On Windows the
        # swap fails with "Access is denied" while antivirus, OneDrive or another process briefly holds the
        # old file open, so retry a few times before giving up.
        for attempt in range(6):
            try:
                tmp.replace(path)
                return
            except PermissionError:
                time.sleep(1.0 + attempt)
        # Still locked: don't kill a multi-hour run over one checkpoint. The finished .tmp stays on disk and
        # the next epoch's save tries again (the previous checkpoint_last.pth is still valid for resuming).
        print(f"WARNING: could not replace {path.name} (file locked by another process); will retry next epoch")

    write(run_dir / "checkpoint_last.pth", {
        **meta, "model": model.state_dict(), "optimizer": optimizer.state_dict(), "scheduler": scheduler.state_dict(),
        "epoch": epoch, "best_miou_fg": best, "history": history,
    })
    if is_best:
        write(run_dir / "checkpoint_best.pth", {**meta, "model": model.state_dict(), "epoch": epoch, "metrics": history[-1]})
    with open(run_dir / "history.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(history[0]))
        w.writeheader()
        w.writerows(history)
    (run_dir / "state.json").write_text(json.dumps({"epoch": epoch, "epochs": epochs, "finished": epoch >= epochs}))


def load_model(checkpoint, device="cuda"):
    ck = torch.load(checkpoint, map_location="cpu", weights_only=False)
    model = SemSegModel(ck["backbone"], pretrained=False)
    model.load_state_dict(ck["model"])
    model.imgsz = ck["imgsz"]
    return model.to(device).eval()


# ---------------------------------------------------------------- inference


@torch.no_grad()
def predict_probs(model, image, device="cuda"):
    """PIL image → class probabilities (C, H, W) at the image's own size."""
    x = torch.from_numpy(np.array(image.convert("RGB"))).permute(2, 0, 1).float().div_(255)[None].to(device)
    h, w = x.shape[-2:]
    x = F.interpolate(x, size=(model.imgsz, model.imgsz), mode="bilinear", align_corners=False)
    with torch.autocast("cuda", dtype=torch.bfloat16):
        logits = model(x)
    return F.interpolate(logits.float(), size=(h, w), mode="bilinear", align_corners=False).softmax(1)[0]


def predict_instances(model, image, device="cuda", min_leaf_frac=0.001):
    """Same output as the YOLO/RF-DETR predictors in 03_evaluate: (masks [N, H, W] bool, names [N], confidences [N]).

    Leaves = connected regions of leaf+disease pixels (touching leaves merge into one region);
    each disease = one mask for all its pixels. Confidence = mean probability over the mask.
    """
    from scipy import ndimage

    conf, cls = predict_probs(model, image, device).max(0)
    conf, cls = conf.cpu().numpy(), cls.cpu().numpy()
    masks, names, scores = [], [], []
    labels, _ = ndimage.label(cls > 0)
    sizes = np.bincount(labels.ravel())
    for i in np.flatnonzero(sizes >= min_leaf_frac * cls.size):
        if i == 0:
            continue
        m = labels == i
        masks.append(m), names.append("leaf"), scores.append(float(conf[m].mean()))
    for d in DISEASES:
        m = cls == CLASSES.index(d)
        if m.any():
            masks.append(m), names.append(d), scores.append(float(conf[m].mean()))
    if not masks:
        return np.zeros((0, *cls.shape), bool), np.array([]), np.array([])
    return np.stack(masks), np.array(names), np.array(scores)
