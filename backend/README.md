# Backend (FastAPI)

Runs the ONNX segmentation model, computes leaf coverage %, stores scans in Firebase.

## Run locally
```bash
python -m venv .venv && .venv\Scripts\activate
pip install -r requirements.txt
copy .env.example .env     # fill in FIREBASE_PROJECT_ID and STORAGE_BUCKET (e.g. <project>.firebasestorage.app)
# put the model at models/leaf_disease_seg.onnx
# set GOOGLE_APPLICATION_CREDENTIALS to a service-account JSON (local only; never commit it)
uvicorn app.main:app --reload
```
Open http://localhost:8000/docs. Without a model file the API still starts, but `POST /scans` returns 503.

## Model
`app/inference.py` reads either export from `training/04_export.ipynb` and detects which from the graph:
YOLO-seg (`output0` + `output1` mask prototypes) or RF-DETR-Seg (`dets`, `labels`, `masks`).
Class names come from the YOLO ONNX metadata; for RF-DETR they default to the Roboflow COCO order
(`_superclass,leaf,leaf_spot,powdery_mildew`). Set `CLASS_NAMES` if your dataset's category ids differ.
Set `MODEL_VERSION` to match the model you deploy; it's stored with every scan.

Current model: `yolo26x-seg-lds-v2` (`training/runs/yolo26x-seg_data-v2`, trained on Roboflow `lds_v1` v2, input
1024 px). The previous model is kept as `models/leaf_disease_seg_yolo26x-seg-data-v1.onnx`; to roll back, rename it
to `leaf_disease_seg.onnx` and set `MODEL_VERSION=yolo26x-seg-data-v1`, `LEAF_CONFIDENCE=0.5`, `DISEASE_CONFIDENCE=0.4`.

## Endpoints
All endpoints except `/health` require `Authorization: Bearer <Firebase ID token>` (401 otherwise).

| Method | Path | Description |
|---|---|---|
| GET | `/health` | Liveness |
| POST | `/scans` | Upload an image (multipart field `image`, ≤ 15 MB) → coverage result |
| GET | `/scans?limit=20&cursor=<last id>` | The user's scan history (newest first) |
| GET | `/scans/{id}` | One scan |
| DELETE | `/scans/{id}` | Delete a scan and its images (204) |
| POST | `/scans/{id}/advice` | AI management tips, body `{"lat", "lon", "crop"}` (all optional). Not stored |

`POST /scans`: EXIF orientation is applied and the long side capped at `MAX_IMAGE_SIDE` (1280) before
inference; that resized image is what's stored, so it lines up with the overlay. Predictions below their
class threshold are dropped: `LEAF_CONFIDENCE` (0.2) for leaves, `LEAF_SPOT_CONFIDENCE` (0.25) and
`POWDERY_MILDEW_CONFIDENCE` (0.3) for the diseases (each falls back to `DISEASE_CONFIDENCE` when unset). These were
tuned on the validation split for the current model with `training/09_tune_inference.ipynb`; re-tune them for every
new model.

`image_url` / `overlay_url` are Firebase download-token URLs (as returned by the client SDK's
`getDownloadURL`), so no private key is needed to sign URLs on Cloud Run.

## AI management tips
`POST /scans/{id}/advice` asks open-source LLMs for treatment options, spray timing and prevention tips, in
two steps:

1. **Photo:** the app sends the scan's original photo (`image_jpeg_b64`), because without a Storage bucket
   the phone holds the only copy. A vision model (`LLM_VISION_MODEL`, default `qwen2.5vl:7b`) describes the
   visible symptoms, guesses the crop, and flags other problems such as pests. If that step fails, the tips are
   still written, and `photo_note` says why the photo wasn't used.
2. **Tips:** the text model (`LLM_MODEL`) writes the advice from the photo observations, the scan's
   coverage/severity, and the local weather.

The response includes `photo_observations`, so the app can show what the AI saw in the photo.

- **Weather** comes from [Open-Meteo](https://open-meteo.com), which is free and needs no key, using the
  `lat`/`lon` the app sends from GPS. `app/weather.py` turns the 48 h forecast into plain facts so a small model
  doesn't have to reason over the numbers: the next spray window (≥ 4 dry, calm, daylight hours at 10–30 °C),
  rain expected, and leaf-spot / powdery-mildew pressure. Without a location, or if Open-Meteo fails, the advice
  is still given, just without the weather.
- **Grounding:** the model may only recommend products from the curated `DISEASE_GUIDE` in `app/advice.py`.
  Products it returns that aren't on that list are dropped, and FRAC codes come from the list, not the model.
  Review and extend that list for your crops and country.
- **LLM:** any OpenAI-compatible chat API. The default is a local [Ollama](https://ollama.com):
  ```bash
  ollama pull gpt-oss:20b    # tips (LLM_MODEL); qwen2.5:7b is a smaller alternative
  ollama pull qwen2.5vl:7b   # reads the photo (LLM_VISION_MODEL); gemma3 or llava also accept images
  ollama serve               # http://localhost:11434
  ```
  To use another server, set `LLM_BASE_URL`, `LLM_MODEL` and `LLM_API_KEY`. For example, the Groq free tier is
  `https://api.groq.com/openai/v1` with `llama-3.1-8b-instant`. A 7B model on a CPU takes about 20–90 s, so
  `LLM_TIMEOUT_S` is 120 and the app waits up to 150 s.
- Errors: 503 if the LLM can't be reached, 502 if it errors or replies with unusable JSON, and 400 for a scan
  with no leaf.

On Cloud Run, `localhost` isn't your machine. Point `LLM_BASE_URL` at an Ollama host the service can reach (or
at a hosted OpenAI-compatible API) and pass the variables with `--set-env-vars`.

## Tests
```bash
pytest
```
The tests use a fake model and fake storage; no Firebase project or model file is needed.

## Deploy (Cloud Run)
```bash
gcloud run deploy leaf-disease-api --source . --region <region> --allow-unauthenticated \
  --memory 2Gi --set-env-vars FIREBASE_PROJECT_ID=<project>,STORAGE_BUCKET=<bucket>,CORS_ORIGINS=<web app origin>
```
The Cloud Run service account needs Firestore (`roles/datastore.user`) and Storage (`roles/storage.objectAdmin`)
access. No key file goes in the image. The model file must be in `models/` when deploying from source.
