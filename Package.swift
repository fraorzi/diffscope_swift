// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DiffScope",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "DiffScopeEngine", targets: ["DiffScopeEngine"]),
        .library(name: "DiffScopeGit", targets: ["DiffScopeGit"]),
        .library(name: "DiffScopeSyntax", targets: ["DiffScopeSyntax"]),
        .executable(name: "diffscope-verify", targets: ["diffscope-verify"]),
        .executable(name: "diffscope-app", targets: ["diffscope-app"]),
        .executable(name: "diffscope-t0", targets: ["diffscope-t0"]),
    ],
    targets: [
        .target(
            name: "CTreeSitter",
            path: "Sources/CTreeSitter",
            sources: ["src"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("src")]
        ),
        .target(
            name: "CTreeSitterTSX",
            path: "Sources/CTreeSitterTSX",
            sources: ["src"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("src")]
        ),
        .target(name: "DiffScopeEngine"),
        .target(name: "DiffScopeGit"),
        .target(
            name: "DiffScopeSyntax",
            dependencies: ["DiffScopeEngine", "CTreeSitter", "CTreeSitterTSX"]
        ),
        .executableTarget(
            name: "diffscope-verify",
            dependencies: ["DiffScopeEngine", "DiffScopeGit", "DiffScopeSyntax"]
        ),
        .executableTarget(
            name: "diffscope-app",
            dependencies: ["DiffScopeEngine", "DiffScopeGit", "DiffScopeSyntax"],
            resources: [.copy("Renderer")]
        ),
        // Gate T0 of docs/26-terminal-plan.md: throwaway measurement code, deliberately outside
        // diffscope-verify's check suite. T1 replaces it.
        .executableTarget(name: "diffscope-t0"),
    ]
)
