import SwiftUI

/// Settings ▸ Acknowledgements: surfaces third-party attribution required by
/// bundled and optional research models. Mirrors THIRD_PARTY_LICENSES.md.
struct AcknowledgementsView: View {
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("AdaFace IR-50")
                        .font(.headline)
                    Text("On-device face embedding model used by the People feature.")
                        .foregroundStyle(.secondary)

                    Link("github.com/mk-minchul/AdaFace",
                         destination: URL(string: "https://github.com/mk-minchul/AdaFace")!)
                        .font(.footnote)

                    Divider()

                    Group {
                        Text("Code license: ").bold() + Text("MIT")
                        Text("Weights license: ").bold() + Text("Non-commercial research use only")
                        Text("Conversion: ").bold() + Text("PyTorch checkpoint → Core ML fp16")
                    }
                    .font(.footnote)
                }
                .padding(.vertical, 6)
            } header: {
                Text("Bundled model")
            } footer: {
                Text("The AdaFace weights are licensed for non-commercial research only, so this app can't be sold or distributed commercially while it includes them. See THIRD_PARTY_LICENSES.md for the full license terms.")
            }

            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("MobileCLIP S2")
                        .font(.headline)
                    Text("Optional natural-language search model; only installed for a local research evaluation.")
                        .foregroundStyle(.secondary)
                    Link("github.com/apple/ml-mobileclip",
                         destination: URL(string: "https://github.com/apple/ml-mobileclip")!)
                        .font(.footnote)
                    Text("MIT source · Apple research-model license for weights and converted Core ML derivatives")
                        .font(.footnote)
                }
                .padding(.vertical, 6)
            } header: {
                Text("Optional research model")
            } footer: {
                Text("The model license excludes product development and commercial use. Converted image/text packages are disclosed derivatives and are never committed to this repository.")
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("DMScrollBar")
                        .font(.headline)
                    Text("Interactive scrollbar used by the library grids.")
                        .foregroundStyle(.secondary)
                    Link("github.com/batanus/DMScrollBar",
                         destination: URL(string: "https://github.com/batanus/DMScrollBar")!)
                        .font(.footnote)
                    Text("MIT License · pinned to 52b6624")
                        .font(.footnote)
                }
                .padding(.vertical, 6)
            } header: {
                Text("Dependency")
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("MIT License")
                        .font(.subheadline).bold()
                    Text(mitLicenseText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            } header: {
                Text("AdaFace code license")
            }
        }
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
    }

    private let mitLicenseText = """
        Copyright (c) 2022 mk-minchul

        Permission is hereby granted, free of charge, to any person obtaining a copy \
        of this software and associated documentation files (the "Software"), to deal \
        in the Software without restriction, including without limitation the rights \
        to use, copy, modify, merge, publish, distribute, sublicense, and/or sell \
        copies of the Software, and to permit persons to whom the Software is \
        furnished to do so, subject to the following conditions:

        The above copyright notice and this permission notice shall be included in \
        all copies or substantial portions of the Software.

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR \
        IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, \
        FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE \
        AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER \
        LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, \
        OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN \
        THE SOFTWARE.
        """
}

#Preview {
    NavigationStack {
        AcknowledgementsView()
    }
}
