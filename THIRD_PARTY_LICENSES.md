# Third-Party Licenses

## AdaFace IR-50

**Source:** https://github.com/mk-minchul/AdaFace  
**Used for:** On-device face embedding (detect → align → embed pipeline) in the People feature.  
**Conversion:** PyTorch checkpoint converted to Core ML at fp16 via `scripts/convert_adaface.py`.  
**Bundled asset:** `PhotoSwipe/Resources/FaceEmbedding.mlpackage`

### Code License (MIT)

The AdaFace source code (`github.com/mk-minchul/AdaFace`) is MIT-licensed:

```
MIT License

Copyright (c) 2022 mk-minchul

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```

### Pretrained Weights — NON-COMMERCIAL Research Use Only

> **The pretrained weights bundled with this app are for non-commercial research
> use only.** They were trained on the MS1MV2 dataset and are distributed by the
> AdaFace authors under a research-only license that **does not permit commercial
> use or App Store distribution**.
>
> Bundling these weights therefore forecloses selling or distributing PhotoSwipe
> commercially. See also the note in `README.md`.
>
> To ship a commercial build, replace the bundled model with a commercially
> licensed alternative (e.g. OpenCV SFace — Apache-2.0 weights — via
> `scripts/convert_sface.py`).

---

## OpenCV SFace (documented commercial swap — not currently bundled)

**Source:** https://github.com/opencv/opencv_zoo (face_recognition_sface_2021dec.onnx)  
**License:** Apache License 2.0 (code and weights — commercially safe)  
**Would replace:** `FaceEmbedding.mlpackage` — swap via `scripts/convert_sface.py`.

---

## MobileCLIP S2 (research evaluation only; not in this repository)

**Source code:** [Apple ML-MobileCLIP](https://github.com/apple/ml-mobileclip), MIT,
Copyright © 2024 Apple Inc. **Tokenizer resources:** `clip-vocab.json` and
`clip-merges.txt`, copied unchanged from Apple's iOS sample. **Potential model
assets:** `MobileCLIPS2Image.mlpackage` and `MobileCLIPS2Text.mlpackage`, produced
from the Apple `mobileclip_s2.pt` checkpoint by `scripts/convert_mobileclip.py`.

The checkpoint and converted packages are governed by the **Apple Machine
Learning Research Model License Agreement**. Read the
[license at the recorded source revision](https://github.com/apple/ml-mobileclip/blob/aecfb5453d022e9deff12f81a150ea8f35194baa/LICENSE_MODELS);
the local copy in `docs/MobileCLIP_LICENSE_MODELS.txt` is not tracked.
The license limits use, modification,
redistribution, and derivatives to research purposes; it expressly excludes
commercial exploitation, product development, and use in a commercial product
or service.

The Core ML packages are model derivatives. If they are ever redistributed,
they must be identified as MobileCLIP S2 conversions, disclose the split
image/text encoders and fp16 internal precision, include the Model License, and
include this attribution:

> Apple Machine Learning Research Model is licensed under the Apple Machine
> Learning Research Model License Agreement.

MobileCLIP checkpoints and converted model packages are not tracked here;
the tokenizer vocabulary and merges are tracked. A build that has been given locally
converted packages bundles them, and that build is a research evaluation build
which must not be distributed or sold.

The converter requires a local Apple checkout and checkpoint, records its
source commit, checkpoint SHA-256, dependency versions, date, and deployment
target in `docs/mobileclip-provenance.json`, and leaves model artifacts ignored.

---

## SigLIP 2 (experimental search alternative — not bundled here)

**Source:** Google's SigLIP 2 image–text encoders, released through
[google-research/big_vision](https://github.com/google-research/big_vision).
Checkpoints are published as `.npz` files under
`storage.googleapis.com/big_vision/siglip2/` and mirrored on Hugging Face.
**Replaces:** `MobileCLIPS2Image.mlpackage` and `MobileCLIPS2Text.mlpackage`,
and with them the research-only restriction that keeps a search build
undistributable. Convert a local checkpoint with `scripts/convert_siglip2.py`;
the app picks up `SigLIP2Image.mlpackage`, `SigLIP2Text.mlpackage`,
`siglip2-vocab.json`, and `siglip2-provenance.json` when MobileCLIP is absent.
Nothing SigLIP 2 produces is tracked in this repository.

Runtime, conversion, and optional build-resource integration are complete.
Real-checkpoint conversion and device validation remain deferred, so SigLIP 2
is experimental. License eligibility alone does not establish that this path
has been validated for distribution.

**License (read from the repository on 2026-09-05):** the SigLIP 2 checkpoint
page states, verbatim:

> All software is licensed under the Apache License, Version 2.0 (Apache 2.0);
> you may not use this file except in compliance with the Apache 2.0 license.
> All other materials are licensed under the Creative Commons Attribution 4.0
> International License (CC-BY).

The repository's top-level README says instead that "Unless explicitly noted
otherwise, everything in the big_vision codebase (including models and colabs)
is released under the Apache2 license." The two statements do not agree about
the weights. Treat the checkpoints as **CC-BY 4.0** — the narrower reading —
until Google resolves it. Under the documented CC-BY terms, use requires
attributing the source and stating that
changes were made, and a Core ML conversion is a change. Verify the terms at
the exact revision and checkpoint you download before shipping.

**Attribution when you ship.** CC-BY needs the source credited and the changes
stated. The Acknowledgements screen and this file must name SigLIP 2 and say
the weights were converted to Core ML as split image and text encoders at
Float16 internal precision.

**What the app does differently for it.** SigLIP 2 is a different model family,
not a renamed MobileCLIP, and `SearchModelSpec` holds each difference:

* **Tokenizer.** The Gemma SentencePiece vocabulary, 256k pieces, ported in
  `SentencePieceTokenizer` (Unigram, Viterbi segmentation, byte fallback).
  CLIP's byte-pair encoding and its bundled merges do not apply.
* **Image preprocessing.** The whole frame is resized to the checkpoint's
  square resolution rather than cropped, then normalised with mean 0.5 and
  std 0.5. Fixed-resolution variants run from 224x224 to 512x512; the NaFlex
  variants keep the native aspect ratio and are not supported here.
* **Embedding width.** Read from the converted model and recorded in the
  provenance file, since it varies by checkpoint. Available sizes are ViT-B
  (86M), L (303M), So400m (400M) and g (1B); the small end is what fits on a
  phone.

Switching families changes the stored model fingerprint, so the search columns
clear and rebuild. Vectors from two embedding spaces are never compared.

---

## DMScrollBar

**Source:** [batanus/DMScrollBar](https://github.com/batanus/DMScrollBar), MIT,
Copyright © 2022 Dmitrii Medvedev. PhotoSwipe pins revision
`52b662428629e659c18c7641d76ee4a8d495a1de`.
