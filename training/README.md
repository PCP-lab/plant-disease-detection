# Training

Trains an instance segmentation model on the Roboflow dataset. Classes: `leaf`, `leaf_spot`, `powdery_mildew`.

## Models
Picked with `MODEL` in `02_train.ipynb`; `03_evaluate` / `04_export` detect the model from the checkpoint file.

| `MODEL` | Model | License |
|---|---|---|
| `"yolo"` (default) | Ultralytics **YOLO26-seg**, size `x` | **AGPL-3.0**: serving it from the backend means releasing the backend source under AGPL, or buying an Ultralytics Enterprise license |
| `"rfdetr"` | Roboflow **RF-DETR-Seg** | Apache 2.0 (Nano–Large) |

Both are scored the same way on the COCO test split, so their numbers in `03_evaluate` are directly comparable.

## Setup
Needs a CUDA GPU for training. Python 3.13; install the CUDA build of PyTorch first so pip doesn't pull the CPU one
(cu128 is required for Blackwell GPUs).
```bash
py -3.13 -m venv training_env --prompt "training env"
training_env\Scripts\activate
pip install torch torchvision --index-url https://download.pytorch.org/whl/cu128
pip install -r requirements.txt ipykernel
python -m ipykernel install --user --name training_env --display-name "training env"
copy .env.example .env   # fill in the Roboflow values
python -m jupyterlab     # or open the notebooks in VS Code and pick the "training env" kernel
```
Use `python -m jupyterlab` rather than `jupyter lab`: app-control policy on lab PCs can block the `.exe` launchers in `Scripts\`.
With Microsoft Store Python, `ipykernel install --user` writes into the Store app's private AppData, where Jupyter can't see it;
write the kernelspec to `%APPDATA%\jupyter\kernels\training_env\kernel.json` instead.

## Notebooks
Run them in order from this folder.

| Notebook | What it does |
|---|---|
| `01_download_dataset.ipynb` | Downloads the dataset from Roboflow twice: COCO segmentation → `datasets/<project>-v<N>-coco/` (evaluation GT, RF-DETR) and YOLO format → `datasets/<project>-v<N>-yolo/`; shows class counts and sample masks |
| `02_train.ipynb` | Trains YOLO26-seg or RF-DETR-Seg → `runs/<run>/` |
| `03_evaluate.ipynb` | Test split: mask mAP per class (instance models) + coverage-% MAE (target < 5 percentage points), per-pixel IoU + image-level coverage for every model, GT vs prediction pictures |
| `04_export.ipynb` | Exports the best checkpoint to ONNX → `../backend/models/leaf_disease_seg.onnx` |
| `05_biotrove_semseg.ipynb` | Experiment: BioTrove-CLIP backbone + per-pixel head → `runs/semseg-<backbone>_data-v<N>/` (auto-resume) |
| `06_backbone_study.ipynb` | Compares every trained run on the test split → `results/` (CSV with bootstrap CIs, paired tests, figures) |

## BioTrove experiment (notebooks 05–06)
Research question: does biodiversity-specific pretraining help lesion segmentation and disease-severity (coverage %) estimation?

- **Model** (`semseg.py`): a ViT backbone + a light DPT-style decoder that gives every pixel one class (background / leaf / leaf_spot / powdery_mildew). Coverage % is pixel counting. `eval_utils.py` wraps YOLO, RF-DETR and this model behind one `predict()` so all of them are scored identically.
- **Backbones** (`BACKBONE` in `05`): `biotrove-b16` (BioTrove-CLIP ViT-B/16, from `BGLab/BioTrove-CLIP` on Hugging Face, MIT), and for the comparison `clip-b16` (the OpenAI CLIP B/16 BioTrove started from: the controlled comparison), `dinov2-b14`, `imagenet-b16`. Only the backbone changes; decoder, data, schedule and seed stay the same. `FREEZE = True` trains only the decoder; `RUN_TAG = "_s1"` etc. for extra seeds.
- **Fair coverage comparison**: a per-pixel model can't split touching leaves, so `03`/`06` also report *image-level* coverage (disease ÷ all leaf pixels), which every model can be scored on.
- **For a paper**: report the bootstrap CIs (the test set is only 76 images), run 3 seeds for the final configuration, describe the labeling protocol (Roboflow auto-label + manual correction) and ideally have a second person relabel ~30 test images for inter-annotator agreement, and check that the same leaf/plant doesn't appear in both train and test. Licenses: BioTrove MIT (authors ask derivatives to stay open source), dataset CC BY 4.0, YOLO26 AGPL-3.0.
