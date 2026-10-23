# Plant Disease Detection

Detects **powdery mildew** and **leaf spot** on a leaf photo and reports what percentage of the leaf each disease covers.

| Part | Folder | Stack |
|---|---|---|
| Model training | [training/](training/) | Roboflow dataset (COCO segmentation) → RF-DETR-Seg → ONNX |
| API | [backend/](backend/) | FastAPI + onnxruntime + firebase-admin, deployed on Cloud Run |
| App | [app/](app/) | Flutter (Android, iOS, web) + Firebase Auth / Firestore / Storage |
| Firebase config | [firebase/](firebase/) | Firestore + Storage security rules |

Classes: `leaf`, `leaf_spot`, `powdery_mildew`.
Coverage % = disease pixels inside the leaf ÷ leaf pixels × 100.

## Quick start
1. **Train**: see [training/README.md](training/README.md). This produces `backend/models/leaf_disease_seg.onnx`.
2. **Firebase**: see [firebase/README.md](firebase/README.md). Create the project, enable Auth/Firestore/Storage and deploy the rules.
3. **Backend**: see [backend/README.md](backend/README.md). Run `uvicorn app.main:app --reload` and open `/docs`.
4. **App**: see [app/README.md](app/README.md). Run `flutterfire configure`, then `flutter run`.
