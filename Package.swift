// swift-tools-version: 6.2

// The foundation below the SimKDS iPad app and its future extension targets.
// The membership test for anything added here, canonical across README and
// REVIEW.md: code a KDS surface (app or extension) needs, which cannot import
// the app.
//
// The Swift settings mirror the app target (project.yml): same language mode,
// MainActor default isolation, and the Approachable Concurrency features the app
// compiles with — one concurrency dialect across app and package.
import PackageDescription

let package = Package(
    name: "SimKDSKit",
    defaultLocalization: "en",
    // iOS 17 is the app floor; macOS 14 rides along because nothing here is
    // iOS-specific and it lets `swift build`/`swift test` run on the host —
    // same tradeoff YandexDeliveryExpressAPI makes (CLAUDE.md rule 10 still
    // bans `@available` in sources).
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "SimKDSKit", targets: ["SimKDSKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-generator", from: "1.13.0"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.12.0"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession", from: "1.3.1"),
        // The house wire logging for generated clients (same as GitLabKit and
        // YandexDeliveryExpressAPI).
        .package(url: "https://github.com/laconicman/OSLogLoggingMiddleware", from: "1.1.0"),
        // Renders the DocC catalog, including the direction articles. Deliberately
        // **not** listed in any target's `plugins:` — it is a *command* plugin,
        // invoked as `swift package generate-documentation`. Attaching it to the
        // library target would be wrong, so do not "fix" the unused-dependency
        // warning that way.
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.4.3")
    ],
    targets: [
        .target(
            name: "SimKDSKit",
            dependencies: [
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
                .product(name: "OSLogLoggingMiddleware", package: "OSLogLoggingMiddleware")
            ],
            // `defaultIsolation(MainActor.self)` (the app/YDeliveryKit dialect) is
            // deliberately absent — it actor-isolates the *generated* client's
            // properties and Decodable conformances. `InternalImportsByDefault` is
            // present because the generated `package import` clashes with implicit
            // `internal` imports in hand-written files (SE-0409 ambiguity).
            swiftSettings: [
                .enableUpcomingFeature("InternalImportsByDefault"),
            ],
            // The generator is a *plugin*, never a `dependencies:` entry. It finds
            // `openapi.yaml` and `openapi-generator-config.yaml` by scanning the
            // target's sources, so those two must stay in the target's sources —
            // not excluded, and not declared as resources. SwiftPM may report them
            // as unhandled; that is expected.
            plugins: [.plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator")]
        ),
        .testTarget(
            name: "SimKDSKitTests",
            dependencies: ["SimKDSKit"],
            resources: [.process("Resources")]
        ),
    ]
)
