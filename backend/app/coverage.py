"""Leaf coverage computation.

Per leaf: disease_mask = union(class masks) ∩ leaf_mask; pct = disease_px / leaf_px × 100.
healthy_pct = 100 − |mildew ∪ spot| / leaf_px × 100. Primary leaf = largest leaf.
No leaf detected → status "no_leaf_detected".
"""

DISEASE_CLASSES = ("powdery_mildew", "leaf_spot")


def compute_coverage(predictions: list[dict]) -> dict:
    # TODO: implement as described in the module docstring
    raise NotImplementedError


def severity(pct: float) -> str:
    # TODO: mild / moderate / severe using settings.severity_* bands
    raise NotImplementedError
