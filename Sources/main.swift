import SwiftUI
import AppKit
import Combine

// MARK: - Model

struct Config: Codable {
    var autoEnabled: Bool = false
    var hour: Int = 3
    var minute: Int = 0
    var monthlyCapGB: Double = 5
    var bwlimitMB: Int = 2
    var language: String = "en"
    var useProxy: Bool = false
    var scope: [String] = ["documents", "desktop", "pictures", "dotfiles"]
    var remote: String = "onedrive"
    var repoPath: String = "MacBackup/restic"
    var initialized: Bool = false

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        autoEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .autoEnabled)) ?? false
        hour = (try? c.decodeIfPresent(Int.self, forKey: .hour)) ?? 3
        minute = (try? c.decodeIfPresent(Int.self, forKey: .minute)) ?? 0
        monthlyCapGB = (try? c.decodeIfPresent(Double.self, forKey: .monthlyCapGB)) ?? 5
        bwlimitMB = (try? c.decodeIfPresent(Int.self, forKey: .bwlimitMB)) ?? 2
        language = (try? c.decodeIfPresent(String.self, forKey: .language)) ?? "en"
        useProxy = (try? c.decodeIfPresent(Bool.self, forKey: .useProxy)) ?? false
        scope = (try? c.decodeIfPresent([String].self, forKey: .scope)) ?? ["documents", "desktop", "pictures", "dotfiles"]
        remote = (try? c.decodeIfPresent(String.self, forKey: .remote)) ?? "onedrive"
        repoPath = (try? c.decodeIfPresent(String.self, forKey: .repoPath)) ?? "MacBackup/restic"
        initialized = (try? c.decodeIfPresent(Bool.self, forKey: .initialized)) ?? false
    }
}

struct RunState: Codable {
    var lastRun: String?
    var status: String?
    var message: String?
    var lastBytes: Int?
}

struct CatInfo: Decodable {
    let bytes: Int
    let files: Int
}

struct Estimate: Decodable {
    let bytes: Int
    let files: Int
    let firstRun: Bool
    let uploadBps: Double?
    let egressIP: String?
    let egressCC: String?
    let egressCity: String?
    let categories: [String: CatInfo]?
}

// MARK: - Store

final class BackupStore: ObservableObject {
    static let base: URL = {
        if let override = getenv("BACKUP_CONTROL_HOME").map({ String(cString: $0) }) {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/macbackup")
    }()

    @Published var config = Config()
    @Published var state: RunState? = nil
    @Published var usage: [String: Int] = [:]
    @Published var isRunning = false
    @Published var logTail: String = ""
    @Published var categories: [String: CatInfo] = [:]
    @Published var uploadBps: Double = 0
    @Published var scanning = false
    @Published var resticOK = false
    @Published var rcloneOK = false
    @Published var remotes: [String] = []
    @Published var initialized = false
    @Published var egressIP: String?
    @Published var egressRegion: String?
    private var lastIPFetch: Date = .distantPast

    private var task: Process?

    var configURL: URL { Self.base.appendingPathComponent("config.json") }
    var stateURL: URL { Self.base.appendingPathComponent("state.json") }
    var usageURL: URL { Self.base.appendingPathComponent("usage.json") }
    var scriptURL: URL { Self.base.appendingPathComponent("backup.sh") }
    var logURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/macbackup.log") }
    var plistURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/local.macbackup.plist") }

    var monthKey: String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM"; return f.string(from: Date())
    }
    var usedThisMonth: Int { usage[monthKey] ?? 0 }
    var capBytes: Int { Int(config.monthlyCapGB * 1024 * 1024 * 1024) }
    var usageFraction: Double { capBytes > 0 ? min(1, Double(usedThisMonth) / Double(capBytes)) : 0 }

    init() {
        ensureSetup()
        refresh()
        initialized = config.initialized
        checkEnvironment()
    }

