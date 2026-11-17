"""API response models."""

from datetime import datetime
from typing import Literal

from pydantic import BaseModel, Field

Severity = Literal["none", "mild", "moderate", "severe"]
Pressure = Literal["low", "medium", "high"]


class Framing(BaseModel):
    """Photo check: is this one dominant leaf, the kind of photo the model is validated on?"""

    ok: bool
    issue: Literal["several_leaves", "small_leaf"] | None
    leaf_frac: float  # main leaf's share of the photo
    dominance: float | None  # main leaf area / second-largest leaf area; None if only one leaf


class LeafCoverage(BaseModel):
    powdery_mildew_pct: float
    leaf_spot_pct: float
    healthy_pct: float
    severity: dict[str, Severity]
    # Whole-plant scans only: which uploaded photo (0-based) this leaf came from, and that photo's check.
    index: int | None = None
    framing: Framing | None = None


class PlantSummary(BaseModel):
    """Whole-plant scans: how the leaf results were combined (primary holds the plant-level coverage)."""

    leaves_analysed: int
    leaves_affected: dict[str, int]  # per disease: leaves with any of it
    spread: dict[str, float]  # per disease: leaves_affected / leaves_analysed
    raised: list[str]  # diseases whose plant level went up a step because they're on many leaves
    skipped: list[int] = []  # photo indexes with no leaf found, left out of the result
    cover: int | None = None  # photo index of the most affected leaf (thumbnail, and the photo for the AI tips)


class LeafImages(BaseModel):
    """One leaf of a whole-plant scan: URLs when there's a Storage bucket, base64 JPEGs in the POST response."""

    index: int
    image_url: str | None = None
    overlay_url: str | None = None
    image_jpeg_b64: str | None = None
    overlay_jpeg_b64: str | None = None


class ScanResult(BaseModel):
    id: str
    created_at: datetime
    model_version: str
    # "leaf": one photo (POST /scans). "plant": 3-6 leaves of one plant (POST /scans/plant); primary is the plant
    # level, leaves the individual leaves.
    kind: Literal["leaf", "plant"] = "leaf"
    status: Literal["ok", "no_leaf_detected"]
    primary: LeafCoverage | None
    leaves: list[LeafCoverage]
    framing: Framing | None = None  # None for no leaf, plant scans, and scans saved before the check existed
    plant: PlantSummary | None = None
    leaf_images: list[LeafImages] | None = None  # plant scans only
    # Null when there's no Cloud Storage bucket: the app shows its on-device copies instead.
    image_url: str | None = None
    overlay_url: str | None = None
    # Only in the POST /scans response, for the app to save on the device (base64 JPEGs).
    image_jpeg_b64: str | None = None
    overlay_jpeg_b64: str | None = None


class AdviceRequest(BaseModel):
    # Omitted (e.g. location permission denied): advice without weather.
    lat: float | None = Field(None, ge=-90, le=90)
    lon: float | None = Field(None, ge=-180, le=180)
    crop: str | None = Field(None, max_length=60)
    # The scan's original photo (base64 JPEG). Sent by the app because, without a Storage bucket, the device
    # holds the only copy. Omitted: advice from the results and weather alone. ≤ ~15 MB decoded.
    image_jpeg_b64: str | None = Field(None, max_length=21_000_000)


class WeatherSummary(BaseModel):
    temperature_c: float | None
    humidity_pct: float | None
    wind_kmh: float | None
    rain_expected_24h: bool
    rain_mm_24h: float
    max_wind_kmh_24h: float | None
    # e.g. "Today 06:00–11:00"; null when there's no good window in the next 48 h.
    spray_window: str | None
    leaf_spot_pressure: Pressure
    powdery_mildew_pressure: Pressure


class DayRisk(BaseModel):
    date: str
    label: str  # "Today", "Tomorrow", "Sat"
    weekday: str  # "Fri"
    # 0–100: how favourable that day's weather is for the disease to infect and spread.
    powdery_mildew_risk: int
    powdery_mildew_level: Pressure
    leaf_spot_risk: int
    leaf_spot_level: Pressure
    rain_mm: float
    rain_probability_max: int
    temp_min_c: float | None
    temp_max_c: float | None
    humidity_mean_pct: int | None
    # Has a ≥ 4 h dry, calm daylight window for spraying.
    spray_ok: bool


class DiseaseTrend(BaseModel):
    direction: Literal["rising", "falling", "steady"]
    peak_day: str | None
    peak_risk: int
    high_risk_days: list[str]


class RiskForecast(BaseModel):
    days: list[DayRisk]
    trends: dict[str, DiseaseTrend]  # keyed "powdery_mildew", "leaf_spot"


class Treatment(BaseModel):
    name: str
    type: Literal["cultural", "organic", "conventional"]
    how: str = ""
    frac_group: str | None = None


class Advice(BaseModel):
    summary: str
    urgency: Pressure
    actions: list[str]
    treatments: list[Treatment]
    spray_timing: str
    prevention: list[str]
    weather: WeatherSummary | None
    # What the vision model saw in the photo; null when no photo was sent or it couldn't be analysed.
    photo_observations: str | None = None
    # Why the photo wasn't used, e.g. vision model not installed; null when it was used or none was sent.
    photo_note: str | None = None
    model: str
    vision_model: str | None = None
    disclaimer: str
