// swift-tools-version: 6.0
import PackageDescription

// RecipeCore is shared by the app and the share extension.
// It must stay app-extension-safe (no UIApplication) and UIKit-free,
// so its unit tests can run with `swift test` on the macOS CI runner (macOS 26+ for
// Foundation Models / SpeechAnalyzer).
let package = Package(
    name: "RecipeCore",
    platforms: [
        .iOS("27.0"),
        .macOS("26.0")
    ],
    products: [
        .library(name: "RecipeCore", targets: ["RecipeCore"])
    ],
    targets: [
        .target(name: "RecipeCore"),
        .testTarget(name: "RecipeCoreTests", dependencies: ["RecipeCore"])
    ]
)
