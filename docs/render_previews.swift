import SwiftUI
import AppKit
import Darwin

@main
struct Renderer {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        NSApp.applicationIconImage = NSImage(contentsOfFile: "Resources/AppIcon.icns")

        let dir = "/tmp/bc-preview"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        writeSamples(to: dir)
        setenv("BACKUP_CONTROL_HOME", dir, 1)
        setenv("BACKUP_CONTROL_PREVIEW", "1", 1)

        snapshot(ContentView().frame(width: 660, height: 780), size: CGSize(width: 660, height: 780), to: "docs/main-window.png")

        let store = BackupStore()
        store.resticOK = true
        store.rcloneOK = true
        store.remotes = ["onedrive"]
        snapshot(SetupView(store: store).frame(width: 660, height: 600), size: CGSize(width: 660, height: 600), to: "docs/setup.png")
    }

    @MainActor static func snapshot<V: View>(_ view: V, size: CGSize, to path: String) {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        host.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height)
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor(srgbRed: 0.09, green: 0.10, blue: 0.13, alpha: 1).cgColor
        host.layer?.cornerRadius = 12
        host.layer?.masksToBounds = true
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            print("no rep"); return
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { print("no png"); return }
        try? png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path) \(rep.pixelsWide)x\(rep.pixelsHigh)")
    }

    static func writeSamples(to dir: String) {
        let config = """
        {"remote":"onedrive","repoPath":"MacBackup/restic","initialized":true,
         "autoEnabled":true,"hour":3,"minute":0,"monthlyCapGB":25,"bwlimitMB":5,
         "language":"en","useProxy":false,
         "scope":["documents","desktop","pictures","dotfiles"]}
        """
        let state = """
        {"lastRun":"2026-11-10T03:00:12Z","status":"ok","message":"Backup completed","lastBytes":52428800}
        """
        let usage = """
        {"2026-11":3435973837}
        """
        let preview = """
        {"bytes":19000000000,"files":37120,"firstRun":false,"uploadBps":6291456,
         "egressIP":"203.0.113.42","egressCC":"US","egressCity":"Los Angeles",
         "categories":{
           "documents":{"bytes":17626543892,"files":36692},
           "desktop":{"bytes":661252,"files":43},
           "pictures":{"bytes":30528720,"files":66},
           "movies":{"bytes":67800,"files":149},
           "music":{"bytes":427570504,"files":403},
           "downloads":{"bytes":11206053,"files":12},
           "dotfiles":{"bytes":25387103,"files":52},
           "full":{"bytes":32816115495,"files":234839}}}
        """
        for (name, body) in [("config.json", config), ("state.json", state),
                             ("usage.json", usage), ("preview.json", preview)] {
            try? body.write(toFile: dir + "/" + name, atomically: true, encoding: .utf8)
        }
    }
}
