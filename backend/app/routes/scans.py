"""Scan endpoints: create (upload + inference), list, get, delete."""

import base64
import io
from types import ModuleType

import numpy as np
from fastapi import APIRouter, Depends, File, HTTPException, Query, Request, Response, UploadFile, status
from PIL import Image, ImageOps, UnidentifiedImageError

from app import advice, local_storage, storage, weather
from app.auth import get_current_uid
from app.config import settings
from app.coverage import compute_coverage, filter_predictions
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


def load_image(data: bytes) -> Image.Image:
    """Decode, apply EXIF orientation, cap the long side at settings.max_image_side."""
    try:
        img = Image.open(io.BytesIO(data))
        img = ImageOps.exif_transpose(img).convert("RGB")
    except (UnidentifiedImageError, OSError) as e:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Not a valid image") from e
    img.thumbnail((settings.max_image_side, settings.max_image_side), Image.Resampling.LANCZOS)
    return img


# Plain `def`: FastAPI runs it in a worker thread, so CPU-bound inference doesn't block the event loop.
@router.post("", response_model=ScanResult)
def create_scan(
    image: UploadFile = File(...),
    uid: str = Depends(get_current_uid),
    model: SegmentationModel = Depends(get_model),
    store: ModuleType = Depends(get_store),
):
    data = image.file.read(int(settings.max_upload_mb * 1024 * 1024) + 1)
    if len(data) > settings.max_upload_mb * 1024 * 1024:
        raise HTTPException(413, f"Image larger than {settings.max_upload_mb:g} MB")

    img = load_image(data)
    pixels = np.asarray(img)
    min_conf = min(settings.class_confidence.values())
    predictions = filter_predictions(model.predict(pixels, min_confidence=min_conf))
    result = compute_coverage(predictions)
    overlay_jpeg = render_overlay(pixels, predictions)

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
