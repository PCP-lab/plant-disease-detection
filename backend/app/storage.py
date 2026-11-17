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
    leaf_images = None
    if doc.get("kind") == "plant":
        leaf_images = [
            {
                "index": leaf["index"],
                "image_url": _download_url(_bucket().name, leaf["image_path"], leaf["tokens"]["image"]),
                "overlay_url": _download_url(_bucket().name, leaf["overlay_path"], leaf["tokens"]["overlay"]),
            }
            if "image_path" in leaf
            else {"index": leaf["index"]}
            for leaf in doc.get("leaf_files", [])
        ]
    return {
        "id": scan_id,
        "created_at": doc["created_at"],
        "model_version": doc.get("model_version", ""),
        "kind": doc.get("kind", "leaf"),
        "status": doc["status"],
        "primary": doc.get("primary"),
        "leaves": doc.get("leaves", []),
        "framing": doc.get("framing"),  # absent on scans saved before the photo check
        "plant": doc.get("plant"),
        "leaf_images": leaf_images,
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
        "framing": result.get("framing"),
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


def save_plant_scan(uid: str, images: dict[int, tuple[bytes, bytes]], result: dict, model_version: str) -> dict:
    """Whole-plant scan. images: photo index → (original JPEG, overlay JPEG) for each analysed leaf.
    result: {"primary", "leaves", "plant"} (aggregate_plant + per-leaf results). Returns the API response dict."""
    ref = _scans(uid).document()
    doc = {
        "created_at": datetime.now(timezone.utc),
        "model_version": model_version,
        "kind": "plant",
        "status": "ok",
        "primary": result["primary"],
        "leaves": result["leaves"],
        "framing": None,
        "plant": result["plant"],
        "leaf_files": [{"index": i} for i in images],
    }
    if settings.use_cloud_storage:
        bucket = _bucket()
        for leaf in doc["leaf_files"]:
            i = leaf["index"]
            original, overlay = images[i]
            leaf["image_path"] = f"scans/{uid}/{ref.id}/leaf_{i}_original.jpg"
            leaf["overlay_path"] = f"scans/{uid}/{ref.id}/leaf_{i}_overlay.jpg"
            leaf["tokens"] = {
                "image": _upload(bucket, leaf["image_path"], original, "image/jpeg"),
                "overlay": _upload(bucket, leaf["overlay_path"], overlay, "image/jpeg"),
            }
            if i == result["plant"]["cover"]:  # top-level image = the most affected leaf (older app builds show it)
                doc["image_path"], doc["overlay_path"] = leaf["image_path"], leaf["overlay_path"]
                doc["download_tokens"] = leaf["tokens"]
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
    _delete_files(snap.to_dict())
    ref.delete()
    return True


def _delete_files(doc: dict) -> None:
    """Deletes a scan doc's images from Cloud Storage, if it has any (single leaf, or every leaf of a plant scan)."""
    paths = {doc.get("image_path"), doc.get("overlay_path")}
    for leaf in doc.get("leaf_files", []):
        paths |= {leaf.get("image_path"), leaf.get("overlay_path")}
    paths.discard(None)
    if not paths:
        return
    bucket = _bucket()
    for path in paths:
        try:
            bucket.blob(path).delete()
        except NotFound:
            pass


def delete_all_scans(uid: str) -> int:
    """Deletes every scan of the user (docs and images), e.g. for account deletion. Returns how many."""
    col = _scans(uid)
    deleted = 0
    while True:
        snaps = list(col.limit(400).stream())
        if not snaps:
            return deleted
        batch = firestore.client().batch()
        for snap in snaps:
            _delete_files(snap.to_dict())
            batch.delete(snap.reference)
        batch.commit()
        deleted += len(snaps)
