"""ONNX model loading and inference: image → per-instance masks with class + confidence.

Handles both exports from training/04_export.ipynb, detected from the graph's outputs:
- YOLO-seg (Ultralytics): letterboxed input; `output0` boxes + scores + mask coefficients
  (end-to-end `[1, N, 6 + nm]` for YOLO26, or `[1, 4 + nc + nm, N]` needing NMS for older YOLOs)
  and `output1` mask prototypes `[1, nm, S/4, S/4]`.
- RF-DETR-Seg: resized + ImageNet-normalized input; `dets` (cx cy w h, normalized),
  `labels` (class logits) and `masks` (per-query mask logits).
"""

import ast
import logging

import cv2
import numpy as np
import onnxruntime as ort

log = logging.getLogger(__name__)

# Roboflow COCO exports put a superclass at id 0, then the classes alphabetically.
RFDETR_DEFAULT_CLASSES = ["_superclass", "leaf", "leaf_spot", "powdery_mildew"]
IMAGENET_MEAN = np.array([0.485, 0.456, 0.406], np.float32)
IMAGENET_STD = np.array([0.229, 0.224, 0.225], np.float32)
NMS_IOU = 0.7
# Leaf masks: a box side counts as "cut" when the full mask covers at least this share of the line just outside it;
# cut sides are widened by this fraction of the box size (training/14 + leaf crop experiment: no flat cuts left,
# leaf IoU 0.975 -> 0.981 on the from-scratch test photos, no loss on the 49 pre-labelled ones).
LEAF_CUT_FRAC = 0.15
LEAF_CROP_PAD = 0.25


def _sigmoid(x: np.ndarray) -> np.ndarray:
    return 1 / (1 + np.exp(-x))


def _box_px(box: np.ndarray, w: int, h: int) -> tuple[int, int, int, int]:
    x1, y1, x2, y2 = np.clip(np.round(box), 0, [w, h, w, h]).astype(int)
    return int(x1), int(y1), int(x2), int(y2)


def crop_to_box(mask: np.ndarray, box: np.ndarray) -> np.ndarray:
    """YOLO-seg masks are only valid inside the instance's box (Ultralytics crops them the same way)."""
    h, w = mask.shape
    x1, y1, x2, y2 = _box_px(box, w, h)
    out = np.zeros_like(mask)
    out[y1:y2, x1:x2] = mask[y1:y2, x1:x2]
    return out


def crop_leaf(mask: np.ndarray, box: np.ndarray) -> np.ndarray:
    """Box crop for leaves, but where the predicted box is too short (common for big leaves, especially ones running
    off the photo) the plain crop cuts the leaf along a straight line. Widen only the sides the mask clearly continues
    past, then keep only the mask parts connected to the box so a neighbouring leaf isn't pulled in."""
    h, w = mask.shape
    x1, y1, x2, y2 = _box_px(box, w, h)
    if x2 - x1 < 2 or y2 - y1 < 2:
        return crop_to_box(mask, box)
    bw, bh = x2 - x1, y2 - y1
    ex1, ey1, ex2, ey2 = x1, y1, x2, y2
    if y1 > 0 and mask[y1 - 1, x1:x2].mean() >= LEAF_CUT_FRAC:
        ey1 = max(0, int(y1 - LEAF_CROP_PAD * bh))
    if y2 < h and mask[y2, x1:x2].mean() >= LEAF_CUT_FRAC:
        ey2 = min(h, int(y2 + LEAF_CROP_PAD * bh))
    if x1 > 0 and mask[y1:y2, x1 - 1].mean() >= LEAF_CUT_FRAC:
        ex1 = max(0, int(x1 - LEAF_CROP_PAD * bw))
    if x2 < w and mask[y1:y2, x2].mean() >= LEAF_CUT_FRAC:
        ex2 = min(w, int(x2 + LEAF_CROP_PAD * bw))
    if (ex1, ey1, ex2, ey2) == (x1, y1, x2, y2):
        return crop_to_box(mask, box)
    widened = np.zeros_like(mask)
    widened[ey1:ey2, ex1:ex2] = mask[ey1:ey2, ex1:ex2]
    _, labels = cv2.connectedComponents(widened.astype(np.uint8))
    inside = np.unique(labels[y1:y2, x1:x2])
    return np.isin(labels, inside[inside > 0])


