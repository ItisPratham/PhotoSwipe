#!/usr/bin/env python3
"""Offline SigLIP 2 -> Core ML conversion.

SigLIP 2 is the distributable alternative to MobileCLIP S2: its checkpoint
page licenses the software under Apache 2.0 and everything else, weights
included, under CC-BY 4.0, so a shipped build must credit SigLIP 2 and state
that the weights were converted. See THIRD_PARTY_LICENSES.md.

Like the MobileCLIP converter, this downloads nothing. Point it at a local
snapshot of a fixed-resolution (non-NaFlex) checkpoint and it fails closed
unless every shape, tokenizer, compilation, and parity check passes.

    python3 scripts/convert_siglip2.py --model-dir ../siglip2-base-patch16-256
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import sys
import tempfile
from datetime import datetime, timezone


# Same 20 strings the MobileCLIP converter uses, so the two tokenizer ports are
# exercised against the same awkward input.
REFERENCE_TEXTS = [
    "beach at sunset", "  surrounding whitespace  ", "Don't stop!", "?! #42",
    "café déjà vu", "café", "family 👨‍👩‍👧‍👦", "東京の夜景", "مرحبا بالعالم",
    "Привет, мир", "नमस्ते दुनिया", "Tom &amp; Jerry &lt;3", "ALL CAPS mixed Case",
    "rock'n'roll isn't over", "email@example.com", "a_b-c+d=e/f\\g", "one\ttwo\nthree",
    "🐶🐱🐦", "123 45.6%", " ".join(["overlength"] * 100),
]
SPACE = "▁"


def digest_tree(path: Path) -> str:
    """One hash over every file in the snapshot, so the fingerprint changes
    whenever any weight does."""
    hasher = hashlib.sha256()
    for file in sorted(p for p in path.rglob("*") if p.is_file()):
        hasher.update(str(file.relative_to(path)).encode())
        with file.open("rb") as handle:
            for block in iter(lambda: handle.read(1024 * 1024), b""):
                hasher.update(block)
    return hasher.hexdigest()


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


def check_spec(model, input_name, input_shape, input_type, output_shape, ct) -> None:
    spec = model.get_spec()
    if len(spec.description.input) != 1 or len(spec.description.output) != 1:
        raise RuntimeError("each converted tower must expose exactly one input and output")
    input_feature, output_feature = spec.description.input[0], spec.description.output[0]
    if input_feature.name != input_name or output_feature.name != "embedding":
        raise RuntimeError("converted tower has unexpected feature names")
    array_type = ct.proto.FeatureTypes_pb2.ArrayFeatureType
    expected_input = array_type.INT32 if input_type == "Int32" else array_type.FLOAT32
    if (tuple(input_feature.type.multiArrayType.shape) != input_shape
            or tuple(output_feature.type.multiArrayType.shape) != output_shape
            or input_feature.type.multiArrayType.dataType != expected_input
            or output_feature.type.multiArrayType.dataType != array_type.FLOAT32):
        raise RuntimeError("converted tower violates the SearchEmbedder contract")


def convert(module, example, input_name, input_type, output_shape, torch, ct, np):
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
    check_spec(model, input_name, tuple(example.shape), input_type, output_shape, ct)
    return model


def validate_package(package: Path, input_name, input_value, reference, output_shape, ct, np) -> None:
    # CPU only: this checks numbers, not speed, and the Mac's ANE compiler
    # refuses some models that compile perfectly well on a phone.
    model = ct.models.MLModel(str(package), compute_units=ct.ComputeUnit.CPU_ONLY)
    output = model.predict({input_name: input_value})["embedding"]
    if tuple(output.shape) != output_shape or not np.isfinite(output).all():
        raise RuntimeError("compiled Core ML tower produced an invalid output")
    if np.linalg.norm(output, axis=-1).min() == 0:
        raise RuntimeError("compiled Core ML tower produced a zero embedding")

    # Search compares embeddings by cosine after L2 normalisation, so that is
    # the property that has to survive Float16 conversion. Elementwise
    # tolerance would fail on near-zero components that no query can notice.
    def unit(vectors):
        return vectors / np.linalg.norm(vectors, axis=-1, keepdims=True)

    cosine = float((unit(output) * unit(reference)).sum(axis=-1).min())
    print(f"    cosine against the traced reference: {cosine:.6f}")
    if cosine < 0.99:
        raise RuntimeError(f"converted tower drifts from the reference: cosine {cosine:.4f}")


def normalize(text: str, add_dummy_prefix: bool) -> str:
    """Mirrors SentencePieceTokenizer.normalized in the app. No Unicode
    normalisation and no whitespace collapsing: the reference applies neither,
    and NFC/NFKC changes decomposed input such as "cafe\u0301"."""
    if add_dummy_prefix:
        text = " " + text
    return text.replace(" ", SPACE)


def bpe_encode(text, ids, scores, byte_fallback, unknown_id):
    """The same greedy BPE the Swift port runs, so a mismatch fails conversion
    rather than shipping a tokenizer that quietly disagrees. Gemma's
    SentencePiece model is BPE: its per-piece scores are merge ranks."""
    symbols = []
    for character in text:
        if character in ids:
            symbols.append(character)
        elif byte_fallback:
            symbols.extend(f"<0x{byte:02X}>" for byte in character.encode("utf-8"))
        else:
            symbols.append(character)
    while len(symbols) > 1:
        best_index, best_score = -1, None
        for index in range(len(symbols) - 1):
            score = scores.get(symbols[index] + symbols[index + 1])
            if score is not None and (best_score is None or score > best_score):
                best_index, best_score = index, score
        if best_index < 0:
            break
        symbols[best_index:best_index + 2] = [symbols[best_index] + symbols[best_index + 1]]
    return [ids.get(symbol, unknown_id) for symbol in symbols]


def special_tokens(tokenizer):
    """Work out whether the reference wraps text in begin/end tokens by
    comparing the two encodings, rather than assuming Gemma's defaults."""
    wrapped = tokenizer.encode("photo", add_special_tokens=True)
    bare = tokenizer.encode("photo", add_special_tokens=False)
    if wrapped == bare:
        return None, None
    if len(wrapped) == len(bare) + 2 and wrapped[1:-1] == bare:
        return wrapped[0], wrapped[-1]
    if len(wrapped) == len(bare) + 1 and wrapped[1:] == bare:
        return wrapped[0], None
    if len(wrapped) == len(bare) + 1 and wrapped[:-1] == bare:
        return None, wrapped[-1]
    raise RuntimeError("could not work out how the reference tokenizer adds special tokens")


