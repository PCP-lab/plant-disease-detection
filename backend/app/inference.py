"""ONNX model loading and inference: image → per-instance masks with class + confidence."""

import numpy as np


class SegmentationModel:
    def __init__(self, model_path: str) -> None:
        # TODO: onnxruntime.InferenceSession(model_path); read input size from the session
        raise NotImplementedError

    def predict(self, image: np.ndarray) -> list[dict]:
        """Return [{"class_name": str, "confidence": float, "mask": np.ndarray[bool] (H, W)}]."""
        # TODO: preprocess (resize/normalize), run, decode boxes + masks back to image size
        raise NotImplementedError
