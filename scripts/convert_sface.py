#!/usr/bin/env python3
"""
Convert OpenCV SFace (face_recognition_sface_2021dec.onnx) to Core ML for
PhotoSwipe's on-device face embedding.

This is a ONE-TIME step run OUTSIDE Xcode. It produces
`PhotoSwipe/Resources/FaceEmbedding.mlpackage`, which you then add to the
Xcode target (drag it into the Resources group, "Copy items if needed",
target = PhotoSwipe). The app gates all face embedding behind the presence
of this model — until it's bundled, the People scan reports the model as
missing and does nothing.

--------------------------------------------------------------------------
MODEL
--------------------------------------------------------------------------
OpenCV Zoo SFace — the whole model directory (weights included) is Apache-2.0.
    https://github.com/opencv/opencv_zoo/tree/main/models/face_recognition_sface
    file: face_recognition_sface_2021dec.onnx
Architecture: MobileFaceNet trained with the SFace loss.
    input : 1x3x112x112, BGR, float32, pixel range [0, 255] (NO normalization)
    output: 1x128 embedding, compared by cosine distance (L2-normalize first)

The .onnx being Apache-2.0 is why SFace was chosen over MobileFaceNet
checkpoints whose MS1M-trained weights are legally orphaned. Attribution is
required — see THIRD_PARTY_LICENSES.md. (Caveat: SFace's *training set* is
undocumented; fine for personal on-device use, revisit before any commercial
App Store release.)

--------------------------------------------------------------------------
SETUP (Python 3.10 or 3.11 recommended; coremltools is picky about newer)
--------------------------------------------------------------------------
    python3 -m venv .venv && source .venv/bin/activate
    pip install --upgrade pip
    pip install onnx onnx2torch torch coremltools numpy

Download the ONNX weights (Git LFS or direct):
    curl -L -o face_recognition_sface_2021dec.onnx \
      https://github.com/opencv/opencv_zoo/raw/main/models/face_recognition_sface/face_recognition_sface_2021dec.onnx

--------------------------------------------------------------------------
RUN
--------------------------------------------------------------------------
    python scripts/convert_sface.py \
        --onnx face_recognition_sface_2021dec.onnx \
        --out PhotoSwipe/Resources/FaceEmbedding.mlpackage

--------------------------------------------------------------------------
PREPROCESSING CONTRACT (must match the Swift side EXACTLY, or embeddings are
garbage). The Swift pipeline is responsible for producing the input tensor:
  1. Detect the face + 5 landmarks (Vision).
  2. Similarity-transform the crop to the canonical 112x112 ArcFace template
     (right eye, left eye, nose, right mouth, left mouth).
  3. Channel order RGB. (OpenCV feeds SFace via blobFromImage(..., swapRB=true);
     since OpenCV Mats are BGR, the network was trained on RGB.)
  4. Pixel values as-is in [0, 255] float32 (NO mean subtraction / scaling).
  5. Feed as MLMultiArray shaped [1, 3, 112, 112] (NCHW).
  6. L2-normalize the 128-d output before comparing (cosine distance).
This model is exported as a pure tensor->tensor function; all preprocessing
lives in Swift so it stays explicit and testable. Do not bake normalization
in here without updating the Swift side to match.
--------------------------------------------------------------------------
"""

import argparse
import sys


def main() -> int:
    parser = argparse.ArgumentParser(description="Convert SFace ONNX to Core ML.")
    parser.add_argument("--onnx", required=True, help="Path to face_recognition_sface_2021dec.onnx")
    parser.add_argument("--out", default="PhotoSwipe/Resources/FaceEmbedding.mlpackage",
                        help="Output .mlpackage path")
    parser.add_argument("--input-name", default="input", help="Core ML input feature name")
    parser.add_argument("--output-name", default="embedding", help="Core ML output feature name")
    args = parser.parse_args()

    try:
        import numpy as np
        import torch
        import coremltools as ct
        from onnx2torch import convert as onnx_to_torch
    except ImportError as exc:
        print(f"Missing dependency: {exc}\nInstall with:\n"
              "  pip install onnx onnx2torch torch coremltools numpy", file=sys.stderr)
        return 1

    print(f"Loading ONNX and converting to PyTorch: {args.onnx}")
    torch_model = onnx_to_torch(args.onnx).eval()

    # SFace is a plain CNN: NCHW [1,3,112,112]. Trace with a dummy input.
    example = torch.rand(1, 3, 112, 112, dtype=torch.float32)
    with torch.no_grad():
        traced = torch.jit.trace(torch_model, example)
        out = torch_model(example)

    out_shape = tuple(out.shape)
    print(f"Traced OK. Output shape: {out_shape} (expected (1, 128))")
    if out_shape[-1] != 128:
        print("WARNING: output is not 128-d — verify you have the SFace model.", file=sys.stderr)

    print("Converting to Core ML (this can take a minute)...")
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name=args.input_name, shape=(1, 3, 112, 112), dtype=np.float32)],
        outputs=[ct.TensorType(name=args.output_name, dtype=np.float32)],
        minimum_deployment_target=ct.target.iOS17,
        convert_to="mlprogram",
        compute_units=ct.ComputeUnit.ALL,
    )

    mlmodel.short_description = (
        "OpenCV SFace (Apache-2.0), ONNX->CoreML. 112x112 BGR [0,255] -> 128-d embedding. "
        "L2-normalize output; compare by cosine distance."
    )
    mlmodel.author = "OpenCV Zoo (model) / converted for PhotoSwipe"
    mlmodel.license = "Apache-2.0 (see THIRD_PARTY_LICENSES.md)"

    print(f"Saving: {args.out}")
    mlmodel.save(args.out)
    print("Done. Add the .mlpackage to the PhotoSwipe target in Xcode "
          "(Resources group, target membership = PhotoSwipe).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
