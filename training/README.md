# Training

Trains an **RF-DETR-Seg** (Apache 2.0) instance segmentation model on the Roboflow dataset.

Classes: `leaf`, `leaf_spot`, `powdery_mildew`.

## Setup
```bash
python -m venv .venv && .venv\Scripts\activate
pip install -r requirements.txt
copy .env.example .env   # fill in the Roboflow values
```

## Steps
| Script | What it does |
|---|---|
| `download_dataset.py` | Downloads the dataset version from Roboflow in COCO segmentation format → `datasets/` |
| `train.py` | Fine-tunes RF-DETR-Seg → `runs/` |
| `evaluate.py` | Test split: mask mAP per class + coverage-% MAE (target < 5 percentage points) |
| `export.py` | Exports the best checkpoint to ONNX → `../backend/models/leaf_disease_seg.onnx` |
