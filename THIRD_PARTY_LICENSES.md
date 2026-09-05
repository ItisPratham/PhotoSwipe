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

## MobileCLIP S2 (research evaluation only; not currently bundled)

**Source code:** [Apple ML-MobileCLIP](https://github.com/apple/ml-mobileclip), MIT,
Copyright © 2024 Apple Inc. **Tokenizer resources:** `clip-vocab.json` and
`clip-merges.txt`, copied unchanged from Apple's iOS sample. **Potential model
assets:** `MobileCLIPS2Image.mlpackage` and `MobileCLIPS2Text.mlpackage`, produced
from the Apple `mobileclip_s2.pt` checkpoint by `scripts/convert_mobileclip.py`.

The checkpoint and converted packages are governed by the **Apple Machine
Learning Research Model License Agreement**, reproduced in
`docs/MobileCLIP_LICENSE_MODELS.txt`. The license limits use, modification,
redistribution, and derivatives to research purposes; it expressly excludes
commercial exploitation, product development, and use in a commercial product
or service.

The Core ML packages are model derivatives. If they are ever redistributed,
they must be identified as MobileCLIP S2 conversions, disclose the split
image/text encoders and fp16 internal precision, include the Model License, and
include this attribution:

> Apple Machine Learning Research Model is licensed under the Apple Machine
> Learning Research Model License Agreement.

The converter requires a local Apple checkout and checkpoint, records its
source commit, checkpoint SHA-256, dependency versions, date, and deployment
target in `docs/mobileclip-provenance.json`, and leaves model artifacts ignored.

---

## DMScrollBar

**Source:** [batanus/DMScrollBar](https://github.com/batanus/DMScrollBar), MIT,
Copyright © 2022 Dmitrii Medvedev. PhotoSwipe pins revision
`52b662428629e659c18c7641d76ee4a8d495a1de`.
