// swift-tools-version:6.2
import PackageDescription

// Plume: the shared macOS code editor base library behind Canoe and
// Runlet. A standalone NSTextView pipeline with incremental tree-sitter
// highlighting, a line-number gutter, find/replace, line operations, and
// injected host integration (theme, syntax profiles, annotations,
// completion, formatting).
//
// Two products: `Plume` is the editor core and stays grammar-free - every
// token color is resolved from the host's `EditorTheme`, and custom
// languages are host-side `SyntaxProfile`s over SwiftTreeSitter.
// `PlumeLanguages` layers preset profiles for the common embedded
// languages (json, xml, javascript, bash, lua) on top, so hosts get
// working highlighting with zero per-language setup.
let package = Package(
    name: "Plume",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "Plume", targets: ["Plume"]),
        .library(name: "PlumeLanguages", targets: ["PlumeLanguages"]),
    ],
    dependencies: [
        .package(url: "https://github.com/tree-sitter/swift-tree-sitter", .exact("0.10.0")),
        .package(url: "https://github.com/tree-sitter/tree-sitter-json", from: "0.24.8"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-javascript", revision: "8d2992c1071befdc0146e9e1d335d9f50f459030"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-xml", from: "0.7.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-bash", from: "0.25.1"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-lua", revision: "591977fe1e8e24cdf9d94d3bfe2593e06b90c973"),
    ],
    targets: [
        .target(
            name: "Plume",
            dependencies: [
                .product(name: "SwiftTreeSitter", package: "swift-tree-sitter"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(
            name: "PlumeLanguages",
            dependencies: [
                "Plume",
                .product(name: "SwiftTreeSitter", package: "swift-tree-sitter"),
                .product(name: "TreeSitterJSON", package: "tree-sitter-json"),
                .product(name: "TreeSitterJavaScript", package: "tree-sitter-javascript"),
                .product(name: "TreeSitterXML", package: "tree-sitter-xml"),
                .product(name: "TreeSitterBash", package: "tree-sitter-bash"),
                .product(name: "TreeSitterLua", package: "tree-sitter-lua"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
