#!/usr/bin/env python3
"""Offline MobileCLIP S2 -> Core ML conversion for research builds only.

The Apple checkpoint and the packages this script produces are research-model
derivatives. This script deliberately does not download either source or
weights. It fails closed unless both local inputs are supplied and every
shape, tokenization, compilation, and numerical-parity check succeeds.

    python3 scripts/convert_mobileclip.py \
      --mobileclip-repo ../ml-mobileclip --checkpoint ../mobileclip_s2.pt
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone


IMAGE_SHAPE = (1, 3, 256, 256)
TEXT_SHAPE = (1, 77)
OUTPUT_SHAPE = (1, 512)
REFERENCE_TEXTS = [
    "beach at sunset", "  surrounding whitespace  ", "Don't stop!", "?! #42",
    "café déjà vu", "cafe\u0301", "family 👨‍👩‍👧‍👦", "東京の夜景", "مرحبا بالعالم",
    "Привет, мир", "नमस्ते दुनिया", "Tom &amp; Jerry &lt;3", "ALL CAPS mixed Case",
    "rock'n'roll isn't over", "email@example.com", "a_b-c+d=e/f\\g", "one\ttwo\nthree",
    "🐶🐱🐦", "123 45.6%", " ".join(["overlength"] * 100),
]


def digest(path: Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as file:
        for block in iter(lambda: file.read(1024 * 1024), b""):
            hasher.update(block)
    return hasher.hexdigest()


def require_file(path: Path, label: str) -> None:
    if not path.is_file():
        raise RuntimeError(f"{label} not found: {path}")


def source_commit(repo: Path) -> str:
    try:
        return subprocess.check_output(
            ["git", "-C", str(repo), "rev-parse", "HEAD"], text=True
        ).strip()
    except (OSError, subprocess.CalledProcessError) as error:
        raise RuntimeError(f"MobileCLIP source must be a Git checkout: {error}") from error


def package_version(name: str) -> str:
    try:
        return importlib.metadata.version(name)
    except importlib.metadata.PackageNotFoundError:
        return "not-installed"


def check_tensor(name, value, expected_shape, torch) -> None:
    if tuple(value.shape) != expected_shape:
        raise RuntimeError(f"{name} has shape {tuple(value.shape)}, expected {expected_shape}")
    if not torch.isfinite(value).all() or torch.linalg.vector_norm(value, dim=-1).min().item() == 0:
        raise RuntimeError(f"{name} contains non-finite or zero embeddings")


def check_spec(model, input_name: str, input_shape, input_type: str, ct) -> None:
    spec = model.get_spec()
    if len(spec.description.input) != 1 or len(spec.description.output) != 1:
        raise RuntimeError("each converted tower must expose exactly one input and output")
    input_feature, output_feature = spec.description.input[0], spec.description.output[0]
    if input_feature.name != input_name or output_feature.name != "embedding":
        raise RuntimeError("converted tower has unexpected feature names")
    input_array = input_feature.type.multiArrayType
    output_array = output_feature.type.multiArrayType
    expected_input_type = (ct.proto.FeatureTypes_pb2.ArrayFeatureType.INT32
                           if input_type == "Int32"
                           else ct.proto.FeatureTypes_pb2.ArrayFeatureType.FLOAT32)
    float32 = ct.proto.FeatureTypes_pb2.ArrayFeatureType.FLOAT32
    if (tuple(input_array.shape) != input_shape or tuple(output_array.shape) != OUTPUT_SHAPE
            or input_array.dataType != expected_input_type or output_array.dataType != float32):
        raise RuntimeError("converted tower shape or tensor type violates the MobileCLIP contract")


def convert(module, example, input_name: str, input_type: str, torch, ct, np):
    traced = torch.jit.trace(module, example, strict=True)
    model = ct.convert(
        traced,
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS17,
        compute_precision=ct.precision.FLOAT16,
        compute_units=ct.ComputeUnit.ALL,
        inputs=[ct.TensorType(name=input_name, shape=tuple(example.shape), dtype=example.numpy().dtype)],
        outputs=[ct.TensorType(name="embedding", dtype=np.float32)],
    )
    check_spec(model, input_name, tuple(example.shape), input_type, ct)
    return model


def validate_package(package: Path, input_name: str, input_value, reference, ct, np) -> None:
    compiled = ct.utils.compile_model(str(package))
    output = ct.models.MLModel(compiled).predict({input_name: input_value})["embedding"]
    if tuple(output.shape) != OUTPUT_SHAPE or not np.isfinite(output).all():
        raise RuntimeError("compiled Core ML tower produced an invalid output")
    if np.linalg.norm(output, axis=-1).min() == 0:
        raise RuntimeError("compiled Core ML tower produced a zero embedding")
    np.testing.assert_allclose(output, reference, rtol=3e-2, atol=3e-2)


def copy_resource(source: Path, target: Path) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists() and digest(source) != digest(target):
        raise RuntimeError(f"tracked tokenizer resource differs from source: {target}")
    if not target.exists():
        shutil.copy2(source, target)


def main() -> int:
    parser = argparse.ArgumentParser(description="Convert local MobileCLIP S2 research artifacts.")
    parser.add_argument("--mobileclip-repo", type=Path, required=True)
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--image-output", type=Path,
                        default=Path("PhotoSwipe/Resources/MobileCLIPS2Image.mlpackage"))
    parser.add_argument("--text-output", type=Path,
                        default=Path("PhotoSwipe/Resources/MobileCLIPS2Text.mlpackage"))
    parser.add_argument("--tokenizer-dir", type=Path,
                        default=Path("PhotoSwipe/Resources/CLIPTokenizer"))
    parser.add_argument("--fixtures-dir", type=Path,
                        default=Path("PhotoSwipeTests/Fixtures/MobileCLIP"))
    parser.add_argument("--provenance", type=Path,
                        default=Path("docs/mobileclip-provenance.json"))
    parser.add_argument("--app-provenance", type=Path,
                        default=Path("PhotoSwipe/Resources/mobileclip-provenance.json"))
    args = parser.parse_args()

    repo, checkpoint = args.mobileclip_repo.resolve(), args.checkpoint.resolve()
    require_file(repo / "mobileclip" / "__init__.py", "MobileCLIP source")
    require_file(repo / "mobileclip" / "configs" / "mobileclip_s2.json", "MobileCLIP S2 configuration")
    require_file(checkpoint, "MobileCLIP S2 checkpoint")
    vocab = repo / "ios_app" / "MobileCLIPExplore" / "Resources" / "clip-vocab.json"
    merges = repo / "ios_app" / "MobileCLIPExplore" / "Resources" / "clip-merges.txt"
    require_file(vocab, "CLIP vocabulary")
    require_file(merges, "CLIP BPE merges")
    for output in [args.image_output, args.text_output]:
        if output.exists():
            raise RuntimeError(f"refusing to overwrite model output: {output}")

    try:
        import coremltools as ct
        import numpy as np
        import torch
    except ImportError as error:
        raise RuntimeError("Install torch, torchvision, numpy, coremltools, open-clip-torch, and timm locally.") from error

    sys.path.insert(0, str(repo))
    try:
        import mobileclip
    except ImportError as error:
        raise RuntimeError(f"could not import the supplied MobileCLIP checkout: {error}") from error

    model, _, _ = mobileclip.create_model_and_transforms(
        "mobileclip_s2", pretrained=str(checkpoint), reparameterize=True, device="cpu"
    )
    model.eval()

    class ImageTower(torch.nn.Module):
        def __init__(self, clip):
            super().__init__()
            self.clip = clip

        def forward(self, image):
            return self.clip.encode_image(image)

    class TextTower(torch.nn.Module):
        def __init__(self, clip):
            super().__init__()
            self.clip = clip

        def forward(self, tokens):
            return self.clip.encode_text(tokens)

    torch.manual_seed(6_000)
    image_input = torch.rand(IMAGE_SHAPE, dtype=torch.float32)
    tokens = torch.as_tensor(mobileclip.get_tokenizer("mobileclip_s2")(REFERENCE_TEXTS), dtype=torch.int32)
    if tuple(tokens.shape) != (len(REFERENCE_TEXTS), TEXT_SHAPE[1]):
        raise RuntimeError("reference tokenizer failed to produce 20 complete 77-token sequences")
    text_input = tokens[:1]
    with torch.no_grad():
        image_reference = ImageTower(model)(image_input).float()
        text_reference = TextTower(model)(text_input).float()
    check_tensor("image tower", image_reference, OUTPUT_SHAPE, torch)
    check_tensor("text tower", text_reference, OUTPUT_SHAPE, torch)

    image_model = convert(ImageTower(model), image_input, "image", "Float32", torch, ct, np)
    text_model = convert(TextTower(model), text_input, "tokens", "Int32", torch, ct, np)
    args.image_output.parent.mkdir(parents=True, exist_ok=True)
    args.text_output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=args.image_output.parent, prefix="mobileclip-") as work:
        work = Path(work)
        image_package, text_package = work / args.image_output.name, work / args.text_output.name
        image_model.save(str(image_package))
        text_model.save(str(text_package))
        validate_package(image_package, "image", image_input.numpy(), image_reference.numpy(), ct, np)
        validate_package(text_package, "tokens", text_input.numpy(), text_reference.numpy(), ct, np)
        os.replace(image_package, args.image_output)
        os.replace(text_package, args.text_output)

    copy_resource(vocab, args.tokenizer_dir / vocab.name)
    copy_resource(merges, args.tokenizer_dir / merges.name)
    args.fixtures_dir.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(args.fixtures_dir / "image-parity.npz", input=image_input.numpy(), expected=image_reference.numpy())
    np.savez_compressed(args.fixtures_dir / "text-parity.npz", input=text_input.numpy(), expected=text_reference.numpy())
    (args.fixtures_dir / "token-sequences.json").write_text(json.dumps({
        "contextLength": TEXT_SHAPE[1],
        "sequences": [{"text": text, "ids": ids.tolist()} for text, ids in zip(REFERENCE_TEXTS, tokens)],
    }, ensure_ascii=False, indent=2) + "\n")
    provenance = {
        "model": "MobileCLIP S2", "sourceCommit": source_commit(repo),
        "checkpointSHA256": digest(checkpoint), "conversionDate": datetime.now(timezone.utc).isoformat(),
        "minimumDeploymentTarget": "iOS 17.0", "internalPrecision": "Float16",
        "imageInput": {"shape": IMAGE_SHAPE, "dtype": "Float32"},
        "textInput": {"shape": TEXT_SHAPE, "dtype": "Int32"},
        "output": {"shape": OUTPUT_SHAPE, "dtype": "Float32"},
        "preprocessing": "RGB, bilinear aspect-fill resize, center crop, pixels / 255; no CLIP mean/std normalization.",
        "derivativeChanges": "reparameterized and split image/text encoders; Core ML ML Programs.",
        "dependencies": {name: package_version(name) for name in ["torch", "torchvision", "numpy", "coremltools", "open-clip-torch", "timm"]},
    }
    for provenance_path in [args.provenance, args.app_provenance]:
        provenance_path.parent.mkdir(parents=True, exist_ok=True)
        provenance_path.write_text(json.dumps(provenance, indent=2) + "\n")
    print("MobileCLIP S2 conversion verified. Generated model packages are research-only and ignored by Git.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, AssertionError) as error:
        print(f"conversion failed: {error}", file=sys.stderr)
        raise SystemExit(1)
