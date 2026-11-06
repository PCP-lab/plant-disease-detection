"""Draw colored disease/leaf masks over the photo and encode as JPEG."""

import cv2
import numpy as np

CLASS_COLORS = {
    "leaf": (46, 160, 67),
    "leaf_spot": (180, 95, 6),
    "powdery_mildew": (230, 230, 250),
}
# Leaves are tinted lightly so the diseases on top stay readable; drawn in this order.
CLASS_ALPHA = {"leaf": 0.25, "leaf_spot": 0.6, "powdery_mildew": 0.6}
OVERLAY_JPEG_QUALITY = 85


def render_overlay(image: np.ndarray, predictions: list[dict]) -> bytes:
    """image: RGB uint8 (H, W, 3); predictions as returned by SegmentationModel.predict."""
    out = image.astype(np.float32)
    for class_name, color in CLASS_COLORS.items():
        union = np.zeros(image.shape[:2], bool)
        for p in predictions:
            if p["class_name"] == class_name:
                union |= p["mask"]
        if not union.any():
            continue
        alpha = CLASS_ALPHA[class_name]
        out[union] = out[union] * (1 - alpha) + np.array(color, np.float32) * alpha

    out = out.astype(np.uint8)
    thickness = max(1, round(max(image.shape[:2]) / 400))
    for class_name, color in CLASS_COLORS.items():
        for p in predictions:
            if p["class_name"] == class_name:
                contours, _ = cv2.findContours(p["mask"].astype(np.uint8), cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
                cv2.drawContours(out, contours, -1, color, thickness, lineType=cv2.LINE_AA)

    # JPEG: the overlay is an opaque photo, ~10× smaller than PNG; it's kept on the user's phone.
    ok, jpeg = cv2.imencode(".jpg", cv2.cvtColor(out, cv2.COLOR_RGB2BGR), [cv2.IMWRITE_JPEG_QUALITY, OVERLAY_JPEG_QUALITY])
    if not ok:
        raise RuntimeError("JPEG encoding failed")
    return jpeg.tobytes()
