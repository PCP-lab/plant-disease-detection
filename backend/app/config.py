"""Settings loaded from environment / .env."""

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", protected_namespaces=())

    model_path: str = "models/leaf_disease_seg.onnx"
    model_version: str = "rfdetr-seg-m-v1"
    firebase_project_id: str = ""
    storage_bucket: str = ""
    cors_origins: str = ""

    # Thresholds
    leaf_confidence: float = 0.5
    disease_confidence: float = 0.4
    max_image_side: int = 1280

    # Severity bands (% of leaf area)
    severity_mild_max: float = 5.0
    severity_moderate_max: float = 25.0

    @property
    def cors_origins_list(self) -> list[str]:
        return [o.strip() for o in self.cors_origins.split(",") if o.strip()]


settings = Settings()
