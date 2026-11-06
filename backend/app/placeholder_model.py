"""Stand-in for the fine-tuned model while models/leaf_disease_seg.onnx doesn't exist yet.

Colour thresholds in HSV, good enough to exercise the whole pipeline on real leaf photos:
leaf = green tissue (plus lesions enclosed by it), leaf spot = brown, powdery mildew = whitish.
Same predict() interface as SegmentationModel. Not a substitute for the trained model.
"""

import cv2
import numpy as np


class ColorHeuristicModel:
    version = "color-heuristic-placeholder"
    max_leaves = 5
    min_leaf_fraction = 0.01  # of the image area

    def predict(self, image: np.ndarray, min_confidence: float = 0.25) -> list[dict]:
        hsv = cv2.cvtColor(image, cv2.COLOR_RGB2HSV)
        h, s, v = (c.astype(np.int16) for c in cv2.split(hsv))  # OpenCV hue is 0–179
        green = (h >= 25) & (h <= 95) & (s >= 40) & (v >= 40)
        brown = ((h < 25) | (h >= 170)) & (s >= 60) & (v >= 30) & (v <= 210)
        white = (s < 45) & (v >= 170)

        k = max(3, round(max(image.shape[:2]) / 100)) | 1
        kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (k, k))
        green_u8 = cv2.morphologyEx(green.astype(np.uint8), cv2.MORPH_OPEN, kernel)
        near_leaf = cv2.dilate(green_u8, kernel, iterations=3).astype(bool)
        tissue = (green_u8.astype(bool) | (brown & near_leaf)).astype(np.uint8)
        tissue = cv2.morphologyEx(tissue, cv2.MORPH_CLOSE, kernel, iterations=2)

        # Fill holes so lesions inside the leaf count as leaf area.
        contours, _ = cv2.findContours(tissue, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        min_area = self.min_leaf_fraction * image.shape[0] * image.shape[1]
        contours = sorted((c for c in contours if cv2.contourArea(c) >= min_area), key=cv2.contourArea, reverse=True)

        predictions = []
        for c in contours[: self.max_leaves]:
            mask = np.zeros(image.shape[:2], np.uint8)
            cv2.drawContours(mask, [c], -1, 1, thickness=cv2.FILLED)
            predictions.append({"class_name": "leaf", "confidence": 1.0, "mask": mask.astype(bool)})

        small = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (3, 3))
        for name, raw in (("leaf_spot", brown), ("powdery_mildew", white)):
            mask = cv2.morphologyEx(raw.astype(np.uint8), cv2.MORPH_OPEN, small).astype(bool)
            if mask.any():
                predictions.append({"class_name": name, "confidence": 1.0, "mask": mask})
        return predictions
