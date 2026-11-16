"""Scan endpoints: create (upload + inference), list, get, delete."""

import base64
import io
from types import ModuleType

import numpy as np
from fastapi import APIRouter, Depends, File, Form, HTTPException, Query, Request, Response, UploadFile, status
from PIL import Image, ImageOps, UnidentifiedImageError

from app import advice, local_storage, storage, weather
from app.auth import get_current_uid
from app.config import settings
from app.coverage import compute_coverage, filter_predictions, main_leaf_keep_mask
from app.inference import SegmentationModel
from app.overlay import render_overlay
from app.schemas import Advice, AdviceRequest, ScanResult

router = APIRouter(prefix="/scans", tags=["scans"])


def get_model(request: Request) -> SegmentationModel:
    model = getattr(request.app.state, "model", None)
    if model is None:
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, "Model not loaded")
    return model


def get_store() -> ModuleType:
    """Firebase when configured, else local files (app.local_storage has the same functions)."""
    return storage if settings.use_firebase else local_storage


def parse_crop(crop: str | None) -> tuple[float, float, float, float] | None:
    """'x0,y0,x1,y1' as fractions (0-1) of the upright photo -> tuple, or None. 400 if malformed or too small."""
    if crop is None or not crop.strip():
        return None
    try:
        x0, y0, x1, y1 = (float(v) for v in crop.split(","))
    except ValueError as e:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Invalid crop: expected 'x0,y0,x1,y1'") from e
    m = settings.min_crop_frac
    if not (0 <= x0 < x1 <= 1 and 0 <= y0 < y1 <= 1) or x1 - x0 < m or y1 - y0 < m:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Invalid crop: box outside the photo or too small")
    return x0, y0, x1, y1


def load_image(data: bytes, crop: tuple[float, float, float, float] | None = None) -> Image.Image:
    """Decode, apply EXIF orientation, crop to the box the user drew around the leaf (fractions of the upright photo),
    then cap the long side at settings.max_image_side. Cropping before the cap keeps the most pixels on the leaf."""
    try:
        img = Image.open(io.BytesIO(data))
        img = ImageOps.exif_transpose(img).convert("RGB")
    except (UnidentifiedImageError, OSError) as e:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Not a valid image") from e
    if crop is not None:
        w, h = img.size
        x0, y0, x1, y1 = crop
        img = img.crop((round(x0 * w), round(y0 * h), max(round(x1 * w), round(x0 * w) + 1), max(round(y1 * h), round(y0 * h) + 1)))
    img.thumbnail((settings.max_image_side, settings.max_image_side), Image.Resampling.LANCZOS)
    return img


ISOLATE_GREY = 114  # the letterbox grey the model already sees as "nothing here"


def analyse(model, pixels: np.ndarray) -> tuple[list[dict], dict, np.ndarray]:
    """Run the model → (predictions, coverage result, image to draw the overlay on).

    With settings.isolate_main_leaf, the first pass only finds the main leaf; everything else is greyed out and the
    model runs again, so background leaves (and the lesions on them) never reach the result. The photo check
    ("framing") is still judged on the whole photo from the first pass, since that's what it's about.
    """
    min_conf = min(settings.class_confidence.values())
    predictions = filter_predictions(model.predict(pixels, min_confidence=min_conf))
    result = compute_coverage(predictions)
    keep = main_leaf_keep_mask(predictions, settings.isolate_margin) if settings.isolate_main_leaf else None
    if keep is None:
        return predictions, result, pixels

    isolated = np.where(keep[..., None], pixels, np.uint8(ISOLATE_GREY))
    inside = [
        p for p in filter_predictions(model.predict(isolated, min_confidence=min_conf))
        if p["mask"].any() and (p["mask"] & keep).sum() >= 0.5 * p["mask"].sum()
    ]
    # One leaf: the largest. Slivers of neighbouring leaves in the margin, or pieces split off the main leaf, go.
    leaves = sorted((p for p in inside if p["class_name"] == "leaf"), key=lambda p: -int(p["mask"].sum()))
    second = leaves[:1] + [p for p in inside if p["class_name"] != "leaf"]
    second_result = compute_coverage(second)
    if second_result["status"] != "ok":  # shouldn't happen; keep the single-pass result rather than lose the leaf
        return predictions, result, pixels
    second_result["framing"] = result["framing"]
    dimmed = np.where(keep[..., None], pixels, (pixels * 0.35).astype(np.uint8))  # show what was ignored
    return second, second_result, dimmed


