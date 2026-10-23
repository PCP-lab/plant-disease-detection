"""FastAPI app: CORS for Flutter web, routers, model loaded once at startup."""

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.config import settings
from app.routes import scans

app = FastAPI(title="Leaf Disease API")

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origins_list,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(scans.router)

# TODO: lifespan handler that loads the ONNX model (app.inference) and initializes firebase_admin


@app.get("/health")
def health() -> dict:
    return {"status": "ok"}
