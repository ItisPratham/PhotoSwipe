#!/usr/bin/env python3
"""
Convert AdaFace IR-50 (adaface_ir50_ms1mv2.ckpt) to Core ML for PhotoSwipe's
on-device face embedding.

This is a ONE-TIME step run OUTSIDE Xcode. It produces
`PhotoSwipe/Resources/FaceEmbedding.mlpackage`, which you then add to the
Xcode target (drag it into the Resources group, "Copy items if needed",
target = PhotoSwipe). The app gates all face embedding behind the presence
of this model — until it's bundled, the People scan reports the model as
missing and does nothing.

--------------------------------------------------------------------------
MODEL
--------------------------------------------------------------------------
AdaFace — quality-adaptive margin, best-in-class on the low-quality/low-light
faces that dominate a real phone library.
    https://github.com/mk-minchul/AdaFace   (code: MIT)
    checkpoint: adaface_ir50_ms1mv2.ckpt     (weights: NON-COMMERCIAL research)
Architecture: IR-50 (IResNet-50 backbone).
    input : 1x3x112x112, BGR, float32, normalized (px-127.5)/128  -> [-1, 1]
    output: 1x512 embedding, already L2-normalized by the backbone; compare by
            cosine distance (equivalently dot product).

The AdaFace *code* is MIT but the pretrained *weights* are for non-commercial
research use only (trained on MS1MV2). That is acceptable here because the app
is NOT being commercialized — bundling this model forecloses selling / App
Store distribution. Attribution is required: see THIRD_PARTY_LICENSES.md. To
ship commercially, swap to OpenCV SFace (Apache-2.0) via convert_sface.py.

--------------------------------------------------------------------------
SETUP (Python 3.10 or 3.11 recommended; coremltools is picky about newer)
--------------------------------------------------------------------------
    python3 -m venv .venv && source .venv/bin/activate
    pip install --upgrade pip
    pip install torch coremltools numpy

AdaFace ships a PyTorch checkpoint, NOT ONNX, so we load its own network
definition. Clone the repo (for `net.py`) next to this project:
    git clone https://github.com/mk-minchul/AdaFace

Download `adaface_ir50_ms1mv2.ckpt` from the AdaFace model zoo (linked in that
repo's README — Google Drive) and place it at the repo root (or pass --ckpt).

--------------------------------------------------------------------------
RUN
--------------------------------------------------------------------------
    python scripts/convert_adaface.py \
        --adaface-repo ../AdaFace \
        --ckpt adaface_ir50_ms1mv2.ckpt \
        --out PhotoSwipe/Resources/FaceEmbedding.mlpackage

--------------------------------------------------------------------------
PREPROCESSING CONTRACT (must match the Swift side EXACTLY, or embeddings are
garbage). The Swift pipeline is responsible for producing the input tensor:
  1. Detect the face + 5 landmarks (Vision).
  2. Similarity-transform the crop to the canonical 112x112 ArcFace template
     (right eye, left eye, nose, right mouth, left mouth) — AdaFace reuses it.
  3. Channel order BGR.
  4. Normalize each pixel: (value - 127.5) / 128   (i.e. (x/255 - 0.5)/0.5).
  5. Feed as MLMultiArray shaped [1, 3, 112, 112] (NCHW), float32.
  6. The 512-d output is already unit-length; L2-normalize again is a harmless
     no-op. Compare by cosine distance.
This model is exported as a pure tensor->tensor function; all preprocessing
lives in Swift so it stays explicit and testable (identical convention to
convert_sface.py). Do not bake normalization in here without updating Swift.
--------------------------------------------------------------------------
"""

import argparse
import os
import sys


