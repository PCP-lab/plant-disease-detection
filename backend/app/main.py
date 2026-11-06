"""FastAPI app: CORS for Flutter web, routers, model loaded once at startup.

Without FIREBASE_PROJECT_ID it runs in local prototype mode (no auth, scans in local_data/, served at
/files); without the ONNX model it falls back to a colour-threshold placeholder model.
"""

import logging
from contextlib import asynccontextmanager
from pathlib import Path

import firebase_admin
from firebase_admin import credentials
from fastapi import FastAPI, HTTPException, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse

from app.config import settings
from app.inference import SegmentationModel
from app.placeholder_model import ColorHeuristicModel
from app.routes import forecast, scans

log = logging.getLogger("uvicorn.error")


def init_firebase() -> None:
    """GOOGLE_APPLICATION_CREDENTIALS from .env if set, else Application Default Credentials (the service account on Cloud Run)."""
    if firebase_admin._apps:
        return
    options = {k: v for k, v in {"projectId": settings.firebase_project_id, "storageBucket": settings.storage_bucket}.items() if v}
    cred = credentials.Certificate(settings.google_application_credentials) if settings.google_application_credentials else None
    firebase_admin.initialize_app(cred, options=options)


def load_model() -> SegmentationModel | ColorHeuristicModel:
    if Path(settings.model_path).exists():
        return SegmentationModel(settings.model_path, settings.class_names_list, settings.max_detections, settings.model_version)
    log.warning("No model at %s: using the colour-threshold placeholder model", settings.model_path)
    return ColorHeuristicModel()


@asynccontextmanager
async def lifespan(app: FastAPI):
    if settings.use_firebase:
        init_firebase()
        if not settings.use_cloud_storage:
            log.warning("STORAGE_BUCKET not set: images are returned to the app to keep on the device, not stored")
    else:
        log.warning("FIREBASE_PROJECT_ID not set: local prototype mode (no auth, scans in %s/)", settings.local_data_dir)
    app.state.model = load_model()
    yield


app = FastAPI(title="Leaf Disease API", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origins_list,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(scans.router)
app.include_router(forecast.router)

@app.get("/files/{path:path}", include_in_schema=False)
def local_file(path: str) -> FileResponse:
    """Serves scan images in local prototype mode (image_url/overlay_url point here)."""
    root = Path(settings.local_data_dir).resolve()
    file = (root / path).resolve()
    if settings.use_firebase or not file.is_relative_to(root) or not file.is_file():
        raise HTTPException(status.HTTP_404_NOT_FOUND)
    return FileResponse(file)


@app.get("/health")
def health() -> dict:
    return {
        "status": "ok",
        "mode": "firebase" if settings.use_firebase else "local",
        "model": getattr(app.state, "model", None).__class__.__name__,
        # Settings are read from .env at startup: restart after editing it.
        "llm_model": settings.llm_model,
    }
