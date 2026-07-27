import CryptoKit
import Foundation

func runBundleFreshnessCheck(_ reportRaw: (String, Bool, String) -> Void) {
    func report(_ name: String, _ ok: Bool, _ detail: String = "") { reportRaw(name, ok, detail) }

    print("\n=== renderer bundle is not stale ===")

    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let sourceDir = root.appendingPathComponent("Renderer/src")
    let bundleDir = root.appendingPathComponent("Sources/diffscope-app/Renderer")
    let recordedURL = bundleDir.appendingPathComponent("SOURCE_HASH")

    guard let names = try? FileManager.default.contentsOfDirectory(atPath: sourceDir.path).sorted() else {
        report("renderer sources are present", false, sourceDir.path)
        return
    }
    report("renderer sources are present", !names.isEmpty, names.joined(separator: ", "))

    var hasher = SHA256()
    for name in names {
        guard let data = try? Data(contentsOf: sourceDir.appendingPathComponent(name)) else { continue }
        hasher.update(data: Data(name.utf8))
        hasher.update(data: data)
    }
    let computed = hasher.finalize().map { String(format: "%02x", $0) }.joined()

    guard let recordedRaw = try? String(contentsOf: recordedURL, encoding: .utf8) else {
        report("committed bundle records the hash of its sources", false, "SOURCE_HASH missing")
        return
    }
    let recorded = recordedRaw.trimmingCharacters(in: .whitespacesAndNewlines)

    report("committed bundle matches the current renderer sources",
           recorded == computed,
           "recorded \(recorded.prefix(16))… computed \(computed.prefix(16))… — run `npm run build` in Renderer/")

    let bundle = bundleDir.appendingPathComponent("renderer.js")
    report("the built bundle exists alongside it", FileManager.default.fileExists(atPath: bundle.path))
}