    func checkEnvironment() {
        let fm = FileManager.default
        resticOK = fm.isExecutableFile(atPath: "/usr/local/bin/restic")
            || fm.isExecutableFile(atPath: "/opt/homebrew/bin/restic")
        rcloneOK = fm.isExecutableFile(atPath: "/usr/local/bin/rclone")
            || fm.isExecutableFile(atPath: "/opt/homebrew/bin/rclone")
    }

    func loadRemotes() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-lc", "rclone listremotes 2>/dev/null | sed 's/:$//'"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
        p.environment = env
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        p.terminationHandler = { [weak self] _ in
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let list = out.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
            DispatchQueue.main.async { self?.remotes = list }
        }
        try? p.run()
    }

    func initializeRepo(remote: String, path: String, password: String,
                        completion: @escaping (String?) -> Void) {
        let passFile = Self.base.appendingPathComponent("restic.pass")
        try? password.write(to: passFile, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: passFile.path)

        config.remote = remote
        config.repoPath = path
        saveConfig()

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-lc", "restic -r rclone:\(remote):\(path) init 2>&1"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
        env["RESTIC_PASSWORD_FILE"] = passFile.path
        p.environment = env
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        p.terminationHandler = { [weak self] _ in
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let ok = out.contains("created restic repository") || out.contains("already")
            DispatchQueue.main.async {
                if ok {
                    self?.config.initialized = true
                    self?.saveConfig()
                    self?.initialized = true
                    completion(nil)
                } else {
                    completion(out.isEmpty ? "Initialization failed." : out)
                }
            }
        }
        try? p.run()
    }

    /// Create the support directory, deploy bundled scripts, and write defaults.
    private func ensureSetup() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.base, withIntermediateDirectories: true)

        for name in ["backup.sh", "estimate.py"] {
            let dst = Self.base.appendingPathComponent(name)
            guard !fm.fileExists(atPath: dst.path) else { continue }
            guard let src = Bundle.main.resourceURL?.appendingPathComponent("scripts/\(name)") else { continue }
            try? fm.copyItem(at: src, to: dst)
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dst.path)
        }

        if !fm.fileExists(atPath: configURL.path) {
            let defaults = """
            {"autoEnabled":false,"hour":3,"minute":0,"monthlyCapGB":25,"bwlimitMB":2,\
            "language":"en","useProxy":false,"initialized":false,\
            "remote":"onedrive","repoPath":"MacBackup/restic",\
            "scope":["documents","desktop","pictures","dotfiles"]}
            """
            try? defaults.write(to: configURL, atomically: true, encoding: .utf8)
        }
    }

    func refresh() {
        let d = JSONDecoder()
        if let data = try? Data(contentsOf: configURL), let c = try? d.decode(Config.self, from: data) { config = c }
        if let data = try? Data(contentsOf: stateURL), let s = try? d.decode(RunState.self, from: data) { state = s }
        if let data = try? Data(contentsOf: usageURL), let u = try? d.decode([String: Int].self, from: data) { usage = u }
        logTail = tail(of: logURL, lines: 5)
    }

    func saveConfig() {
        if let data = try? JSONEncoder().encode(config) { try? data.write(to: configURL) }
    }

    private func tail(of url: URL, lines: Int) -> String {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return s.components(separatedBy: .newlines).suffix(lines).joined(separator: "\n")
    }

    // MARK: launchd

    private func uid() -> uid_t { getuid() }

    func jobLoaded() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["print", "gui/\(uid())/local.macbackup"]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try? p.run(); p.waitUntilExit()
        return p.terminationStatus == 0
    }

    func writePlist() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key><string>local.macbackup</string>
          <key>ProgramArguments</key>
          <array><string>/bin/bash</string><string>\(scriptURL.path)</string></array>
          <key>StartCalendarInterval</key>
          <array><dict><key>Hour</key><integer>\(config.hour)</integer><key>Minute</key><integer>\(config.minute)</integer></dict></array>
          <key>RunAtLoad</key><false/>
          <key>LowPriorityIO</key><true/>
          <key>Nice</key><integer>19</integer>
          <key>ProcessType</key><string>Background</string>
        </dict>
        </plist>
        """
        try? xml.write(to: plistURL, atomically: true, encoding: .utf8)
    }

    private func launchctl(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try? p.run(); p.waitUntilExit()
    }

    func enableAuto() {
        writePlist()
        launchctl(["bootout", "gui/\(uid())/local.macbackup"])
        launchctl(["bootstrap", "gui/\(uid())", plistURL.path])
    }

    func disableAuto() {
        launchctl(["bootout", "gui/\(uid())/local.macbackup"])
    }

    func applyAuto() {
        saveConfig()
        if config.autoEnabled { enableAuto() } else { disableAuto() }
    }

    // MARK: run

    func loadCategories() {
        if getenv("BACKUP_CONTROL_PREVIEW") != nil {
            if let data = try? Data(contentsOf: Self.base.appendingPathComponent("preview.json")),
               let e = try? JSONDecoder().decode(Estimate.self, from: data) {
                categories = e.categories ?? [:]
                uploadBps = e.uploadBps ?? 0
                if let ip = e.egressIP {
                    egressIP = ip
                    egressRegion = [e.egressCity, e.egressCC].compactMap { $0 }.joined(separator: ", ")
                }
            }
            return
        }
        scanning = true
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [scriptURL.path, "--estimate", "--categories", "--speed"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        p.terminationHandler = { [weak self] _ in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let e = try? JSONDecoder().decode(Estimate.self, from: data) else {
                DispatchQueue.main.async { self?.scanning = false }
                return
            }
            DispatchQueue.main.async {
                self?.categories = e.categories ?? [:]
                self?.uploadBps = e.uploadBps ?? 0
                self?.scanning = false
            }
        }
        try? p.run()
    }

    func fetchEgress(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastIPFetch) > 300 else { return }
        lastIPFetch = now
        guard let url = URL(string: "https://ifconfig.co/json") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ip = obj["ip"] as? String else { return }
            let city = obj["city"] as? String
            let country = obj["country_iso"] as? String
            let region = [city, country].compactMap { $0 }.joined(separator: ", ")
            DispatchQueue.main.async {
                self?.egressIP = ip
                self?.egressRegion = region
            }
        }.resume()
    }

    func estimate(_ completion: @escaping (Estimate?) -> Void) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [scriptURL.path, "--estimate", "--speed", "--egress"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        p.terminationHandler = { _ in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let e = try? JSONDecoder().decode(Estimate.self, from: data)
            DispatchQueue.main.async { completion(e) }
        }
        do { try p.run() } catch { DispatchQueue.main.async { completion(nil) } }
    }

    func backupNow() {
        guard !isRunning else { return }
        isRunning = true
        logTail = "Starting backup…"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [scriptURL.path, "--force"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env
        p.standardOutput = Pipe(); p.standardError = Pipe()
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.isRunning = false
                self?.refresh()
            }
        }
        task = p
        do { try p.run() } catch {
            isRunning = false
            logTail = "Failed to start: \(error.localizedDescription)"
        }
    }

    func stopBackup() {
        task?.terminate()
        task = nil
        isRunning = false
        logTail = "Stopped by user"
    }

    // MARK: formatting

    func humanBytes(_ b: Int) -> String {
        let f = ByteCountFormatter(); f.countStyle = .file
        return f.string(fromByteCount: Int64(b))
    }

    var lastRunText: String {
        guard let s = state?.lastRun, let d = ISO8601DateFormatter().date(from: s) else { return "Never" }
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        return f.string(from: d)
    }

    var statusColor: Color {
        guard let st = state?.status else { return .gray }
        switch st {
        case "ok": return .green
        case "skipped", "capped": return .orange
        case "error": return .red
        default: return .gray
        }
    }

    var statusText: String {
        guard let st = state?.status else { return "Idle" }
        switch st {
        case "ok": return "Healthy"
        case "skipped": return "Skipped"
        case "capped": return "Capped"
        case "error": return "Failed"
        default: return "Idle"
        }
    }
}


// MARK: - Localization

struct Loc {
    let zh: Bool
    private func s(_ en: String, _ cn: String) -> String { zh ? cn : en }

    var appTitle: String { s("Backup Control", "备份控制") }
    var subtitle: String { s("Encrypted · OneDrive", "加密备份 · OneDrive") }
    var lastBackup: String { s("LAST BACKUP", "上次备份") }
    var statusLabel: String { s("STATUS", "状态") }
    var never: String { s("Never", "从未备份") }
    var usedThisMonth: String { s("Data used this month", "本月已用流量") }
    var automatic: String { s("Automatic Backup", "自动备份") }
    var dailyAt: String { s("DAILY AT", "每天") }
    var monthlyCap: String { s("MONTHLY CAP", "每月上限") }
    var uploadLimit: String { s("UPLOAD LIMIT", "上传限速") }
    var backUpNow: String { s("Back Up Now", "立即备份") }
    var stopBackup: String { s("Stop Backup", "停止备份") }
    var log: String { s("Log", "日志") }
    var recent: String { s("RECENT ACTIVITY", "最近活动") }
    var noActivity: String { s("No activity yet", "暂无活动记录") }
    var healthy: String { s("Healthy", "正常") }
    var skipped: String { s("Skipped", "已跳过") }
    var capped: String { s("Capped", "已达上限") }
    var failed: String { s("Failed", "失败") }
    var idle: String { s("Idle", "空闲") }
    var acOnly: String { s("Runs only while plugged in", "仅在接通电源时运行") }
    var firstHint: String { s("First full backup ≈ 30 GB — prefer Wi-Fi", "首次全量约 30 GB,建议用 Wi-Fi") }
    var confirmTitle: String { s("Start backup now?", "确定现在开始备份?") }
    var confirmBody: String { s("The first full backup is about 30 GB. On mobile data this may be expensive or exceed your cap.", "首次全量备份约 30 GB。使用手机流量可能产生较高费用或超出上限。") }
    var start: String { s("Start", "开始") }
    var cancel: String { s("Cancel", "取消") }
    var language: String { s("Language", "语言") }
    var running: String { s("Running…", "进行中…") }
    var readyTitle: String { s("Ready to back up", "准备开始备份") }
    var aboutToUpload: String { s("About to upload", "预计需要上传") }
    var firstRunNote: String { s("first full backup", "首次全量备份") }
    var changesNote: String { s("changed since last backup", "自上次备份以来的变更") }
    var estimating: String { s("Estimating…", "正在估算…") }
    var atSpeed: String { s("At current upload speed", "按当前上行速度") }
    var about: String { s("about", "约") }
    var egress: String { s("Egress IP", "出口 IP") }
    var useProxy: String { s("Upload via proxy (foreign IP)", "通过代理上传(境外 IP)") }
    var scopeTitle: String { s("What to back up", "备份范围") }
    var total: String { s("Total", "合计") }
    var rescan: String { s("Scan now", "重新扫描") }
    func catName(_ id: String) -> String {
        switch id {
        case "documents": return s("Documents", "文档")
        case "desktop": return s("Desktop", "桌面")
        case "pictures": return s("Pictures", "图片")
        case "movies": return s("Movies", "影片")
        case "music": return s("Music", "音乐")
        case "downloads": return s("Downloads", "下载")
        case "dotfiles": return s("Dotfiles & configs", "配置文件")
        case "full": return s("Full disk (everything)", "全盘(全部)")
        default: return id
        }
    }
    var useProxyHint: String { s("Slower but hides your real IP", "较慢,但隐藏真实 IP") }
    var foreignNotice: String { s("This upload will leave via a foreign IP", "本次上传将从境外 IP 发出") }
    var ackForeign: String { s("I understand, upload anyway", "我已了解,仍然上传") }
    func capAdjust(_ gb: Int) -> String {
        s("Monthly cap will be raised to \(gb) GB to fit this backup",
          "每月上限将自动调整为 \(gb) GB,以容纳本次备份")
    }
}

// MARK: - UI


struct ContentView: View {
    @StateObject private var store = BackupStore()
    @State private var showConfirm = false
    @State private var showEstimate = false
    @State private var estimating = false
    @State private var pendingEstimate: Estimate? = nil
    @State private var timeText: String = ""
    @State private var ackForeign = false

    private let timer = Timer.publish(every: 4, on: .main, in: .common).autoconnect()
    private var l: Loc { Loc(zh: store.config.language == "zh") }

    var body: some View {
        Group {
            if store.initialized {
                mainBody
            } else {
                SetupView(store: store)
            }
        }
    }

    private var mainBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                scopeSection
                overviewSection
                scheduleSection
                actionSection
                activitySection
                Text(l.acOnly)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            }
            .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(width: 660, height: 760)
        .onReceive(timer) { _ in
            if !store.isRunning { store.refresh() }
            store.fetchEgress()
        }
        .onAppear {
            store.refresh()
            store.fetchEgress(force: true)
            store.loadCategories()
            timeText = String(format: "%02d:%02d", store.config.hour, store.config.minute)
        }
        .alert(l.confirmTitle, isPresented: $showConfirm) {
            Button(l.cancel, role: .cancel) {}
            Button(l.start) { store.backupNow() }
        } message: { Text(l.confirmBody) }
        .sheet(isPresented: $showEstimate) {
            estimateSheet
        }
    }

    private var estimateSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(l.readyTitle).font(.title3.weight(.semibold))

            if let e = pendingEstimate {
                Text(l.aboutToUpload).font(.subheadline).foregroundStyle(.secondary)
                Text(store.humanBytes(e.bytes))
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("\(e.files.formatted()) files · \(e.firstRun ? l.firstRunNote : l.changesNote)")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if let ip = e.egressIP {
                    HStack(spacing: 6) {
                        Image(systemName: "globe")
                        Text("\(l.egress): \(ip) · \(e.egressCC ?? "?")")
                            .monospaced()
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }

                if let bps = e.uploadBps, bps > 1000 {
                    Label {
                        Text("\(speedText(bps)) · \(l.about) \(etaText(e.bytes, bps))")
                    } icon: {
                        Image(systemName: "speedometer")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                }
            } else {
                Text(l.noActivity).foregroundStyle(.secondary)
            }

            if isForeignEgress {
                VStack(alignment: .leading, spacing: 8) {
                    Label(l.foreignNotice, systemImage: "exclamationmark.shield.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                    Toggle(l.ackForeign, isOn: $ackForeign)
                        .toggleStyle(.checkbox)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            }

            if neededCapGB > Int(store.config.monthlyCapGB) {
                Label(l.capAdjust(neededCapGB), systemImage: "arrow.up.right.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if isForeignEgress {
                VStack(alignment: .leading, spacing: 8) {
                    Label(l.foreignNotice, systemImage: "exclamationmark.shield.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                    Toggle(l.ackForeign, isOn: $ackForeign)
                        .toggleStyle(.checkbox)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            }

            Text(l.confirmBody).font(.caption).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button(l.cancel) { showEstimate = false }
                    .keyboardShortcut(.cancelAction)
                Button(l.start) {
                    showEstimate = false
                    if neededCapGB > Int(store.config.monthlyCapGB) {
                        store.config.monthlyCapGB = Double(neededCapGB)
                        store.saveConfig()
                    }
                    store.backupNow()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isForeignEgress && !ackForeign)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(l.appTitle).font(.title3.weight(.semibold))
                Text(l.subtitle).font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Image(systemName: "network").font(.caption2)
                    Text(store.egressIP.map { "\(l.egress): \($0)" } ?? "\(l.egress): —")
                        .font(.caption2)
                        .monospaced()
                        .textSelection(.enabled)
                    if let r = store.egressRegion, !r.isEmpty {
                        Text("· \(r)").font(.caption2)
                    }
                }
                .foregroundStyle(.tertiary)
            }
            Spacer()

            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 7, height: 7)
                Text(statusText).font(.subheadline.weight(.medium))
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(.quaternary.opacity(0.6)))

            Menu {
                Button("English") { store.config.language = "en"; store.saveConfig() }
                Button("简体中文") { store.config.language = "zh"; store.saveConfig() }
            } label: {
                Label(l.language, systemImage: "globe")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(l.language)
        }
    }

    private let catIds = ["documents", "desktop", "pictures", "movies", "music", "downloads", "dotfiles", "full"]

    private func scopeBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { store.config.scope.contains(id) },
            set: { on in
                var sc: [String]
                if id == "full" {
                    sc = on ? ["full"] : []
                } else {
                    sc = store.config.scope.filter { $0 != "full" && $0 != id }
                    if on { sc.append(id) }
                }
                store.config.scope = sc
                store.saveConfig()
            }
        )
    }

    private var totalBytes: Int {
        if store.config.scope.contains("full") { return store.categories["full"]?.bytes ?? 0 }
        return store.config.scope.compactMap { store.categories[$0]?.bytes }.reduce(0, +)
    }

    private var scopeSection: some View {
        GroupBox {
            VStack(spacing: 0) {
                ForEach(catIds, id: \.self) { id in
                    HStack(spacing: 10) {
                        Toggle(isOn: scopeBinding(id)) {
                            Text(l.catName(id)).font(.callout)
                        }
                        .toggleStyle(.checkbox)

                        Spacer()

                        if let c = store.categories[id] {
                            Text(store.humanBytes(c.bytes))
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text("· " + etaShort(c.bytes))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .frame(width: 78, alignment: .trailing)
                        } else {
                            Text("…").font(.callout).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 7)

                    if id != catIds.last { Divider() }
                }

                Divider()
                HStack {
                    Text(l.total).font(.callout.weight(.semibold))
                    Spacer()
                    Text(store.humanBytes(totalBytes))
                        .font(.callout.weight(.semibold).monospacedDigit())
                    Text("· " + etaShort(totalBytes))
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 9)
            }
        } label: {
            HStack(spacing: 8) {
                Text(l.scopeTitle)
                Spacer()
                if store.scanning {
                    ProgressView().controlSize(.small)
                }
                Button {
                    store.loadCategories()
                } label: {
                    Label(l.rescan, systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help(l.rescan)
                .disabled(store.scanning)
            }
        }
    }

    private func etaShort(_ bytes: Int) -> String {
        guard store.uploadBps > 1000, bytes > 0 else { return "—" }
        let secs = Double(bytes) / (store.uploadBps * 0.8)
        if secs < 60 { return "< 1 min" }
        let m = Int(secs / 60)
        if m < 60 { return "\(l.about) \(m) min" }
        let h = m / 60, rm = m % 60
        return rm == 0 ? "\(l.about) \(h) h" : "\(l.about) \(h)h \(rm)m"
    }

    // MARK: overview

    private var overviewSection: some View {
        HStack(alignment: .center, spacing: 26) {
            ZStack {
                Circle()
                    .stroke(.quaternary, lineWidth: 11)
                Circle()
                    .trim(from: 0, to: max(0.001, store.usageFraction))
                    .stroke(
                        AngularGradient(colors: store.usageFraction > 0.9 ? [.red, .orange, .red] : [.accentColor, .teal, .accentColor],
                                        center: .center),
                        style: StrokeStyle(lineWidth: 11, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 1) {
                    Text("\(Int(store.usageFraction * 100))%")
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                    Text("of cap").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 116, height: 116)

            VStack(alignment: .leading, spacing: 8) {
                Text(l.lastBackup)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(store.lastRunText)
                    .font(.title3.weight(.semibold))

                Text("\(store.humanBytes(store.usedThisMonth)) of \(String(format: "%.0f", store.config.monthlyCapGB)) GB · \(l.usedThisMonth)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let msg = store.state?.message {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                if store.usedThisMonth == 0 {
                    Label(l.firstHint, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: schedule

    private var scheduleSection: some View {
        GroupBox {
            VStack(spacing: 0) {
                HStack {
                    Label(l.automatic, systemImage: "clock.arrow.circlepath")
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { store.config.autoEnabled },
                        set: { v in store.config.autoEnabled = v; store.applyAuto() }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
                .padding(.vertical, 10)

                Divider()

                LabeledContent(l.dailyAt) {
                    HStack(spacing: 6) {
                        TextField("03:00", text: $timeText)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 68)
                            .onSubmit { commitTime() }
                            .onChange(of: timeText) { _, newValue in
                                if newValue.range(of: #"^\d{1,2}:\d{2}$"#, options: .regularExpression) != nil {
                                    commitTime()
                                }
                            }
                    }
                }
                .padding(.vertical, 8)

                Divider()

                LabeledContent(l.monthlyCap) {
                    HStack(spacing: 6) {
                        TextField("25", value: $store.config.monthlyCapGB, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 64)
                            .onChange(of: store.config.monthlyCapGB) { _, v in
                                let c = min(500, max(1, v))
                                if c != v { store.config.monthlyCapGB = c }
                                store.saveConfig()
                            }
                        Text("GB").foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 8)

                Divider()

                LabeledContent(l.uploadLimit) {
                    HStack(spacing: 6) {
                        TextField("2", value: $store.config.bwlimitMB, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 64)
                            .onChange(of: store.config.bwlimitMB) { _, v in
                                let c = min(100, max(1, v))
                                if c != v { store.config.bwlimitMB = c }
                                store.saveConfig()
                            }
                        Text("MB/s").foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 8)

                Divider()

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(l.useProxy)
                        Text(l.useProxyHint).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { store.config.useProxy },
                        set: { v in store.config.useProxy = v; store.saveConfig() }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
                .padding(.vertical, 8)
            }
        }
    }

    // MARK: actions

    private var actionSection: some View {
        HStack(spacing: 12) {
            Button {
                if store.isRunning {
                    store.stopBackup()
                } else if estimating {
                    return
                } else {
                    estimating = true
                    store.estimate { e in
                        estimating = false
                        pendingEstimate = e
                        ackForeign = false
                        showEstimate = true
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    if store.isRunning {
                        ProgressView().controlSize(.small)
                        Text(l.stopBackup)
                    } else if estimating {
                        ProgressView().controlSize(.small)
                        Text(l.estimating)
                    } else {
                        Label(l.backUpNow, systemImage: "arrow.up.circle.fill")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(store.isRunning ? .red : .accentColor)

            Button {
                NSWorkspace.shared.open(store.logURL)
            } label: {
                Label(l.log, systemImage: "doc.text.magnifyingglass")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    // MARK: activity

    private var activitySection: some View {
        GroupBox(l.recent) {
            Text(store.logTail.isEmpty ? l.noActivity : store.logTail)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(6)
                .textSelection(.enabled)
                .padding(.vertical, 2)
        }
    }

    private var isForeignEgress: Bool {
        guard let cc = pendingEstimate?.egressCC else { return false }
        return cc != "CN"
    }

    private var neededCapGB: Int {
        guard let e = pendingEstimate else { return Int(store.config.monthlyCapGB) }
        let need = Double(store.usedThisMonth + e.bytes) / (1024 * 1024 * 1024)
        return max(1, Int(ceil(need)))
    }

    private func commitTime() {
        let parts = timeText.split(separator: ":")
        guard parts.count == 2,
              let h = Int(parts[0]), let m = Int(parts[1]),
              (0...23).contains(h), (0...59).contains(m) else { return }
        store.config.hour = h
        store.config.minute = m
        store.applyAuto()
        timeText = String(format: "%02d:%02d", h, m)
    }

    private func speedText(_ bps: Double) -> String {
        let mb = bps / 1024 / 1024
        if mb >= 1 { return String(format: "%.1f MB/s", mb) }
        return String(format: "%.0f KB/s", bps / 1024)
    }

    private func etaText(_ bytes: Int, _ bps: Double) -> String {
        let secs = Double(bytes) / (bps * 0.8)
        if secs < 60 { return "< 1 min" }
        let m = Int(secs / 60)
        if m < 60 { return "\(m) min" }
        let h = m / 60, rm = m % 60
        return rm == 0 ? "\(h) h" : "\(h) h \(rm) m"
    }

    private var statusText: String {
        guard let st = store.state?.status else { return l.idle }
        switch st {
        case "ok": return l.healthy
        case "skipped": return l.skipped
        case "capped": return l.capped
        case "error": return l.failed
        default: return l.idle
        }
    }

    private var statusColor: Color {
        guard let st = store.state?.status else { return .secondary }
        switch st {
        case "ok": return .green
        case "skipped", "capped": return .orange
        case "error": return .red
        default: return .secondary
        }
    }
}


// MARK: - Setup

struct SetupView: View {
    @ObservedObject var store: BackupStore
    @State private var remote: String = "onedrive"
    @State private var repoPath: String = "MacBackup/restic"
    @State private var password: String = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Welcome to Backup Control").font(.largeTitle.weight(.bold))
                Text("Encrypted, incremental backups to OneDrive — powered by restic and rclone.")
                    .foregroundStyle(.secondary)
            }

            GroupBox("Environment") {
                VStack(alignment: .leading, spacing: 8) {
                    row("restic", store.resticOK)
                    row("rclone", store.rcloneOK)
                    HStack {
                        Text("rclone remotes: " + (store.remotes.isEmpty ? "none found" : store.remotes.joined(separator: ", ")))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Refresh") {
                            store.checkEnvironment()
                            store.loadRemotes()
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(6)
            }

            GroupBox("Repository") {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("Remote") {
                        TextField("onedrive", text: $remote)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 210)
                    }
                    LabeledContent("Folder") {
                        TextField("MacBackup/restic", text: $repoPath)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 210)
                    }
                    LabeledContent("Password") {
                        HStack(spacing: 6) {
                            SecureField("at least 8 characters", text: $password)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 210)
                            Button("Generate") {
                                password = UUID().uuidString + UUID().uuidString
                            }
                        }
                    }
                    Label("This password encrypts every snapshot. Save it in your password manager — it cannot be reset.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                .padding(6)
            }

            if let e = error {
                Text(e).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }

            Spacer()

            HStack {
                if !store.remotes.isEmpty {
                    Text("Tip: the remote must already exist in rclone config.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button(busy ? "Initializing…" : "Initialize repository") {
                    busy = true
                    error = nil
                    store.initializeRepo(remote: remote, path: repoPath, password: password) { err in
                        busy = false
                        if let err { error = err }
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(busy || password.count < 8 || remote.isEmpty || repoPath.isEmpty
                          || !store.resticOK || !store.rcloneOK)
            }
        }
        .padding(26)
        .frame(width: 660, height: 600)
        .onAppear {
            remote = store.config.remote
            repoPath = store.config.repoPath
            store.checkEnvironment()
            store.loadRemotes()
        }
    }

    private func row(_ name: String, _ ok: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(ok ? .green : .red)
            Text(name)
            Spacer()
            Text(ok ? "found" : "missing — run: brew install " + name)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - App


#if !RENDER_PREVIEW
@main
struct BackupApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
#endif
