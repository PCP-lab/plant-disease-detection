"""API response models."""

from datetime import datetime
from typing import Literal

from pydantic import BaseModel

Severity = Literal["none", "mild", "moderate", "severe"]


class LeafCoverage(BaseModel):
    powdery_mildew_pct: float
    leaf_spot_pct: float
    healthy_pct: float
    severity: dict[str, Severity]


class ScanResult(BaseModel):
    id: str
    created_at: datetime
    model_version: str
    status: Literal["ok", "no_leaf_detected"]
    primary: LeafCoverage | None
    leaves: list[LeafCoverage]
    image_url: str
    overlay_url: str