def _providers() -> list[str]:
    """CUDA when onnxruntime-gpu is installed (requirements-gpu.txt), else CPU (the default, e.g. on Cloud Run)."""
    if "CUDAExecutionProvider" not in ort.get_available_providers():
        return ["CPUExecutionProvider"]
    try:  # load the CUDA/cuDNN DLLs shipped as pip wheels (onnxruntime-gpu[cuda,cudnn])
        ort.preload_dlls()
    except Exception as e:  # noqa: BLE001 - a system CUDA install may still work
        log.warning("Could not preload CUDA DLLs: %s", e)
    return ["CUDAExecutionProvider", "CPUExecutionProvider"]


class SegmentationModel:
    def __init__(
        self, model_path: str, class_names: list[str] | None = None, max_detections: int = 100, version: str = ""
    ) -> None:
        self.version = version
        self.session = ort.InferenceSession(model_path, providers=_providers())
        self.device = "gpu" if self.session.get_providers()[0] == "CUDAExecutionProvider" else "cpu"
        self.max_detections = max_detections
        self.input_name = self.session.get_inputs()[0].name
        meta = self.session.get_modelmeta().custom_metadata_map
        outputs = self.session.get_outputs()
        self.output_names = [o.name for o in outputs]
        self.kind = "yolo" if len(outputs) == 2 else "rfdetr"
        self.input_hw = self._input_size(meta)

        if class_names:
            self.class_names = class_names
        elif self.kind == "yolo" and "names" in meta:
            names = ast.literal_eval(meta["names"])  # "{0: 'leaf', 1: 'leaf_spot', ...}"
            self.class_names = [names[i] for i in sorted(names)]
        else:
            self.class_names = RFDETR_DEFAULT_CLASSES
        log.info(
            "Loaded %s model %s on %s, input %s, classes %s",
            self.kind, model_path, self.device.upper(), self.input_hw, self.class_names,
        )

    def _input_size(self, meta: dict) -> tuple[int, int]:
        shape = self.session.get_inputs()[0].shape  # [1, 3, H, W]; H/W are strings if dynamic
        if isinstance(shape[2], int) and isinstance(shape[3], int):
            return shape[2], shape[3]
        if "imgsz" in meta:
            h, w = ast.literal_eval(meta["imgsz"])
            return int(h), int(w)
        return 640, 640

    def predict(self, image: np.ndarray, min_confidence: float = 0.25) -> list[dict]:
        """image: RGB uint8 (H, W, 3).
        Return [{"class_name": str, "confidence": float, "mask": np.ndarray[bool] (H, W)}]."""
        if self.kind == "yolo":
            return self._predict_yolo(image, min_confidence)
        return self._predict_rfdetr(image, min_confidence)

    def _name(self, class_id: int) -> str:
        return self.class_names[class_id] if 0 <= class_id < len(self.class_names) else f"class_{class_id}"

    # --- YOLO-seg -------------------------------------------------------------------------------

    def _predict_yolo(self, image: np.ndarray, conf: float) -> list[dict]:
        h0, w0 = image.shape[:2]
        sh, sw = self.input_hw
        r = min(sh / h0, sw / w0)
        nh, nw = round(h0 * r), round(w0 * r)
        top, left = (sh - nh) // 2, (sw - nw) // 2
        canvas = np.full((sh, sw, 3), 114, np.uint8)
        canvas[top : top + nh, left : left + nw] = cv2.resize(image, (nw, nh), interpolation=cv2.INTER_LINEAR)
        x = (canvas.transpose(2, 0, 1)[None].astype(np.float32)) / 255

        out = self.session.run(None, {self.input_name: x})
        protos = next(o for o in out if o.ndim == 4)[0]  # (nm, mh, mw)
        pred = next(o for o in out if o.ndim == 3)[0]
        nm, mh, mw = protos.shape

        if pred.shape[-1] == 6 + nm:  # end-to-end: (N, x1 y1 x2 y2 score cls coeffs...)
            boxes, scores, cls, coefs = pred[:, :4], pred[:, 4], pred[:, 5].astype(int), pred[:, 6:]
            keep = np.flatnonzero(scores >= conf)
        else:  # (4 + nc + nm, N): cx cy w h, class scores, coeffs
            pred = pred.T
            nc = pred.shape[1] - 4 - nm
            cls_scores = pred[:, 4 : 4 + nc]
            cls, scores = cls_scores.argmax(1), cls_scores.max(1)
            cxcywh, coefs = pred[:, :4], pred[:, 4 + nc :]
            boxes = np.concatenate([cxcywh[:, :2] - cxcywh[:, 2:] / 2, cxcywh[:, :2] + cxcywh[:, 2:] / 2], 1)
            cand = np.flatnonzero(scores >= conf)
            xywh = np.concatenate([boxes[cand, :2], boxes[cand, 2:] - boxes[cand, :2]], 1)
            nms = cv2.dnn.NMSBoxesBatched(xywh.tolist(), scores[cand].tolist(), cls[cand].tolist(), conf, NMS_IOU)
            keep = cand[np.asarray(nms, int).reshape(-1)]
        keep = keep[np.argsort(-scores[keep])][: self.max_detections]
        if keep.size == 0:
            return []

        mask_logits = (coefs[keep] @ protos.reshape(nm, -1)).reshape(-1, mh, mw)
        # Letterbox padding in prototype coordinates, removed before resizing to the original image.
        py0, px0 = int(top * mh / sh), int(left * mw / sw)
        py1, px1 = int(round((top + nh) * mh / sh)), int(round((left + nw) * mw / sw))
        scaled = (boxes[keep] - [left, top, left, top]) / r

        results = []
        for logits, box, score, c in zip(mask_logits, scaled, scores[keep], cls[keep]):
            m = cv2.resize(logits[py0:py1, px0:px1], (w0, h0), interpolation=cv2.INTER_LINEAR) > 0  # sigmoid > 0.5
            name = self._name(int(c))
            cropped = crop_leaf(m, box) if name == "leaf" else crop_to_box(m, box)
            results.append({"class_name": name, "confidence": float(score), "mask": cropped})
        return results

    # --- RF-DETR-Seg ----------------------------------------------------------------------------

    def _predict_rfdetr(self, image: np.ndarray, conf: float) -> list[dict]:
        h0, w0 = image.shape[:2]
        sh, sw = self.input_hw
        x = cv2.resize(image, (sw, sh), interpolation=cv2.INTER_LINEAR).astype(np.float32) / 255
        x = ((x - IMAGENET_MEAN) / IMAGENET_STD).transpose(2, 0, 1)[None].astype(np.float32)

        out = dict(zip(self.output_names, self.session.run(None, {self.input_name: x})))
        masks = out.get("masks", next((o for o in out.values() if o.ndim == 4), None))
        logits = out.get("labels", next(o for o in out.values() if o.ndim == 3 and o.shape[-1] != 4))
        if masks is None:
            raise RuntimeError("RF-DETR model has no mask output; export the segmentation variant")
        prob = _sigmoid(logits[0])  # (Q, C)
        cls, scores = prob.argmax(1), prob.max(1)
        keep = np.flatnonzero(scores >= conf)
        keep = keep[np.argsort(-scores[keep])][: self.max_detections]

        return [
            {
                "class_name": self._name(int(cls[q])),
                "confidence": float(scores[q]),
                "mask": cv2.resize(masks[0, q], (w0, h0), interpolation=cv2.INTER_LINEAR) > 0,
            }
            for q in keep
        ]
