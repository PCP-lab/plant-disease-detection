"""Fine-tune RF-DETR-Seg on the downloaded dataset; checkpoints go to runs/.

Start with the Medium seg model at resolution 640; try Small/Large and higher resolution later.
"""


def main() -> None:
    # TODO: check the seg model class names in the installed rfdetr version (e.g. RFDETRSegMedium)
    # TODO: model.train(dataset_dir=..., epochs=..., batch_size=..., output_dir="runs/...", early_stopping=True)
    raise NotImplementedError


if __name__ == "__main__":
    main()
