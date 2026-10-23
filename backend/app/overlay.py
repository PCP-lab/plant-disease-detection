"""Draw colored disease/leaf masks over the photo and encode as PNG."""

import numpy as np

CLASS_COLORS = {
    "leaf": (46, 160, 67),
    "leaf_spot": (180, 95, 6),
    "powdery_mildew": (230, 230, 250),
}


def render_overlay(image: np.ndarray, predictions: list[dict]) -> bytes:
    # TODO: alpha-blend masks, draw outlines, return PNG bytes
    raise NotImplementedError