def main() -> int:
    parser = argparse.ArgumentParser(description="Convert AdaFace IR-50 checkpoint to Core ML.")
    parser.add_argument("--adaface-repo", required=True,
                        help="Path to a clone of github.com/mk-minchul/AdaFace (for net.py)")
    parser.add_argument("--ckpt", default="adaface_ir50_ms1mv2.ckpt",
                        help="Path to the AdaFace IR-50 checkpoint (.ckpt)")
    parser.add_argument("--out", default="PhotoSwipe/Resources/FaceEmbedding.mlpackage",
                        help="Output .mlpackage path")
    parser.add_argument("--input-name", default="input", help="Core ML input feature name")
    parser.add_argument("--output-name", default="embedding", help="Core ML output feature name")
    args = parser.parse_args()

    if not os.path.isfile(args.ckpt):
        print(f"Checkpoint not found: {args.ckpt}", file=sys.stderr)
        return 1
    net_py = os.path.join(args.adaface_repo, "net.py")
    if not os.path.isfile(net_py):
        print(f"net.py not found in --adaface-repo ({args.adaface_repo}).\n"
              "Clone it: git clone https://github.com/mk-minchul/AdaFace", file=sys.stderr)
        return 1

    try:
        import numpy as np
        import torch
        import coremltools as ct
    except ImportError as exc:
        print(f"Missing dependency: {exc}\nInstall with:\n"
              "  pip install torch coremltools numpy", file=sys.stderr)
        return 1

    # Import AdaFace's own network definition.
    sys.path.insert(0, os.path.abspath(args.adaface_repo))
    try:
        import net  # noqa: E402  (from the AdaFace repo)
    except ImportError as exc:
        print(f"Could not import AdaFace's net.py: {exc}", file=sys.stderr)
        return 1

    print(f"Building IR-50 and loading checkpoint: {args.ckpt}")
    backbone = net.build_model("ir_50")

    # weights_only=False: Lightning .ckpt pickles non-tensor objects (hparams),
    # which the modern torch default (weights_only=True) refuses to load. Safe
    # here — you are loading your own trusted checkpoint.
    ckpt = torch.load(args.ckpt, map_location="cpu", weights_only=False)
    state = ckpt.get("state_dict", ckpt)  # Lightning ckpt -> state_dict; else raw
    # Lightning prefixes backbone weights with "model." — strip it.
    backbone_state = {k[6:]: v for k, v in state.items() if k.startswith("model.")}
    if not backbone_state:  # already a bare backbone state_dict
        backbone_state = state
    missing, unexpected = backbone.load_state_dict(backbone_state, strict=False)
    if missing:
        print(f"WARNING: {len(missing)} missing keys (first few: {missing[:3]})", file=sys.stderr)
    if unexpected:
        print(f"NOTE: {len(unexpected)} unexpected keys ignored (first few: {unexpected[:3]})")
    backbone.eval()

    # AdaFace's backbone returns (feature, norm); we only want the (already
    # L2-normalized) feature. Wrap so the traced graph has a single output.
    class EmbeddingWrapper(torch.nn.Module):
        def __init__(self, model):
            super().__init__()
            self.model = model

        def forward(self, x):
            feature, _ = self.model(x)
            return feature

    wrapper = EmbeddingWrapper(backbone).eval()

    example = torch.rand(1, 3, 112, 112, dtype=torch.float32)
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, example)
        out = wrapper(example)

    out_shape = tuple(out.shape)
    print(f"Traced OK. Output shape: {out_shape} (expected (1, 512))")
    if out_shape[-1] != 512:
        print("WARNING: output is not 512-d — verify you have the IR-50 checkpoint.",
              file=sys.stderr)

    print("Converting to Core ML at fp16 (this can take a minute)...")
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name=args.input_name, shape=(1, 3, 112, 112), dtype=np.float32)],
        outputs=[ct.TensorType(name=args.output_name, dtype=np.float32)],
        minimum_deployment_target=ct.target.iOS17,
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
        compute_units=ct.ComputeUnit.ALL,
    )

    mlmodel.short_description = (
        "AdaFace IR-50 (MIT code / non-commercial weights), PyTorch->CoreML fp16. "
        "112x112 BGR, normalized (px-127.5)/128 -> 512-d embedding (unit length). "
        "Compare by cosine distance."
    )
    mlmodel.author = "mk-minchul/AdaFace (model) / converted for PhotoSwipe"
    mlmodel.license = "MIT code; pretrained weights NON-COMMERCIAL (see THIRD_PARTY_LICENSES.md)"

    print(f"Saving: {args.out}")
    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    mlmodel.save(args.out)
    print("Done. Add the .mlpackage to the PhotoSwipe target in Xcode "
          "(drag into Resources, Copy items if needed, target = PhotoSwipe).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
