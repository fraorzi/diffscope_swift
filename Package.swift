// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DiffScope",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "DiffScopeEngine", targets: ["DiffScopeEngine"]),
        .library(name: "DiffScopeGit", targets: ["DiffScopeGit"]),
        .library(name: "DiffScopeSyntax", targets: ["DiffScopeSyntax"]),
        .library(name: "DiffScopeTerminal", targets: ["DiffScopeTerminal"]),
        .library(name: "DiffScopeShell", targets: ["DiffScopeShell"]),
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
        .target(name: "DiffScopeTerminal"),
        // The keyboard map (DEC-057). AppKit-free on purpose: the application builds its menu bar
        // from it and the check suite links the same file, so the map cannot drift from the menu.
        .target(name: "DiffScopeShell"),
        .executableTarget(
            name: "diffscope-verify",
            dependencies: ["DiffScopeEngine", "DiffScopeGit", "DiffScopeSyntax", "DiffScopeTerminal",
                           "DiffScopeShell"]
        ),
        .executableTarget(
            name: "diffscope-app",
            dependencies: ["DiffScopeEngine", "DiffScopeGit", "DiffScopeSyntax", "DiffScopeTerminal",
                           "DiffScopeShell"],
            resources: [.copy("Renderer")]
        ),
        // Gate T0 of docs/26-terminal-plan.md, kept runnable and pointed at the shipping module —
        // a gate that measures a copy of the code measures the wrong thing.
        .executableTarget(name: "diffscope-t0", dependencies: ["DiffScopeTerminal"]),
    ]
)
