"""Firebase persistence: images in Cloud Storage, scan docs in Firestore at users/{uid}/scans/{scanId}."""


def save_scan(uid: str, image_bytes: bytes, overlay_png: bytes, result: dict) -> dict:
    # TODO: upload scans/{uid}/{scanId}/original.jpg + overlay.png; write the Firestore doc; return the doc + signed URLs
    raise NotImplementedError


def list_scans(uid: str, limit: int, cursor: str | None) -> list[dict]:
    raise NotImplementedError


def get_scan(uid: str, scan_id: str) -> dict | None:
    raise NotImplementedError


def delete_scan(uid: str, scan_id: str) -> None:
    raise NotImplementedError
