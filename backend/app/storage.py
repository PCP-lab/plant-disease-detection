"""Firebase persistence: images in Cloud Storage, scan docs in Firestore at users/{uid}/scans/{scanId}.

Image URLs are Firebase download-token URLs (the same kind the client SDK's getDownloadURL returns),
so no service-account private key is needed to sign them on Cloud Run. The tokens are stored in the
scan doc; the owner can read them anyway, and deleting the scan deletes the files.

Without STORAGE_BUCKET (Cloud Storage needs the paid Blaze plan) no images are stored at all: the doc
holds only the results, and the app keeps the images it gets back from POST /scans on the device.
"""

import uuid
from datetime import datetime, timezone
from urllib.parse import quote

from firebase_admin import firestore, storage
from google.api_core.exceptions import NotFound
from google.cloud.firestore_v1 import Query

from app.config import settings


def _scans(uid: str):
    return firestore.client().collection("users").document(uid).collection("scans")


def _bucket():
    return storage.bucket(settings.storage_bucket or None)


def _download_url(bucket_name: str, path: str, token: str) -> str:
    return f"https://firebasestorage.googleapis.com/v0/b/{bucket_name}/o/{quote(path, safe='')}?alt=media&token={token}"


def _upload(bucket, path: str, data: bytes, content_type: str) -> str:
    token = str(uuid.uuid4())
    blob = bucket.blob(path)
    blob.metadata = {"firebaseStorageDownloadTokens": token}
    blob.upload_from_string(data, content_type=content_type)
    return token


def _to_response(scan_id: str, doc: dict) -> dict:
    if "image_path" not in doc:  # no Storage bucket: images live on the user's device
        urls = {"image_url": None, "overlay_url": None}
    else:
        bucket_name = _bucket().name
        tokens = doc.get("download_tokens", {})
        urls = {
            "image_url": _download_url(bucket_name, doc["image_path"], tokens.get("image", "")),
            "overlay_url": _download_url(bucket_name, doc["overlay_path"], tokens.get("overlay", "")),
        }
    return {
        "id": scan_id,
        "created_at": doc["created_at"],
        "model_version": doc.get("model_version", ""),
        "status": doc["status"],
        "primary": doc.get("primary"),
        "leaves": doc.get("leaves", []),
        **urls,
    }


def save_scan(uid: str, image_bytes: bytes, overlay_jpeg: bytes, result: dict, model_version: str) -> dict:
    """result: compute_coverage() output. Returns the API response dict."""
    ref = _scans(uid).document()
    doc = {
        "created_at": datetime.now(timezone.utc),
        "model_version": model_version,
        "status": result["status"],
        "primary": result["primary"],
        "leaves": result["leaves"],
    }
    if settings.use_cloud_storage:
        bucket = _bucket()
        image_path = f"scans/{uid}/{ref.id}/original.jpg"
        overlay_path = f"scans/{uid}/{ref.id}/overlay.jpg"
        doc["image_path"] = image_path
        doc["overlay_path"] = overlay_path
        doc["download_tokens"] = {
            "image": _upload(bucket, image_path, image_bytes, "image/jpeg"),
            "overlay": _upload(bucket, overlay_path, overlay_jpeg, "image/jpeg"),
        }
    ref.set(doc)
    return _to_response(ref.id, doc)


def list_scans(uid: str, limit: int, cursor: str | None) -> list[dict] | None:
    """Newest first. cursor = id of the last scan of the previous page; None if that id doesn't exist."""
    col = _scans(uid)
    query = col.order_by("created_at", direction=Query.DESCENDING).limit(limit)
    if cursor:
        last = col.document(cursor).get()
        if not last.exists:
            return None
        query = query.start_after(last)
    return [_to_response(snap.id, snap.to_dict()) for snap in query.stream()]


def get_scan(uid: str, scan_id: str) -> dict | None:
    snap = _scans(uid).document(scan_id).get()
    return _to_response(snap.id, snap.to_dict()) if snap.exists else None


def delete_scan(uid: str, scan_id: str) -> bool:
    """False if the scan doesn't exist."""
    ref = _scans(uid).document(scan_id)
    snap = ref.get()
    if not snap.exists:
        return False
    doc = snap.to_dict()
    if "image_path" in doc:
        bucket = _bucket()
        for path in (doc.get("image_path"), doc.get("overlay_path")):
            if path:
                try:
                    bucket.blob(path).delete()
                except NotFound:
                    pass
    ref.delete()
    return True