# Plain `def`: FastAPI runs it in a worker thread, so CPU-bound inference doesn't block the event loop.
@router.post("", response_model=ScanResult)
def create_scan(
    image: UploadFile = File(...),
    crop: str | None = Form(None, description="Box around the leaf: 'x0,y0,x1,y1', fractions of the upright photo"),
    uid: str = Depends(get_current_uid),
    model: SegmentationModel = Depends(get_model),
    store: ModuleType = Depends(get_store),
):
    box = parse_crop(crop)  # validate before reading the upload
    data = image.file.read(int(settings.max_upload_mb * 1024 * 1024) + 1)
    if len(data) > settings.max_upload_mb * 1024 * 1024:
        raise HTTPException(413, f"Image larger than {settings.max_upload_mb:g} MB")

    img = load_image(data, box)
    pixels = np.asarray(img)
    predictions, result, shown = analyse(model, pixels)
    overlay_jpeg = render_overlay(shown, predictions)

    # Store the oriented, resized image so it lines up with the overlay.
    jpeg = io.BytesIO()
    img.save(jpeg, format="JPEG", quality=90)
    scan = store.save_scan(uid, jpeg.getvalue(), overlay_jpeg, result, model.version)
    # Both images go back to the app, which keeps them on the device (the only copy without Cloud Storage).
    return {
        **scan,
        "image_jpeg_b64": base64.b64encode(jpeg.getvalue()).decode(),
        "overlay_jpeg_b64": base64.b64encode(overlay_jpeg).decode(),
    }


@router.get("", response_model=list[ScanResult])
def list_scans(
    limit: int = Query(20, ge=1, le=100),
    cursor: str | None = None,
    uid: str = Depends(get_current_uid),
    store: ModuleType = Depends(get_store),
):
    scans = store.list_scans(uid, limit, cursor)
    if scans is None:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Unknown cursor")
    return scans


@router.get("/{scan_id}", response_model=ScanResult)
def get_scan(scan_id: str, uid: str = Depends(get_current_uid), store: ModuleType = Depends(get_store)):
    scan = store.get_scan(uid, scan_id)
    if scan is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Scan not found")
    return scan


# Plain `def`: the weather and LLM calls block, so FastAPI runs this in a worker thread.
@router.post("/{scan_id}/advice", response_model=Advice)
def scan_advice(
    scan_id: str,
    body: AdviceRequest,
    uid: str = Depends(get_current_uid),
    store: ModuleType = Depends(get_store),
):
    """Management tips for a scan. Not stored.

    1. The photo (if sent) → vision model → visible symptoms.
    2. Those observations + the scan's coverage/severity + local weather (if lat/lon sent) → text model → tips.
    """
    scan = store.get_scan(uid, scan_id)
    if scan is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Scan not found")
    if scan.get("status") != "ok" or not scan.get("primary"):
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "No leaf detected in this scan")

    photo, photo_note = None, None
    if body.image_jpeg_b64:
        try:
            data = base64.b64decode(body.image_jpeg_b64, validate=True)
        except ValueError as e:
            raise HTTPException(status.HTTP_400_BAD_REQUEST, "image_jpeg_b64 is not valid base64") from e
        photo, photo_note = advice.describe_photo(load_image(data))
    else:
        photo_note = "No photo was sent, so the tips use the scan results only."

    conditions, outlook = None, None
    if body.lat is not None and body.lon is not None:
        forecast = weather.fetch_weather(body.lat, body.lon)
        if forecast:
            conditions = weather.derive_conditions(forecast)
            outlook = weather.risk_forecast(forecast)

    crop = body.crop.strip() if body.crop and body.crop.strip() else None
    tips = advice.get_advice(scan, conditions, crop, photo, outlook)
    return {
        **tips,
        "spray_timing": advice.spray_timing_text(conditions),
        "weather": conditions,
        "photo_observations": advice.photo_summary(photo) if photo else None,
        "photo_note": photo_note,
        "model": settings.llm_model,
        "vision_model": settings.llm_vision_model if photo else None,
        "disclaimer": advice.DISCLAIMER,
    }


@router.delete("/{scan_id}", status_code=204)
def delete_scan(scan_id: str, uid: str = Depends(get_current_uid), store: ModuleType = Depends(get_store)):
    if not store.delete_scan(uid, scan_id):
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Scan not found")
    return Response(status_code=204)