def self_test() -> int:
    """Checks the normaliser and the merge loop against a hand-built
    vocabulary — the same cases the Swift port is tested against. Needs no
    model, no torch, and no checkpoint."""
    assert normalize("a  b", False) == f"a{SPACE}{SPACE}b"
    assert normalize("ab", True) == f"{SPACE}ab"
    assert normalize("cafe\u0301", False) == "cafe\u0301", "no Unicode normalisation"

    ids = {"<pad>": 0, "<eos>": 1, "<bos>": 2, "<unk>": 3, "a": 4, "b": 5, "ab": 6}
    scores = {"a": -1.0, "b": -2.0, "ab": -3.0}
    for byte in range(256):
        ids[f"<0x{byte:02X}>"] = 7 + byte
        scores[f"<0x{byte:02X}>"] = 0.0
    assert bpe_encode("ab", ids, scores, True, 3) == [6], "adjacent pair must merge"
    assert bpe_encode("ba", ids, scores, True, 3) == [5, 4], "no merge exists for this order"
    # "é" is absent, so it becomes its two UTF-8 bytes.
    assert bpe_encode("aé", ids, scores, True, 3) == [4, ids["<0xC3>"], ids["<0xA9>"]]
    assert bpe_encode("aé", ids, scores, False, 3) == [4, 3]
    print("self-test passed")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Convert a local SigLIP 2 checkpoint for PhotoSwipe.")
    parser.add_argument("--model-dir", type=Path,
                        help="Local snapshot of a fixed-resolution SigLIP 2 checkpoint (not NaFlex).")
    parser.add_argument("--self-test", action="store_true",
                        help="Check the tokenizer logic against a small built-in vocabulary and exit.")
    parser.add_argument("--image-output", type=Path,
                        default=Path("PhotoSwipe/Resources/SigLIP2Image.mlpackage"))
    parser.add_argument("--text-output", type=Path,
                        default=Path("PhotoSwipe/Resources/SigLIP2Text.mlpackage"))
    parser.add_argument("--vocab-output", type=Path,
                        default=Path("PhotoSwipe/Resources/siglip2-vocab.json"))
    parser.add_argument("--fixtures-dir", type=Path,
                        default=Path("PhotoSwipeTests/Fixtures/SigLIP2"))
    parser.add_argument("--provenance", type=Path, default=Path("docs/siglip2-provenance.json"))
    parser.add_argument("--app-provenance", type=Path,
                        default=Path("PhotoSwipe/Resources/siglip2-provenance.json"))
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    if args.model_dir is None:
        raise RuntimeError("--model-dir is required (or pass --self-test)")

    model_dir = args.model_dir.resolve()
    if not model_dir.is_dir():
        raise RuntimeError(f"model snapshot not found: {model_dir}")
    for output in [args.image_output, args.text_output]:
        if output.exists():
            raise RuntimeError(f"refusing to overwrite model output: {output}")

    try:
        import coremltools as ct
        import numpy as np
        import torch
        from transformers import AutoModel, AutoTokenizer
    except ImportError as error:
        raise RuntimeError("Install torch, numpy, coremltools, transformers, and sentencepiece locally.") from error

    model = AutoModel.from_pretrained(str(model_dir), dtype=torch.float32).eval()
    tokenizer = AutoTokenizer.from_pretrained(str(model_dir))
    # Read the SentencePiece model straight off disk. Transformers 5 dropped
    # the slow tokenizers that used to expose `sp_model`, and the piece scores
    # only exist in this file — the fast tokenizer cannot hand them over.
    sentencepiece_model = model_dir / "tokenizer.model"
    if not sentencepiece_model.is_file():
        raise RuntimeError("tokenizer.model not found; this checkpoint is not SentencePiece-based")
    try:
        import sentencepiece as spm
    except ImportError as error:
        raise RuntimeError("Install sentencepiece to read the tokenizer vocabulary.") from error
    sp = spm.SentencePieceProcessor(model_file=str(sentencepiece_model))

    vision_config = model.config.vision_config
    text_config = model.config.text_config
    image_side = getattr(vision_config, "image_size", None)
    if not image_side:
        raise RuntimeError("this looks like a NaFlex checkpoint; use a fixed-resolution variant")
    context_length = text_config.max_position_embeddings
    dimension = getattr(text_config, "projection_size", None) or text_config.hidden_size
    image_shape = (1, 3, image_side, image_side)
    text_shape = (1, context_length)
    output_shape = (1, dimension)

    def features(output):
        # Transformers 5 hands back the whole model output where 4 returned a
        # tensor; SigLIP's embedding is the attention-pooled head either way.
        if torch.is_tensor(output):
            return output
        pooled = getattr(output, "pooler_output", None)
        if pooled is None:
            raise RuntimeError("the model returned no pooled embedding to convert")
        return pooled

    class ImageTower(torch.nn.Module):
        def __init__(self, wrapped):
            super().__init__()
            self.wrapped = wrapped

        def forward(self, image):
            return features(self.wrapped.get_image_features(pixel_values=image))

    class TextTower(torch.nn.Module):
        def __init__(self, wrapped):
            super().__init__()
            self.wrapped = wrapped

        def forward(self, tokens):
            return features(self.wrapped.get_text_features(input_ids=tokens))

    # Export the vocabulary the Swift tokenizer reads.
    pieces = [sp.id_to_piece(index) for index in range(sp.get_piece_size())]
    scores = [sp.get_score(index) for index in range(sp.get_piece_size())]
    if len(pieces) != model.config.text_config.vocab_size:
        print(f"note: tokenizer has {len(pieces)} pieces, text config declares "
              f"{model.config.text_config.vocab_size}")
    piece_ids = {}
    piece_scores = {}
    for index, piece in enumerate(pieces):
        piece_ids.setdefault(piece, index)
        piece_scores.setdefault(piece, scores[index])
    byte_ids = {}
    for index, piece in enumerate(pieces):
        if len(piece) == 6 and piece.startswith("<0x") and piece.endswith(">"):
            byte_ids.setdefault(int(piece[3:5], 16), index)
    byte_fallback = len(byte_ids) == 256

    begin_id, end_id = special_tokens(tokenizer)

    unknown_id = tokenizer.unk_token_id if tokenizer.unk_token_id is not None else 3
    pad_id = tokenizer.pad_token_id if tokenizer.pad_token_id is not None else 0
    # SentencePiece's add_dummy_prefix is a property of the model, not a
    # constant: Gemma's vocabulary does not use one, so "beach" tokenizes as
    # "beach" and not as the word-initial piece. Detect it rather than assume.
    add_dummy_prefix = sp.encode("hello") == sp.encode(" hello")

    # The exported vocabulary must reproduce the reference ids exactly.
    reference_sequences = []
    for text in REFERENCE_TEXTS:
        expected = tokenizer(text, padding="max_length", max_length=context_length,
                             truncation=True)["input_ids"]
        body = bpe_encode(normalize(text, add_dummy_prefix), piece_ids, piece_scores,
                          byte_fallback, unknown_id)
        ours = ([begin_id] if begin_id is not None else []) + body
        if end_id is not None:
            ours.append(end_id)
        if len(ours) > context_length:
            ours = ours[:context_length]
            if end_id is not None:
                ours[-1] = end_id
        ours += [pad_id] * (context_length - len(ours))
        if ours != list(expected):
            raise RuntimeError(
                f"exported vocabulary does not reproduce the reference tokenization of {text!r}"
            )
        reference_sequences.append({"text": text, "ids": list(expected)})

    torch.manual_seed(6_000)
    image_input = torch.rand(image_shape, dtype=torch.float32) * 2 - 1
    text_input = torch.as_tensor([reference_sequences[0]["ids"]], dtype=torch.int32)
    with torch.no_grad():
        image_reference = ImageTower(model)(image_input).float()
        text_reference = TextTower(model)(text_input).float()
    check_tensor("image tower", image_reference, output_shape, torch)
    check_tensor("text tower", text_reference, output_shape, torch)

    image_model = convert(ImageTower(model), image_input, "image", "Float32", output_shape, torch, ct, np)
    text_model = convert(TextTower(model), text_input, "tokens", "Int32", output_shape, torch, ct, np)
    args.image_output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=args.image_output.parent, prefix="siglip2-") as work:
        work = Path(work)
        image_package, text_package = work / args.image_output.name, work / args.text_output.name
        image_model.save(str(image_package))
        text_model.save(str(text_package))
        validate_package(image_package, "image", image_input.numpy(), image_reference.numpy(), output_shape, ct, np)
        validate_package(text_package, "tokens", text_input.numpy(), text_reference.numpy(), output_shape, ct, np)
        os.replace(image_package, args.image_output)
        os.replace(text_package, args.text_output)

    args.vocab_output.parent.mkdir(parents=True, exist_ok=True)
    args.vocab_output.write_text(json.dumps({
        "pieces": pieces,
        "scores": scores,
        "unknownID": unknown_id,
        "padID": pad_id,
        "beginID": begin_id,
        "endID": end_id,
        "contextLength": context_length,
        "addDummyPrefix": add_dummy_prefix,
        "byteFallback": byte_fallback,
        # Carried inside the vocabulary rather than a separate fixture so the
        # Swift port can be checked against the reference tokenizer from
        # inside the app bundle, on the device that will run it.
        "referenceSequences": reference_sequences,
    }, ensure_ascii=False) + "\n")

    args.fixtures_dir.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(args.fixtures_dir / "image-parity.npz",
                        input=image_input.numpy(), expected=image_reference.numpy())
    np.savez_compressed(args.fixtures_dir / "text-parity.npz",
                        input=text_input.numpy(), expected=text_reference.numpy())
    (args.fixtures_dir / "reference-token-sequences.json").write_text(json.dumps({
        "contextLength": context_length, "sequences": reference_sequences,
    }, ensure_ascii=False, indent=2) + "\n")

    provenance = {
        "model": f"SigLIP 2 ({model_dir.name})",
        "sourceCommit": model_dir.name,
        "checkpointSHA256": digest_tree(model_dir),
        "conversionDate": datetime.now(timezone.utc).isoformat(),
        "minimumDeploymentTarget": "iOS 17.0",
        "internalPrecision": "Float16",
        "embeddingDimension": dimension,
        "imageSide": image_side,
        "contextLength": context_length,
        "imageInput": {"shape": list(image_shape), "dtype": "Float32"},
        "textInput": {"shape": list(text_shape), "dtype": "Int32"},
        "output": {"shape": list(output_shape), "dtype": "Float32"},
        "preprocessing": "RGB, bilinear resize to a square (aspect ratio not preserved), "
                         "pixels / 255 then normalized with mean 0.5 and std 0.5.",
        "tokenizer": "SentencePiece BPE (Gemma vocabulary), exported to siglip2-vocab.json.",
        "derivativeChanges": "split image/text encoders traced to Core ML ML Programs at Float16.",
        "license": "Checkpoints are CC-BY 4.0 per the SigLIP 2 checkpoint page; attribution "
                   "and a statement of changes are required when shipping.",
        "dependencies": {name: package_version(name)
                         for name in ["torch", "numpy", "coremltools", "transformers", "sentencepiece"]},
    }
    for path in [args.provenance, args.app_provenance]:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(provenance, indent=2) + "\n")
    print("SigLIP 2 conversion verified. Remember the CC-BY attribution when you ship.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, AssertionError) as error:
        print(f"conversion failed: {error}", file=sys.stderr)
        raise SystemExit(1)
