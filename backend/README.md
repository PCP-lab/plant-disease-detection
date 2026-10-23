# Backend (FastAPI)

Runs the ONNX segmentation model, computes leaf coverage %, stores scans in Firebase.

## Run locally
```bash
python -m venv .venv && .venv\Scripts\activate
pip install -r requirements.txt
copy .env.example .env
# put the model at models/leaf_disease_seg.onnx
# set GOOGLE_APPLICATION_CREDENTIALS to a service-account JSON (local only; never commit it)
uvicorn app.main:app --reload
```
Open http://localhost:8000/docs.

## Endpoints
All endpoints except `/health` require `Authorization: Bearer <Firebase ID token>`.

| Method | Path | Description |
|---|---|---|
| GET | `/health` | Liveness |
| POST | `/scans` | Upload an image → coverage result |
| GET | `/scans` | The user's scan history (newest first) |
| GET | `/scans/{id}` | One scan |
| DELETE | `/scans/{id}` | Delete a scan |

## Tests
```bash
pytest
```

## Deploy (Cloud Run)
```bash
gcloud run deploy leaf-disease-api --source . --region <region> --allow-unauthenticated
```
The Cloud Run service account needs Firestore and Storage access. No key file goes in the image.
