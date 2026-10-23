"""Evaluate a checkpoint on the test split.

Reports mask mAP per class and coverage-% MAE: predicted % vs % computed from ground-truth masks
(disease pixels inside the leaf / leaf pixels). Target MAE < 5 percentage points per disease.
"""


def main() -> None:
    # TODO: run predictions on the test split, compute mAP (pycocotools) and coverage MAE
    raise NotImplementedError


if __name__ == "__main__":
    main()
