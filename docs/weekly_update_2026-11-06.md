---
title: Leaf Disease Detection: Weekly Update
date: 2026-11-06
---

<!--
How to use: each "---" starts a new slide. Paste into Marp / Slidev / Gamma / PowerPoint Copilot
("create slides from this outline"), or copy slide by slide. "Notes:" lines are speaker notes.
Numbers come from training/results/*.json|csv (test split = 76 held-out images).
-->

# Leaf Disease Detection
## Weekly update · 6 Nov 2026

- Part 1: Model training: results, experiments, next steps
- Part 2: Mobile app: features, models, data flow
- Part 3: Path to production on a $1,000 budget

---

# Part 1: Model training

---

# Task and data

**Goal:** segment every **leaf**, **leaf spot** lesion and **powdery mildew** patch in a photo, then report the
**% of leaf area diseased** and a **severity band** (mild < 5 %, moderate < 25 %, severe ≥ 25 %)

| Dataset (Roboflow) | Train | Valid | Test |
|---|---|---|---|
| v1 `leaf-dis-seg` (hydrangea) | 1,950 | 154 | 76 |
| **v2 `lds_v1-v2`** (v1 + new powdery-mildew images) | **2,937** | **146** | **76** |

- Train counts include Roboflow augmented copies; valid/test are original photos only
- Test set: 76 images, **1,480 leaves · 3,061 leaf spots · 794 mildew patches**
  (70 images with leaf spot, 23 with mildew)
- New mildew images were labelled faster with a **Label-Assist loop**: a YOLO model fine-tuned on ~70 corrected
  images pre-labels the next batch in Roboflow, and a human corrects them

Notes: The original-photo count in train is roughly a third of 2,937 (3× augmentation); confirm on the Roboflow version page.

---

# Final model: YOLO26x-seg (instance segmentation)

| Setting | Value |
|---|---|
| Architecture | Ultralytics YOLO26-seg, size **x** (70.5 M params) |
| Input size | 1024 px (inference 1280 px) |
| Batch / LR | 8 / 0.0014 |
| Epochs | 85 trained, best at **epoch 74** (early stopping) |
| Training time | **7.1 h** on one RTX PRO 5000 (Blackwell) |
| Checkpoint selection | on **validation**, by coverage error (not only mAP) |
| Thresholds | tuned on validation: leaf 0.20 · spot 0.25 · mildew 0.30 |
| Export | ONNX, 240 MB, served with ONNX Runtime (CPU or GPU) |

Notes: Thresholds were tuned on validation only, and the test set was used once at the end, so there is no tuning leakage.

---

# Results: pixel level (test, 76 images)

How well the masks overlap the hand labels:

| Class | Precision | Recall | F1 | **IoU** [95 % CI] |
|---|---|---|---|---|
| Leaf | 0.92 | 0.96 | 0.93 | **0.88** [0.86 – 0.90] |
| Leaf spot | 0.78 | 0.82 | 0.80 | **0.67** [0.63 – 0.70] |
| Powdery mildew | 0.68 | 0.69 | 0.68 | **0.52** [0.44 – 0.60] |

- Pixel accuracy **91.7 %** · mean IoU (3 foreground classes) **0.69** · mean F1 **0.81**
- Leaves: excellent. Leaf spot: good. **Mildew is the weakest class**: it is faint, diffuse and has no sharp edge

Notes: CIs come from a bootstrap over test images. Mildew has a wide CI because only 23 test images contain it.

---

# Results: image level (what the user sees)

| | Leaf spot | Powdery mildew |
|---|---|---|
| Disease detected correctly (presence F1) | **0.97** (68 ✓, 2 false alarms, 2 missed) | **1.00** (23/23, 0 false alarms) |
| Coverage error (MAE, % of leaf) | **0.35 pp** (0.37 on infected) | **0.36 pp** (1.18 on infected) |
| Agreement with labels (CCC) | 0.95 | 0.96 |
| Correct severity band | **93 %** | **99 %** |

- Target was coverage error **< 5 percentage points**: met by a wide margin for both diseases
- Threshold tuning cut leaf-spot error from **0.48 → 0.34 pp** and raised spot IoU by **+0.034** (both significant)

Notes: The app's main output is coverage % and severity, and this table is the metric that matters most to users.

---

# Results: instance level (each leaf / lesion as an object)

Mask mAP, YOLO standard metric (IoU-matched objects):

| Class | Val mAP50 | **Test mAP50** | Test mAP50-95 | Test P / R |
|---|---|---|---|---|
| Leaf | 0.69 | **0.66** | 0.53 | 0.79 / 0.63 |
| Leaf spot | 0.64 | **0.64** | 0.30 | 0.74 / 0.57 |
| Powdery mildew | 0.54 | **0.47** | 0.20 | 0.62 / 0.48 |
| **All** | **0.62** | **0.59** | **0.34** | 0.71 / 0.56 |

- **Validation ≈ test** (0.62 vs 0.59): the model generalises and is not overfitting
- Low mAP50-95 for lesions: small, irregular shapes, so the exact edge is hard (and labels vary)
- Instance recall is lower than pixel recall: touching lesions get merged into one object, which doesn't hurt coverage %

---

# Progress: v1 → v2 (same 76 test images)

| Mask mAP50 | v1 model | **v2 model** | Change |
|---|---|---|---|
| Leaf | 0.62 | 0.66 | +0.04 |
| Leaf spot | 0.58 | 0.64 | +0.06 |
| **Powdery mildew** | 0.31 | **0.47** | **+0.16** |
| All | 0.50 | 0.59 | +0.09 |

- Mildew **recall doubled** (0.22 → 0.48) after adding the powdery-mildew images
- Lesson: **more labelled data for the weak class** was the single biggest gain

---

# Experiment: BioTrove-CLIP + segmentation head

**Question:** does a biodiversity-pretrained backbone segment disease better?

- **BioTrove-CLIP ViT-B/16** (trained on ~40 M biodiversity images) + light DPT-style **per-pixel** decoder
- Controlled study: same data (v1), schedule, seed; only the backbone changes (vs CLIP, DINOv2, ImageNet)
- Trained 40 epochs; scored with the same code and test set as YOLO

| Test (v1 data) | YOLO26x-seg | BioTrove + head | Winner (p < 0.05) |
|---|---|---|---|
| Mean IoU (leaf + diseases) | **0.67** | 0.60 | **YOLO** (p = 0.011) |
| Mildew IoU | **0.34** | 0.16 | **YOLO** (p = 0.004) |
| Leaf / spot IoU | 0.92 / 0.74 | 0.93 / 0.73 | tie |
| Image coverage error, spot | **0.19 pp** | 0.41 pp | **YOLO** (p = 0.001) |
| Image coverage error, mildew | **1.40 pp** | 2.00 pp | **YOLO** (p = 0.034) |
| Speed / size | 92 ms · 70.5 M | **38 ms** · 93.8 M | BioTrove faster |

---

# Why YOLO over BioTrove

1. **More accurate where it matters:** significantly better mildew and image-level coverage
2. **Instances, not just pixels:** separates touching leaves, so we get **per-leaf severity** and lesion counts.
   A per-pixel model can't tell two touching leaves apart
3. **Rare, faint class:** BioTrove's pretraining did not help mildew (IoU halved)
4. **Ecosystem:** one-line ONNX export, Roboflow Label-Assist, mature augmentation and tooling
5. BioTrove did win on *per-leaf* coverage in v1. The cause was YOLO learning leaf masks **with holes** at the
   lesions; we fixed that in post-processing (hole filling), so YOLO keeps that advantage too

Notes: BioTrove remains interesting for research (bootstrap CIs, more seeds). For the product, YOLO is the clear choice.

---

# How to make the masks better

| Problem | Next step |
|---|---|
| Mildew weakest (IoU 0.52) | **More mildew images**, balanced classes; copy-paste augmentation |
| Inconsistent labels (diffuse mildew edges) | **AI-assisted relabel** (built, notebook 12): SAM 2.1 redraws leaf/spot outlines, colour checks flag bad spots; written labelling rules; measure **inter-annotator agreement** (target ≥ 0.85 IoU) |
| Leaf masks with holes | Retrain with `overlap_mask = False` (whole masks), not just post-fix |
| Small lesions / edges | Higher resolution (1280 already helps), **tiled inference**, mask refinement with SAM |
| Domain shift (one crop, lab-like photos) | Field photos: other crops, lighting, phones |
| Stability | 3 seeds, test-time augmentation |
| **AGPL licence** of YOLO | Benchmark **RF-DETR-Seg (Apache 2.0)**: already supported by our pipeline |

---

# Part 2: Mobile app

---

# What the app does

**Flutter** app (Android, iOS, web) + **FastAPI** backend + **Firebase**

1. **Sign in** with Google (Firebase Auth)
2. **Scan:** take or pick a leaf photo, then get the disease overlay, coverage chart, per-leaf breakdown and severity
3. **History:** all past scans, newest first, with their images; open one or delete it
4. **Management tips & disease risk** (new this week):
   - **7-day disease-risk forecast** with a chart and day table
   - **AI management tips:** treatments, spray timing, prevention

---

# Scan: how inference works

```
Phone ──photo──► FastAPI backend ──► ONNX Runtime (YOLO26x-seg)
                  │ fix EXIF rotation, resize ≤ 1280 px
                  │ masks per class above tuned thresholds
                  │ coverage per leaf (hole-filled leaf + nearby lesions)
                  │ severity band, coloured overlay
                  ◄── results + original & overlay images (JPEG)
```

- Model loaded **once at startup**; GPU if present, otherwise CPU
- Response time about 0.2 s on GPU; on CPU it's a few seconds
- Firebase ID token checked on every request

---

# Where data lives

| What | Where | Why |
|---|---|---|
| Account | Firebase Auth | Free, secure Google sign-in |
| Scan results (coverage, severity, date, model version) | **Firestore** `users/{uid}/scans/{id}` | History syncs across devices; security rules: owner only |
| Photo + overlay | **On the phone** (Hive store; IndexedDB on web), keyed `scanId/original`, `scanId/overlay` | No Cloud Storage cost (needs paid plan); private |
| (Optional) photos in cloud | Cloud Storage bucket, switched on with one setting | For production / multi-device |

- History screen streams **live** from Firestore, and images are loaded from the phone
- Delete removes the Firestore record and the phone copies
- Trade-off: uninstalling the app or switching phone loses the photos (results stay)

---

# Disease-risk forecast (no AI, instant)

- Weather from **Open-Meteo** (free, no key): hourly forecast for 7 days at the phone's GPS location
- Daily risk score 0–100 per disease, from agronomy rules:
  - **Leaf spot:** hours of **wet leaves** (rain or humidity ≥ 90 %)
  - **Powdery mildew:** **warm (15–28 °C), humid (50–90 %), dry** hours
  - **Spray day:** ≥ 4 dry, calm (< 15 km/h), daylight hours
- Shown as: **trend** (rising / falling, peak day), **line chart**, and a **day table**
  (Low/Med/High · rain · temperature · ✓ spray day)
- Colour-blind-safe palette; levels always written in words, never colour alone

Notes: The scores are rule-of-thumb risk indices, not a calibrated epidemiological model; thresholds are configurable.

---

# AI management tips: two open-source models

| Step | Model (local, via Ollama) | Input → output |
|---|---|---|
| 1. Look at the photo | **Qwen2.5-VL 7B** (vision) | photo → visible symptoms, crop guess, other issues (pests…) |
| 2. Write the advice | **gpt-oss 20B** (text) | symptoms + coverage/severity + weather + 7-day risk → JSON advice |

- **Grounded:** the model may only recommend products from a **curated list** (e.g. sulfur, potassium
  bicarbonate, copper, myclobutanil…). Anything else is dropped, and **FRAC resistance groups** come from our list,
  not the AI
- Advice includes: urgency, steps, treatments (cultural / organic / conventional), spray timing, prevention
- Fixed disclaimer: follow the label and local regulations
- Speed on our GPU: ~9 s for tips, plus ~30 s for the photo step the first time (model loading)
- Any OpenAI-compatible server works (switch with 3 settings)

---

# Part 3: Path to production

---

# Production architecture (Google Cloud + Firebase)

```
 Funders / users
   │  Android APK (Firebase App Distribution)  ·  Web app link (Firebase Hosting)
   ▼
 Firebase Auth ──► Cloud Run: FastAPI + YOLO ONNX (CPU, scales to zero)
                     ├─► Firestore (scan results)
                     ├─► Cloud Storage (photos, optional)
                     ├─► Open-Meteo (weather, free)
                     └─► Hosted open-model API (gpt-oss-20b + vision model)
```

- **Frontend:** Flutter web on **Firebase Hosting**; Android build via **App Distribution** (invite by email)
- **Backend + YOLO model:** Docker image (model inside) on **Cloud Run**, no servers to manage
- **LLMs:** a GPU running 24/7 costs ≈ $500+/month, too much. Use a **hosted API for the same open models**
  (e.g. Groq / OpenRouter / Together) at a fraction of a cent per tip; keep Ollama for development

---

# Budget: 12-month pilot (≈ $1,000)

| Item | Est. cost | Notes |
|---|---|---|
| Firebase Auth, Firestore, Hosting | **$0–5/mo** | Free tiers cover a pilot |
| Cloud Run (YOLO on CPU) | **$0–20/mo** | Free tier: 180k vCPU-s/mo; scale to zero |
| Cloud Storage for photos | **$1–5/mo** | Needs Blaze (pay-as-you-go) plan |
| Artifact Registry (Docker image) | ~$1/mo | |
| Hosted LLM API | **$5–20/mo** | ~3k tokens per tip, well under 1 ¢ |
| Google Play developer account | $25 once | Or free via App Distribution |
| Apple developer (iOS/TestFlight) | $99/yr | Only if iOS is needed |
| Domain (optional) | ~$12/yr | |
| **Total, year 1** | **≈ $300–500** | Leaves ≈ $500 buffer for demos and growth |

- New Google Cloud accounts get **$300 free credit** (90 days)
- Set **budget alerts** at $25 / $50 / $100 per month
- Prices are approximate list prices; check the GCP calculator

Notes: Keeping one Cloud Run instance always warm would cost about $100/month, so turn it on only for demo days.

---

# Production checklist

**Must do before funders use it**
- Deploy the backend to Cloud Run; secrets in **Secret Manager**; budget alerts
- Turn on **Cloud Storage** for photos (Blaze plan) so history survives phone changes
- **Firebase App Check** + Firestore/Storage rules (only the app can call the API)
- Privacy notice (photos + location), terms, AI disclaimer
- Get the pesticide list **reviewed by an agronomist** for the target country

**Licence decision**
- YOLO26 is **AGPL-3.0**: serving it means open-sourcing the backend, **or** buying an Ultralytics licence,
  **or** switching to **RF-DETR-Seg (Apache 2.0)**

**Nice to have**
- Monitoring (Cloud Logging, error alerts), CI/CD deploy on push, usage analytics, offline mode

---

# Plan: next 4 weeks

| Week | Deliverable |
|---|---|
| 1 | Backend on Cloud Run; LLM switched to a hosted API; budget alerts |
| 2 | Web app on Firebase Hosting + Android APK via App Distribution → **funders can try it** |
| 3 | Photos in Cloud Storage, App Check, privacy notice; more mildew images labelled |
| 4 | Retrain (v3 data, relabelled, `overlap_mask = False`); RF-DETR licence-free comparison; funder demo |

---

# Summary

- **Model:** YOLO26x-seg detects disease reliably (presence F1 0.97 / 1.00) and estimates coverage within
  **~0.4 percentage points**; leaf masks are excellent, and **mildew masks are the main thing to improve**
- **BioTrove** was tested in a controlled study; **YOLO is significantly better** and gives per-leaf results
- **App:** scan → coverage → history, plus a **7-day disease-risk forecast** and **grounded AI tips** from
  open-source models
- **Production:** Firebase + Cloud Run + a hosted open-model API fit in **≈ $300–500/year**, so funders can
  use it within ~2 weeks

**Questions?**
