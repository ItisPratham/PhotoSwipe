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
