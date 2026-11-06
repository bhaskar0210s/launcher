// The apps Launcher looks through: the ones added in Settings. Also finds every installed app, for adding them.

import AppKit

struct AppEntry {
    let path: String
    let name: String
    let haystack: Haystack
}

@MainActor
final class Catalog {
    /// The added apps that exist, by name.
    private(set) var apps: [AppEntry] = []
    /// Everything added, as saved: an app on a disk that isn't connected stays in the list for when it is.
    private var paths: [String] = []
    private var icons: [String: CGImage] = [:]  // by path
    private var installedCache: [AppEntry]?
    private var realPaths: [String: String] = [:]  // path → the path with symbolic links resolved
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The saved list, tidied: anything that isn't a path is skipped (an odd value never empties the list), and one
    /// app saved under two paths (/Applications/Safari.app is a link into the system) counts once.
    func load() {
        var seen = Set<String>()
        paths = []
        for case let path as String in defaults.array(forKey: Defaults.apps) ?? [] where path.hasPrefix("/") {
            let standard = (path as NSString).standardizingPath
            if seen.insert(realPath(standard)).inserted { paths.append(standard) }
        }
        rebuild()
    }

    /// Checks that the added apps are where they were: an app on a disk connected later appears, a deleted one goes.
    /// A file check per app, done each time the window opens.
    func refreshIfChanged() {
        let fileManager = FileManager.default
        let present = Set(paths.filter { fileManager.fileExists(atPath: $0) })
        if present != Set(apps.map(\.path)) { rebuild() }
    }

    private func realPath(_ path: String) -> String {
        if let real = realPaths[path] { return real }
        let real = (path as NSString).resolvingSymlinksInPath
        realPaths[path] = real
        return real
    }

    private func save() {
        defaults.set(paths, forKey: Defaults.apps)
    }

    private func rebuild() {
        let fileManager = FileManager.default
        apps = paths.compactMap { fileManager.fileExists(atPath: $0) ? entry($0) : nil }.sorted(by: Catalog.byName)
    }

    static func byName(_ a: AppEntry, _ b: AppEntry) -> Bool {
        a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    private func entry(_ path: String) -> AppEntry {
        let name = Catalog.displayName(path)
        return AppEntry(path: path, name: name, haystack: prepare(name))
    }

    /// The name Finder shows, in the user's language, without ".app".
    static func displayName(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        var name = (try? url.resourceValues(forKeys: [.localizedNameKey]))?.localizedName ?? url.lastPathComponent
        if name.hasSuffix(".app") { name.removeLast(4) }
        return name
    }

    func contains(_ path: String) -> Bool {
        let real = realPath((path as NSString).standardizingPath)
        return paths.contains { realPath($0) == real }
    }

    func add(_ path: String) {
        guard !contains(path) else { return }
        paths.append((path as NSString).standardizingPath)
        save()
        rebuild()
    }

    func remove(_ path: String) {
        let real = realPath((path as NSString).standardizingPath)
        paths.removeAll { realPath($0) == real }
        save()
        rebuild()
    }

    // MARK: Icons

    /// An app's icon, drawn once at `points` × `scale` into an sRGB bitmap: drawn into the list from that bitmap, it
    /// needs no color conversion.
    func icon(_ path: String, points: CGFloat, scale: CGFloat) -> CGImage? {
        let pixels = Int((points * scale).rounded())
        if let icon = icons[path], icon.width == pixels { return icon }
        guard pixels > 0, let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let image = NSWorkspace.shared.icon(forFile: path)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        context.interpolationQuality = .high
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let made = context.makeImage()
        icons[path] = made
        return made
    }

    /// Draws the icons of the added apps ahead of time, so the first search after launch is as quick as any other.
    func prepareIcons(points: CGFloat, scale: CGFloat) {
        for app in apps { _ = icon(app.path, points: points, scale: scale) }
    }

    /// Keeps only the icons of added apps (Settings may have drawn many more).
    func trimIcons() {
        let keep = Set(apps.map(\.path))
        icons = icons.filter { keep.contains($0.key) }
    }

    // MARK: Installed apps

    /// Every app in the usual places, plus the added ones that live elsewhere, by name. Kept until `forgetInstalled`.
    func installed() -> [AppEntry] {
        if let installedCache { return installedCache }
        let fileManager = FileManager.default
        var seen = Set<String>()
        var found: [AppEntry] = []
        func add(_ path: String) {
            let real = (path as NSString).resolvingSymlinksInPath
            if seen.insert(real).inserted { found.append(entry(path)) }
        }
        func visit(_ directory: String, depth: Int) {
            guard let names = try? fileManager.contentsOfDirectory(atPath: directory) else { return }
            for name in names where !name.hasPrefix(".") {
                let path = directory + "/" + name
                if name.hasSuffix(".app") {
                    add(path)
                } else if depth > 0 {
                    var isDirectory: ObjCBool = false
                    if fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue { visit(path, depth: depth - 1) }
                }
            }
        }
        for root in ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications", "/System/Library/CoreServices/Applications"] {
            visit(root, depth: 1)
        }
        let finder = "/System/Library/CoreServices/Finder.app"
        if fileManager.fileExists(atPath: finder) { add(finder) }
        for app in apps { add(app.path) }
        found.sort(by: Catalog.byName)
        installedCache = found
        return found
    }

    func forgetInstalled() {
        installedCache = nil
    }
}
