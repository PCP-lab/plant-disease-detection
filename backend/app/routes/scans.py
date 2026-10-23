"""Scan endpoints: create (upload + inference), list, get, delete."""

from fastapi import APIRouter, Depends, File, UploadFile

from app.auth import get_current_uid
from app.schemas import ScanResult

router = APIRouter(prefix="/scans", tags=["scans"])


@router.post("", response_model=ScanResult)
async def create_scan(image: UploadFile = File(...), uid: str = Depends(get_current_uid)):
    # TODO: EXIF-orient, cap long side, predict, compute_coverage, render_overlay, save_scan
    raise NotImplementedError


@router.get("", response_model=list[ScanResult])
def list_scans(limit: int = 20, cursor: str | None = None, uid: str = Depends(get_current_uid)):
    raise NotImplementedError


@router.get("/{scan_id}", response_model=ScanResult)
def get_scan(scan_id: str, uid: str = Depends(get_current_uid)):
    raise NotImplementedError


@router.delete("/{scan_id}", status_code=204)
def delete_scan(scan_id: str, uid: str = Depends(get_current_uid)):
    raise NotImplementedError
