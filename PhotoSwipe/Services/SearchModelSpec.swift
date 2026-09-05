import Foundation

/// Which search model this build actually has, and the constants that follow
/// from it.
///
/// Two families are supported. **MobileCLIP S2** is what the repository has
/// been developed against; its weights are research-only. **SigLIP 2** is the
/// alternative for a build that has to be distributable — its checkpoints are
/// CC-BY 4.0, so they can be used commercially with attribution.
///
/// They are not interchangeable at runtime: different tokenizers, different
/// input sizes, different pixel normalisation, and different embedding widths.
/// Everything that differs lives here, resolved once from whichever packages
/// are installed, so the rest of the app keeps reading plain constants. The
/// stored model fingerprint means switching families clears the search columns
/// and reindexes rather than mixing two embedding spaces.
struct SearchModelSpec: Equatable {
    enum Family: String, Equatable {
        case mobileCLIPS2
        case sigLIP2
    }

    let family: Family
    let imageModelName: String
    let textModelName: String
    let provenanceResource: String
    let dimension: Int
    let imageSide: Int
    let contextLength: Int
    /// The tower sees `(value / 255 - pixelMean) / pixelStd`.
    let pixelMean: Float
    let pixelStd: Float
    /// SigLIP's reference processor resizes the whole frame to a square and
    /// accepts the distortion; MobileCLIP's fills the square and crops. Using
    /// the wrong one shifts every embedding slightly.
    let squashesAspectRatio: Bool
    /// Cosine floor for a result, and **not** transferable between families.
    /// CLIP-style contrastive training puts a good match around 0.20-0.35;
    /// SigLIP's sigmoid loss, with its learned scale of ~113 and bias of
    /// ~-17, compresses everything below about 0.15 — a perfect caption
    /// scores ~0.13 and an unrelated one ~-0.03. Sharing one constant means
    /// one of the two models returns nothing at all.
    let cutoff: Float

    var embeddingByteCount: Int { dimension * MemoryLayout<Float16>.size }

    /// MobileCLIP's own preprocessing is `ToTensor()` only — no mean/std step,
    /// which is why this is 0/1 rather than the usual CLIP constants.
    static let mobileCLIPS2 = SearchModelSpec(
        family: .mobileCLIPS2,
        imageModelName: "MobileCLIPS2Image",
        textModelName: "MobileCLIPS2Text",
        provenanceResource: "mobileclip-provenance",
        dimension: 512,
        imageSide: 256,
        contextLength: CLIPTokenizer.contextLength,
        pixelMean: 0,
        pixelStd: 1,
        squashesAspectRatio: false,
        cutoff: 0.15
    )

    /// Defaults for the base fixed-resolution checkpoint. The converter writes
    /// the real numbers into the provenance file, because width and resolution
    /// vary by variant (B/L/So400m, 224 through 512).
    static let sigLIP2 = SearchModelSpec(
        family: .sigLIP2,
        imageModelName: "SigLIP2Image",
        textModelName: "SigLIP2Text",
        provenanceResource: "siglip2-provenance",
        dimension: 768,
        imageSide: 256,
        contextLength: 64,
        pixelMean: 0.5,
        pixelStd: 0.5,
        squashesAspectRatio: true,
        // Starting point from the measured scale, not from use: unrelated text
        // sits near zero or below, a plausible description around 0.06-0.08.
        // Tune on a real library the way 0.15 was tuned for MobileCLIP.
        cutoff: 0.09
    )

    /// Resolved once for the app's own bundle; every constant the rest of the
    /// app reads comes from here.
    static let current = installed(in: .main) ?? .mobileCLIPS2

    /// The installed family, or nil when neither is complete. MobileCLIP wins
    /// when both are present: it is the developed-against default, and a
    /// deliberate switch means removing it.
    static func installed(in bundle: Bundle) -> SearchModelSpec? {
        if mobileCLIPS2.isComplete(in: bundle) { return mobileCLIPS2.resolvingProvenance(in: bundle) }
        if sigLIP2.isComplete(in: bundle) { return sigLIP2.resolvingProvenance(in: bundle) }
        return nil
    }

    func modelURL(for role: Role, in bundle: Bundle) -> URL? {
        let name = role == .image ? imageModelName : textModelName
        return bundle.url(forResource: name, withExtension: "mlmodelc")
            ?? bundle.url(forResource: name, withExtension: "mlpackage")
    }

    enum Role { case image, text }

    var tokenizerResourceName: String {
        family == .mobileCLIPS2 ? "clip-vocab.json" : "siglip2-vocab.json"
    }

    func hasTokenizerResources(in bundle: Bundle) -> Bool {
        switch family {
        case .mobileCLIPS2:
            bundle.url(forResource: "clip-vocab", withExtension: "json") != nil
                && bundle.url(forResource: "clip-merges", withExtension: "txt") != nil
        case .sigLIP2:
            bundle.url(forResource: "siglip2-vocab", withExtension: "json") != nil
        }
    }

    func provenanceURL(in bundle: Bundle) -> URL? {
        bundle.url(forResource: provenanceResource, withExtension: "json")
    }

    private func isComplete(in bundle: Bundle) -> Bool {
        modelURL(for: .image, in: bundle) != nil
            && modelURL(for: .text, in: bundle) != nil
            && hasTokenizerResources(in: bundle)
            && provenanceURL(in: bundle) != nil
    }

    /// SigLIP 2's width and resolution depend on the checkpoint, so the
    /// converter records them next to the packages. Missing or nonsensical
    /// values keep the defaults rather than producing an unusable spec.
    private func resolvingProvenance(in bundle: Bundle) -> SearchModelSpec {
        guard let url = provenanceURL(in: bundle),
              let data = try? Data(contentsOf: url),
              let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return self
        }
        var spec = self
        if let dimension = values["embeddingDimension"] as? Int, dimension > 0, dimension <= 4_096 {
            spec = spec.with(dimension: dimension)
        }
        if let side = values["imageSide"] as? Int, side >= 64, side <= 1_024 {
            spec = spec.with(imageSide: side)
        }
        if let length = values["contextLength"] as? Int, length > 1, length <= 512 {
            spec = spec.with(contextLength: length)
        }
        return spec
    }

    private func with(dimension: Int? = nil, imageSide: Int? = nil, contextLength: Int? = nil) -> SearchModelSpec {
        SearchModelSpec(
            family: family,
            imageModelName: imageModelName,
            textModelName: textModelName,
            provenanceResource: provenanceResource,
            dimension: dimension ?? self.dimension,
            imageSide: imageSide ?? self.imageSide,
            contextLength: contextLength ?? self.contextLength,
            pixelMean: pixelMean,
            pixelStd: pixelStd,
            squashesAspectRatio: squashesAspectRatio,
            cutoff: cutoff
        )
    }
}
