"""Settings loaded from environment / .env."""

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", protected_namespaces=())

    model_path: str = "models/leaf_disease_seg.onnx"
    model_version: str = "yolo26x-seg-lds-v2"
    # Class names by model class id, comma-separated. Empty: read from the ONNX metadata (YOLO),
    # or the Roboflow COCO order "<superclass>,leaf,leaf_spot,powdery_mildew" (RF-DETR).
    class_names: str = ""
    # Leave empty for local prototype mode: no token checks, scans saved under local_data_dir.
    firebase_project_id: str = ""
    # Leave empty to store no images on the server: auth and scan results still use Firebase, and the
    # app keeps the images on the device. Cloud Storage needs the paid Blaze plan.
    storage_bucket: str = ""
    # Service-account JSON for local runs (outside the repo). Empty: Application Default Credentials
    # (GOOGLE_APPLICATION_CREDENTIALS, or the service account on Cloud Run).
    google_application_credentials: str = ""
    local_data_dir: str = "local_data"
    cors_origins: str = ""

    # Thresholds, tuned on the validation split for yolo26x-seg-lds-v2 (training/09_tune_inference.ipynb).
    # Re-tune them for every new model.
    leaf_confidence: float = 0.2
    disease_confidence: float = 0.3
    # Per-disease thresholds; unset = disease_confidence.
    leaf_spot_confidence: float | None = 0.25
    powdery_mildew_confidence: float | None = 0.3
    max_image_side: int = 1280
    max_upload_mb: float = 15.0
    # Multi-leaf photos reach 100+ instances (every leaf and every lesion), so keep this well above that.
    max_detections: int = 300

    # Severity bands (% of leaf area)
    severity_mild_max: float = 5.0
    severity_moderate_max: float = 25.0

    # AI management tips (POST /scans/{id}/advice). Any OpenAI-compatible chat API: Ollama by default
    # (free, local, open-weight models); Groq / OpenRouter / vLLM / LM Studio work by changing these.
    llm_base_url: str = "http://localhost:11434/v1"
    llm_model: str = "qwen2.5:7b"
    llm_api_key: str = ""
    # Vision model (same server) that looks at the leaf photo first; its observations go to LLM_MODEL with the
    # scan results and weather. Empty: skip the photo. Must accept images (Ollama: qwen2.5vl, gemma3, llava).
    llm_vision_model: str = "qwen2.5vl:7b"
    # Long side of the photo sent to the vision model; smaller is faster.
    llm_vision_image_side: int = 896
    # CPU inference of a 7B model can take a minute or more.
    llm_timeout_s: float = 120.0
    # Open-Meteo: free, no API key.
    weather_api_url: str = "https://api.open-meteo.com/v1/forecast"
    weather_timeout_s: float = 10.0

    @property
    def class_confidence(self) -> dict[str, float]:
        """Minimum confidence per class name."""
        disease = lambda v: self.disease_confidence if v is None else v  # noqa: E731
        return {
            "leaf": self.leaf_confidence,
            "leaf_spot": disease(self.leaf_spot_confidence),
            "powdery_mildew": disease(self.powdery_mildew_confidence),
        }

    @property
    def use_firebase(self) -> bool:
        return bool(self.firebase_project_id)

    @property
    def use_cloud_storage(self) -> bool:
        return self.use_firebase and bool(self.storage_bucket)

    @property
    def cors_origins_list(self) -> list[str]:
        return [o.strip() for o in self.cors_origins.split(",") if o.strip()]

    @property
    def class_names_list(self) -> list[str] | None:
        names = [n.strip() for n in self.class_names.split(",")]
        return names if any(names) else None


settings = Settings()
