import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Darwin
import Security

protocol CredentialStore {
    func read() throws -> String?
    func write(_ value: String) throws
    func delete() throws
}

struct KeychainCredentials: CredentialStore {
    private var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "ComfyDraw.localLLM", kSecAttrAccount as String: "apiKey"] }
    func read() throws -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let code = SecItemCopyMatching(q as CFDictionary, &result)
        if code == errSecItemNotFound { return nil }
        guard code == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else { throw credentialError() }
        return value
    }
    func write(_ value: String) throws {
        let data = Data(value.utf8)
        var q = query
        q[kSecValueData as String] = data
        guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw credentialError() }
    }
    func delete() throws {
        let code = SecItemDelete(query as CFDictionary)
        guard code == errSecSuccess || code == errSecItemNotFound else { throw credentialError() }
    }
    private func credentialError() -> NSError {
        NSError(domain: "ComfyDraw.Keychain", code: 1, userInfo: [NSLocalizedDescriptionKey: "钥匙串操作失败"])
    }
}

func saveCredential(_ value: String, store: CredentialStore) throws {
    guard !value.isEmpty else { return }
    if let existing = try store.read() {
        guard existing == value else {
            throw NSError(domain: "ComfyDraw.Keychain", code: 4, userInfo: [NSLocalizedDescriptionKey: "已有不同 Key；请先备份，再明确删除后设置新 Key"])
        }
        return
    }
    try store.write(value)
    guard try store.read() == value else {
        throw NSError(domain: "ComfyDraw.Keychain", code: 3, userInfo: [NSLocalizedDescriptionKey: "密钥保存验证失败，请检查钥匙串"])
    }
}

func migrateCredential(defaults: UserDefaults, store: CredentialStore) throws {
    guard let old = defaults.string(forKey: AppSettings.llmKeyKey), !old.isEmpty else { return }
    if let existing = try store.read() {
        guard existing == old else { throw NSError(domain: "ComfyDraw.Keychain", code: 2, userInfo: [NSLocalizedDescriptionKey: "旧密钥与钥匙串不同，已保留两者"] ) }
    } else { try store.write(old) }
    guard try store.read() == old else { throw NSError(domain: "ComfyDraw.Keychain", code: 3, userInfo: [NSLocalizedDescriptionKey: "密钥迁移验证失败"] ) }
    defaults.removeObject(forKey: AppSettings.llmKeyKey)
}

final class LocalOnlySessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private let localSession: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0]
    return URLSession(configuration: configuration, delegate: LocalOnlySessionDelegate(), delegateQueue: nil)
}()

func localEndpoint(_ value: String) -> URL? {
    guard let parts = URLComponents(string: value), parts.scheme == "http",
          let host = parts.host, host == "127.0.0.1" || host == "localhost",
          parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
          parts.percentEncodedPath.isEmpty || parts.percentEncodedPath == "/",
          let authority = value.components(separatedBy: "/").dropFirst(2).first,
          !authority.isEmpty, !authority.contains("%") else { return nil }
    let fields = authority.split(separator: ":", omittingEmptySubsequences: false)
    guard fields.count <= 2, fields.first.map(String.init) == host else { return nil }
    var port: Int?
    if fields.count == 2 {
        let raw = fields[1]
        guard !raw.isEmpty, raw.allSatisfy({ $0.isASCII && $0.isNumber }),
              let number = Int(raw), (1...65535).contains(number) else { return nil }
        port = number
    }
    var normalized = URLComponents()
    normalized.scheme = "http"
    normalized.host = "127.0.0.1"
    normalized.port = port
    return normalized.url
}

// MARK: - 本机引擎发现与设置

struct EngineInstall: Identifiable {
    let id: String
    let title: String
    let root: URL
    let python: URL
    let main: URL
    let modelConfig: URL?
    let input: URL
    let output: URL
}

enum EngineLocator {
    /// Finds ComfyUI installs this app can launch directly. Only reads existing files.
    static func discover() -> [EngineInstall] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var found: [EngineInstall] = []
        var seen = Set<String>()

        func add(_ install: EngineInstall?) {
            guard let install, !seen.contains(install.root.path) else { return }
            seen.insert(install.root.path)
            found.append(install)
        }

        if let raw = UserDefaults.standard.string(forKey: AppSettings.engineRootKey), !raw.isEmpty {
            let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
            add(make(title: "自定义目录", base: url, modelConfig: nil))
        }

        let installations = home.appendingPathComponent("Library/Application Support/Comfy Desktop/installations.json")
        if let data = try? Data(contentsOf: installations),
           let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for item in list {
                guard item["status"] as? String == "installed",
                      item["sourceId"] as? String == "standalone",
                      let path = item["installPath"] as? String else { continue }
                let name = item["name"] as? String ?? "ComfyUI"
                let id = item["id"] as? String ?? ""
                let config = home.appendingPathComponent(
                    "Library/Application Support/Comfy Desktop/instance-model-paths/\(id).yaml")
                let configURL = fm.fileExists(atPath: config.path) ? config : nil
                add(make(title: "Comfy Desktop · \(name)",
                         base: URL(fileURLWithPath: path, isDirectory: true),
                         modelConfig: configURL))
            }
        }

        for path in ["~/ComfyUI", "~/comfyui", "~/Documents/ComfyUI"] {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
            add(make(title: "ComfyUI", base: url, modelConfig: nil))
        }
        return found
    }

    private static func make(title: String, base: URL, modelConfig: URL?) -> EngineInstall? {
        let fm = FileManager.default
        var root = base
        let nested = base.appendingPathComponent("ComfyUI", isDirectory: true)
        if fm.fileExists(atPath: nested.appendingPathComponent("main.py").path) { root = nested }
        let main = root.appendingPathComponent("main.py")
        let python = root.appendingPathComponent(".venv/bin/python3")
        guard fm.fileExists(atPath: main.path), fm.isExecutableFile(atPath: python.path) else { return nil }
        let shared = fm.homeDirectoryForCurrentUser.appendingPathComponent("ComfyUI-Shared", isDirectory: true)
        func folder(_ preferred: URL, _ fallback: String) -> URL {
            fm.fileExists(atPath: preferred.path) ? preferred : root.appendingPathComponent(fallback, isDirectory: true)
        }
        return EngineInstall(id: root.path, title: title, root: root, python: python, main: main,
                             modelConfig: modelConfig,
                             input: folder(shared.appendingPathComponent("input", isDirectory: true), "input"),
                             output: folder(shared.appendingPathComponent("output", isDirectory: true), "output"))
    }
}

enum AppSettings {
    static let backendBaseKey = "backendBase"
    static let engineRootKey = "engineRoot"
    static let autoStartKey = "autoStartEngine"
    static let llmBaseKey = "llmBase"
    static let llmKeyKey = "llmKeyOverride"

    static var backendBase: String {
        UserDefaults.standard.string(forKey: backendBaseKey) ?? "http://127.0.0.1:8188"
    }
    static var autoStartEngine: Bool {
        UserDefaults.standard.object(forKey: autoStartKey) as? Bool ?? true
    }
    static var llmBase: String {
        UserDefaults.standard.string(forKey: llmBaseKey) ?? "http://127.0.0.1:8000"
    }
    static func migratedSupportDir() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ComfyDraw", isDirectory: true)
    }
}

#if !APP_TESTING
// Owns only the process that this app launches. Never interrupts an existing server.
@MainActor
final class LocalEngine {
    static let shared = LocalEngine()
    private var process: Process?
    private var logHandle: FileHandle?
    var activeGenerations = 0

    var isRunning: Bool { process?.isRunning == true }
    var isOwned: Bool { isRunning }

    func start(_ install: EngineInstall, port: Int) throws {
        if isRunning { return }
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: install.python.path),
              fm.isReadableFile(atPath: install.main.path) else {
            throw NSError(domain: "ComfyDraw", code: 10, userInfo: [NSLocalizedDescriptionKey:
                "找不到可用的 ComfyUI 安装，请在设置中指定引擎目录。"])
        }
        let child = Process()
        child.executableURL = install.python
        child.currentDirectoryURL = install.root
        var arguments = ["-s", install.main.path, "--listen", "127.0.0.1", "--port", String(port),
                         "--disable-auto-launch",
                         "--input-directory", install.input.path,
                         "--output-directory", install.output.path]
        if let config = install.modelConfig {
            arguments.append(contentsOf: ["--extra-model-paths-config", config.path])
        }
        child.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["NO_PROXY"] = "127.0.0.1,localhost"
        environment["no_proxy"] = "127.0.0.1,localhost"
        child.environment = environment
        let logPath = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ComfyDraw-engine.log").path
        let fd = open(logPath, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard fd >= 0 else {
            throw NSError(domain: "ComfyDraw", code: 11,
                          userInfo: [NSLocalizedDescriptionKey: "无法打开本地引擎日志"])
        }
        let log = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        child.standardOutput = log
        child.standardError = log
        try child.run()
        logHandle = log
        process = child
    }

}
#endif

// MARK: - 历史记录模型

struct HistoryItem: Codable, Identifiable {
    let id: UUID
    let date: Date
    let mode: String          // txt2img / img2img
    let prompt: String
    let negative: String
    let width: Int
    let height: Int
    let steps: Int
    let seed: Int
    let batch: Int
    let unet: String
    let clip: String
    let vae: String
    let strength: Double
    let files: [String]       // 归档内的文件名
    let seconds: Int
    var referenceFile: String? = nil
}

// MARK: - 生成器

@MainActor
final class Generator: ObservableObject {
    @Published var tab: Int = 0
    @Published var mode: String = "txt2img"
    @Published var prompt: String = "一只橘猫坐在中式木窗边，窗外是雨中的江南水乡，暖色灯笼的光映在湿漉漉的石板路上，摄影风格，浅景深"
    @Published var negative: String = ""
    @Published var width: Int = 1024
    @Published var height: Int = 1024
    @Published var steps: Int = 20
    @Published var seed: Int = 42
    @Published var batch: Int = 1
    @Published var strength: Double = 0.65
    @Published var refImagePath: String = ""

    @Published var isRunning = false {
        didSet {
            #if !APP_TESTING
            if oldValue != isRunning { LocalEngine.shared.activeGenerations += isRunning ? 1 : -1 }
            #endif
        }
    }
    @Published var isSaving = false
    @Published var status = "就绪"
    @Published var progress: Double = 0
    @Published var images: [NSImage] = []
    @Published var backendOK = false
    @Published var engineStarting = false
    @Published var backendBase: String = AppSettings.backendBase
    @Published var autoStartEngine: Bool = AppSettings.autoStartEngine
    @Published var engineRoot: String = UserDefaults.standard.string(forKey: AppSettings.engineRootKey) ?? ""
    @Published var detectedEngines: String = "尚未检测"
    @Published var llmBase: String = AppSettings.llmBase
    @Published var llmKey: String = ""
    private let credentialStore: CredentialStore = KeychainCredentials()
    @Published var settingsMessage: String = ""

    @Published var unetList: [String] = []
    @Published var clipList: [String] = []
    @Published var vaeList: [String] = []
    @Published var unet = "qwen-image-2.1-UC-Q6_K.gguf"
    @Published var clip = "qwen3vl_8b_bf16.safetensors"
    @Published var vae  = "qwen_image_2.1_vae_bf16.safetensors"

    @Published var history: [HistoryItem] = []
    @Published var selectedHistory: HistoryItem?

    // 文档分析
    @Published var docPath: String = ""
    @Published var docChars: Int = 0
    @Published var isAnalyzing = false
    @Published var analyzeStatus = "选择 PDF / Word 文件，基于文本节选生成提示词"
    @Published var hint: String = ""
    @Published var llmModel: String = "Qwen3.8-Flash-Next-oQ4e-mtp"
    @Published var generatedPrompt: String = ""

    private static func configuredBase() -> URL? {
        #if APP_TESTING
        guard let value = ProcessInfo.processInfo.environment["COMFYUI_BASE_URL"],
              let parsed = URLComponents(string: value),
              parsed.scheme == "http", parsed.host == "127.0.0.1",
              parsed.user == nil, parsed.password == nil,
              parsed.query == nil, parsed.fragment == nil,
              parsed.path.isEmpty || parsed.path == "/",
              let url = parsed.url else { return nil }
        return url
        #else
        return nil
        #endif
    }
    #if APP_TESTING
    var configuredURL = Generator.configuredBase()
    #else
    private let configuredURL = Generator.configuredBase()
    #endif
    private var activeEndpoint: URL?
    private var connectedEndpoint: URL?
    private var selectedEndpoint: URL? { configuredURL ?? localEndpoint(AppSettings.backendBase) }
    private var generationFinishing = false
    private var backendAddressValid: Bool { selectedEndpoint != nil }
    private var task: Task<Void, Never>?
    private var currentID: String?
    private var cancellationRequested = false
    private var uploadedReference: Data?
    private var documentText = ""
    private var documentRequest = UUID()
    private var historyReadFailed = false
    private var historySnapshot: Data?
    private let selectedSupportDir: URL
    private(set) var usingLegacyDirectory = false
    private var connectionRequest = UUID()

    // MARK: 路径

    var supportDir: URL { selectedSupportDir }
    var archiveDir: URL {
        supportDir.appendingPathComponent("archive", isDirectory: true)
    }
    var historyFile: URL { supportDir.appendingPathComponent("history.json") }
    var comfyInputDir: URL {
        URL(fileURLWithPath: NSString(string: "~/ComfyUI-Shared/input").expandingTildeInPath)
    }

    init() {
        #if APP_TESTING
        guard let path = ProcessInfo.processInfo.environment["APP_DATA_DIR"], path.hasPrefix("/") else {
            fatalError("Tests require an absolute APP_DATA_DIR")
        }
        selectedSupportDir = URL(fileURLWithPath: path, isDirectory: true)
        #else
        let fm = FileManager.default
        let target = AppSettings.migratedSupportDir()
        let legacy = target.deletingLastPathComponent().appendingPathComponent("Local Image Desk", isDirectory: true)
        let useLegacy = !fm.fileExists(atPath: target.path) && fm.fileExists(atPath: legacy.path)
        selectedSupportDir = useLegacy ? legacy : target
        usingLegacyDirectory = useLegacy
        #endif
        loadHistory()
        refresh()
    }

    // MARK: 后端

    func refresh() {
        guard !engineStarting, !isRunning, !generationFinishing else { return }
        connectedEndpoint = nil
        let requestID = UUID()
        connectionRequest = requestID
        unetList = []
        clipList = []
        vaeList = []
        backendOK = false
        guard backendAddressValid else {
            status = "后端地址无效：仅支持本机 HTTP 地址，例如 http://127.0.0.1:8188"
            return
        }
        let endpoint = selectedEndpoint!
        activeEndpoint = endpoint
        engineStarting = true
        Task {
            defer { engineStarting = false; activeEndpoint = nil }
            let ok = await checkBackend()
            guard connectionRequest == requestID else { return }
            backendOK = ok
            if ok {
                connectedEndpoint = endpoint
                loadLists(requestID)
                if !isRunning && !historyReadFailed { status = "绘图引擎已连接" }
                return
            }
            #if APP_TESTING
            if !isRunning && !historyReadFailed { status = "绘图引擎未连接" }
            #else
            await startLocalEngine(requestID)
            #endif
        }
    }

    private func checkBackend() async -> Bool {
        guard let endpoint = activeEndpoint else { return false }
        var req = URLRequest(url: endpoint.appendingPathComponent("system_stats"))
        req.timeoutInterval = 3
        guard let (data, response) = try? await localSession.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let system = obj["system"] as? [String: Any],
              system["comfyui_version"] is String else { return false }
        return true
    }

    #if !APP_TESTING
    private static func portAppearsAvailable(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: in_addr_t(INADDR_LOOPBACK).bigEndian)
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    private func startLocalEngine(_ requestID: UUID) async {
        guard AppSettings.autoStartEngine else {
            status = "绘图引擎未连接。可在设置中开启自动启动，或手动打开 ComfyUI 后重试"
            return
        }
        if !isRunning && !historyReadFailed { status = "正在启动本地绘图引擎…" }
        guard let install = EngineLocator.discover().first else {
            status = "未找到可启动的 ComfyUI。请在设置中指定 ComfyUI 目录，或先手动运行 ComfyUI"
            return
        }
        guard let port = activeEndpoint?.port else {
            status = "自动启动需要显式指定端口，例如 http://127.0.0.1:8188"
            return
        }
        if LocalEngine.shared.isRunning {
            status = "已有本软件启动的引擎进程，但当前端点不可用；请检查配置"
            return
        }
        if !Self.portAppearsAvailable(port) {
            status = "端口 \(port) 已被占用，且无法识别为 ComfyUI；请检查占用端口的程序后重试"
            return
        }
        do {
            try LocalEngine.shared.start(install, port: port)
        } catch {
            backendOK = false
            status = "绘图引擎启动失败：\(error.localizedDescription)"
            return
        }
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline && LocalEngine.shared.isRunning {
            if await checkBackend() && LocalEngine.shared.isRunning {
                guard connectionRequest == requestID else { return }
                backendOK = true
                connectedEndpoint = activeEndpoint
                loadLists(requestID)
                if !isRunning && !historyReadFailed { status = "本地绘图引擎已就绪" }
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        backendOK = false
        if await checkBackend() {
            backendOK = true
            connectedEndpoint = activeEndpoint
            loadLists(requestID)
            status = "绘图引擎已连接"
        } else {
            status = LocalEngine.shared.isRunning
                ? "本地引擎启动超时，请检查端口 \(port) 后点击刷新"
                : "本地引擎未能启动；端口 \(port) 可能被占用，请检查 ComfyUI 日志"
        }
    }
    #endif

    private func loadLists(_ requestID: UUID) {
        fetchOptions("UnetLoaderGGUF", key: "unet_name", requestID: requestID) { self.unetList = $0; self.pickDefault() }
        fetchOptions("CLIPLoader", key: "clip_name", requestID: requestID) { self.clipList = $0; self.pickDefault() }
        fetchOptions("VAELoader", key: "vae_name", requestID: requestID) { self.vaeList = $0; self.pickDefault() }
    }

    private func fetchOptions(_ node: String, key: String, requestID: UUID,
                              done: @escaping @MainActor ([String]) -> Void) {
        guard let endpoint = connectedEndpoint else { return }
        let url = endpoint.appendingPathComponent("object_info").appendingPathComponent(node)
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        localSession.dataTask(with: request) { data, response, _ in
            guard (response as? HTTPURLResponse)?.statusCode == 200, let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let nodeInfo = obj[node] as? [String: Any],
                  let input = nodeInfo["input"] as? [String: Any],
                  let required = input["required"] as? [String: Any],
                  let spec = required[key] as? [Any],
                  let list = spec.first as? [String] else { return }
            Task { @MainActor in
                guard self.connectionRequest == requestID,
                      self.connectedEndpoint == self.selectedEndpoint else { return }
                done(list)
            }
        }.resume()
    }

    private func pickDefault() {
        if !unetList.contains(unet) {
            if let f = unetList.first(where: {
                $0.localizedCaseInsensitiveContains("qwen") && $0.contains("Q6_K")
            }) {
                unet = f
            } else if let f = unetList.first(where: { $0.localizedCaseInsensitiveContains("qwen") }) {
                unet = f
            } else if let f = unetList.first {
                unet = f
            }
        }
        if !clipList.contains(clip), let f = clipList.first(where: { $0.contains("qwen3vl_8b") })
            ?? clipList.first(where: { $0.localizedCaseInsensitiveContains("qwen") })
            ?? clipList.first {
            clip = f
        }
        if !vaeList.contains(vae), let f = vaeList.first(where: { $0.contains("qwen_image") })
            ?? vaeList.first {
            vae = f
        }
    }

    var modelLooksQwen: Bool {
        unet.localizedCaseInsensitiveContains("qwen") && clip.localizedCaseInsensitiveContains("qwen")
    }

    // MARK: 设置

    func detectEngines() {
        let found = EngineLocator.discover()
        detectedEngines = found.isEmpty
            ? "未检测到可启动的 ComfyUI"
            : found.map(\.title).joined(separator: "、")
    }

    func chooseEngineFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.message = "选择包含 main.py 的 ComfyUI 目录"
        if panel.runModal() == .OK, let url = panel.url {
            engineRoot = url.path
            detectEngines()
        }
    }

    func deleteStoredKey() {
        guard !isAnalyzing else { settingsMessage = "文档分析进行中，无法删除 Key"; return }
        do {
            try credentialStore.delete()
            UserDefaults.standard.removeObject(forKey: AppSettings.llmKeyKey)
            llmKey = ""
            settingsMessage = "已删除手动保存的 Key；文档分析将尝试本机 oMLX 配置"
        } catch { settingsMessage = "删除失败，旧密钥已保留" }
    }

    func saveSettings() {
        guard !isRunning, !generationFinishing, !engineStarting, !isAnalyzing else { settingsMessage = "任务、文档分析或连接进行中，无法保存设置"; return }
        guard let endpoint = localEndpoint(backendBase), let textEndpoint = localEndpoint(llmBase) else {
            settingsMessage = "地址必须为本机 HTTP 根地址，不能包含路径、凭据或查询参数"
            return
        }
        backendBase = endpoint.absoluteString
        llmBase = textEndpoint.absoluteString
        do {
            try migrateCredential(defaults: .standard, store: credentialStore)
            if !llmKey.isEmpty {
                try saveCredential(llmKey, store: credentialStore)
                llmKey = ""
            }
        } catch { settingsMessage = "Key 未保存：\(error.localizedDescription)"; return }
        UserDefaults.standard.set(backendBase, forKey: AppSettings.backendBaseKey)
        UserDefaults.standard.set(autoStartEngine, forKey: AppSettings.autoStartKey)
        UserDefaults.standard.set(engineRoot.trimmingCharacters(in: .whitespacesAndNewlines), forKey: AppSettings.engineRootKey)
        UserDefaults.standard.set(llmBase, forKey: AppSettings.llmBaseKey)
        settingsMessage = "已保存，正在重新连接…"
        detectEngines()
        refresh()
    }

    // MARK: 生成

    func generate() {
        guard backendAddressValid else {
            status = "后端地址无效：仅支持本机 HTTP 地址，例如 http://127.0.0.1:8188"
            return
        }
        guard !isRunning, !generationFinishing else { return }
        guard !engineStarting, backendOK, let endpoint = selectedEndpoint, endpoint == connectedEndpoint else { status = "绘图引擎尚未就绪，请等待或点击刷新"; return }
        guard unetList.contains(unet), clipList.contains(clip), vaeList.contains(vae) else {
            status = "请选择有效的图像模型、文本编码器和 VAE；请检查节点及模型后刷新"
            return
        }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { status = "请先输入提示词"; return }
        if mode == "img2img" && refImagePath.isEmpty {
            status = "图生图需要先选一张参考图"
            return
        }

        generationFinishing = true
        activeEndpoint = endpoint
        isRunning = true
        cancellationRequested = false
        uploadedReference = nil
        progress = 0
        images = []
        status = "提交任务…"

        let snap = (mode, text, negative.trimmingCharacters(in: .whitespacesAndNewlines),
                    width, height, steps, seed, batch, strength, unet, clip, vae, refImagePath)

        task = Task { [weak self] in
            guard let self else { return }
            defer { self.activeEndpoint = nil; self.generationFinishing = false }
            var submissionStarted = false
            do {
                let refName = try await self.prepareReference(snap.0 == "img2img" ? snap.12 : "")
                if self.cancellationRequested { self.isRunning = false; self.status = "已取消，生成任务尚未提交"; return }
                submissionStarted = true
                let id = try await self.submit(mode: snap.0, prompt: snap.1, negative: snap.2,
                                               w: snap.3, h: snap.4, steps: snap.5, seed: snap.6,
                                               batch: snap.7, strength: snap.8,
                                               unet: snap.9, clip: snap.10, vae: snap.11,
                                               refName: refName)
                self.currentID = id
                if self.cancellationRequested {
                    await self.cancelServerTask(id)
                    self.currentID = nil
                    self.isRunning = false
                    return
                }
                await self.poll(id, snapshot: snap)
                self.currentID = nil
            } catch {
                self.isRunning = false
                if self.cancellationRequested {
                    self.status = submissionStarted
                        ? "已停止等待；提交状态可能未知，请检查 ComfyUI 队列"
                        : "已取消，生成任务尚未提交；参考图可能已经上传"
                } else {
                    self.status = "失败：" + error.localizedDescription
                        + (submissionStarted ? "；提交状态可能未知，请检查 ComfyUI 队列" : "")
                }
            }
        }
    }

    private func prepareReference(_ path: String) async throws -> String {
        guard !path.isEmpty else { return "" }
        let data = try await Task.detached { () throws -> Data in
            let source = try Data(contentsOf: URL(fileURLWithPath: path))
            guard let image = NSImage(data: source), let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let converted = bitmap.representation(using: .png, properties: [:]) else {
                throw NSError(domain: "ComfyDraw", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "参考图无法转换为 PNG"])
            }
            return converted
        }.value
        if cancellationRequested { return "" }
        uploadedReference = data
        let name = "ref_\(UUID().uuidString).png"
        let boundary = UUID().uuidString
        let body = await Task.detached { () -> Data in
            var body = Data()
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"\(name)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
            body.append(data)
            body.append(Data("\r\n--\(boundary)--\r\n".utf8))
            return body
        }.value
        if cancellationRequested { return "" }
        guard let endpoint = activeEndpoint else { throw failure("任务端点不可用") }
        var request = URLRequest(url: endpoint.appendingPathComponent("upload/image"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (result, response) = try await localSession.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = try JSONSerialization.jsonObject(with: result) as? [String: Any],
              let uploaded = obj["name"] as? String else { throw failure("参考图上传失败") }
        let subfolder = obj["subfolder"] as? String ?? ""
        return subfolder.isEmpty ? uploaded : "\(subfolder)/\(uploaded)"
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "qwen", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func submit(mode: String, prompt: String, negative: String,
                        w: Int, h: Int, steps: Int, seed: Int, batch: Int, strength: Double,
                        unet: String, clip: String, vae: String,
                        refName: String) async throws -> String {

        var flow: [String: Any] = [
            "1": ["class_type": "UnetLoaderGGUF", "inputs": ["unet_name": unet]],
            "2": ["class_type": "CLIPLoader", "inputs": ["clip_name": clip, "type": "qwen_image"]],
            "3": ["class_type": "VAELoader", "inputs": ["vae_name": vae]],
            "4": ["class_type": "CLIPTextEncode", "inputs": ["text": prompt, "clip": ["2", 0]]],
            "5": ["class_type": "CLIPTextEncode", "inputs": ["text": negative, "clip": ["2", 0]]],
            "9": ["class_type": "SaveImage",
                  "inputs": ["images": ["8", 0], "filename_prefix": "comfydraw"]],
            "8": ["class_type": "VAEDecode", "inputs": ["samples": ["7", 0], "vae": ["3", 0]]],
        ]

        if mode == "img2img" {
            flow["10"] = ["class_type": "LoadImage", "inputs": ["image": refName]]
            flow["11"] = ["class_type": "VAEEncode",
                          "inputs": ["pixels": ["10", 0], "vae": ["3", 0]]]
            flow["7"] = ["class_type": "KSampler",
                         "inputs": ["model": ["1", 0], "positive": ["4", 0], "negative": ["5", 0],
                                    "latent_image": ["11", 0], "seed": seed, "steps": steps,
                                    "cfg": 1.0, "sampler_name": "euler", "scheduler": "simple",
                                    "denoise": strength]]
        } else {
            flow["6"] = ["class_type": "EmptySD3LatentImage",
                         "inputs": ["width": w, "height": h, "batch_size": batch]]
            flow["7"] = ["class_type": "KSampler",
                         "inputs": ["model": ["1", 0], "positive": ["4", 0], "negative": ["5", 0],
                                    "latent_image": ["6", 0], "seed": seed, "steps": steps,
                                    "cfg": 1.0, "sampler_name": "euler", "scheduler": "simple",
                                    "denoise": 1.0]]
        }

        guard let endpoint = activeEndpoint else { throw failure("任务端点不可用") }
        var req = URLRequest(url: endpoint.appendingPathComponent("prompt"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["prompt": flow])
        req.timeoutInterval = 30
        let (data, response) = try await localSession.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errs = obj["node_errors"] as? [String: Any], !errs.isEmpty {
                let detail = (errs.values.first as? [String: Any])
                    .flatMap { $0["errors"] as? [[String: Any]] }?
                    .first.flatMap { $0["message"] as? String } ?? "请检查模型和节点"
                throw failure("节点校验失败：\(detail)")
            }
            throw failure("提交失败，服务器拒绝请求或返回异常；如已提交请检查队列")
        }

        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "qwen", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "返回格式异常"])
        }
        if let errs = obj["node_errors"] as? [String: Any], !errs.isEmpty {
            let detail = (errs.values.first as? [String: Any])
                .flatMap { $0["errors"] as? [[String: Any]] }?
                .first.flatMap { $0["message"] as? String } ?? ""
            throw NSError(domain: "qwen", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "节点校验失败 \(detail)"])
        }
        guard let id = obj["prompt_id"] as? String else {
            throw NSError(domain: "qwen", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "未返回任务 ID"])
        }
        await MainActor.run { self.status = "排队中…" }
        return id
    }

    private func poll(_ id: String,
                      snapshot: (String, String, String, Int, Int, Int, Int, Int, Double, String, String, String, String)) async {
        guard let endpoint = activeEndpoint else { isRunning = false; status = "任务端点不可用"; return }
        let start = Date()
        var failures = 0
        while Date().timeIntervalSince(start) < 3600 {
            if cancellationRequested {
                await cancelServerTask(id)
                isRunning = false
                return
            }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if cancellationRequested { continue }
            guard let url = URL(string: "\(endpoint.absoluteString)/history/\(id)") else { break }
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            guard let (data, response) = try? await localSession.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                if cancellationRequested { continue }
                failures += 1
                if failures >= 5 { isRunning = false; status = "无法连接服务器，已停止等待；任务可能仍在运行，请检查 ComfyUI 队列"; return }
                continue
            }
            failures = 0
            if cancellationRequested { continue }
            var queueRequest = URLRequest(url: endpoint.appendingPathComponent("queue"))
            queueRequest.timeoutInterval = 5
            if let (queueData, queueResponse) = try? await localSession.data(for: queueRequest),
               (queueResponse as? HTTPURLResponse)?.statusCode == 200,
               let queue = try? JSONSerialization.jsonObject(with: queueData) as? [String: Any] {
                let running = (queue["queue_running"] as? [[Any]] ?? []).contains { $0.count > 1 && ($0[1] as? String) == id }
                let pending = (queue["queue_pending"] as? [[Any]] ?? []).contains { $0.count > 1 && ($0[1] as? String) == id }
                if !cancellationRequested {
                    status = running ? "生成中…" : (pending ? "排队中…" : "等待服务器返回结果…")
                }
            }
            if cancellationRequested { continue }
            guard let entry = obj[id] as? [String: Any],
                  let st = entry["status"] as? [String: Any],
                  let str = st["status_str"] as? String else { continue }

            if str == "error" {
                var msg = "生成失败"
                if let msgs = st["messages"] as? [[Any]] {
                    for m in msgs where m.count > 1 {
                        if let d = m[1] as? [String: Any],
                           let ex = d["exception_message"] as? String {
                            msg = "失败：" + String(ex.prefix(120))
                        }
                    }
                }
                await MainActor.run { self.isRunning = false; self.status = msg }
                return
            }

            if str == "success", let outs = entry["outputs"] as? [String: Any] {
                var refs: [(String, String, String)] = []
                for key in outs.keys.sorted() {
                    guard let v = outs[key] else { continue }
                    if let o = v as? [String: Any],
                       let imgs = o["images"] as? [[String: Any]] {
                        for im in imgs {
                            if let name = im["filename"] as? String {
                                refs.append((name,
                                             (im["subfolder"] as? String) ?? "",
                                             (im["type"] as? String) ?? "output"))
                            }
                        }
                    }
                }
                await self.finish(refs, snapshot: snapshot,
                                  seconds: Int(Date().timeIntervalSince(start)))
                return
            }
        }
        isRunning = false
        status = "等待超时；任务可能仍在服务器运行，请检查 ComfyUI 队列"
    }

    private func finish(_ refs: [(String, String, String)],
                        snapshot: (String, String, String, Int, Int, Int, Int, Int, Double, String, String, String, String),
                        seconds: Int) async {
        isSaving = true
        status = "生成完成，正在下载图片…"
        defer { isSaving = false }
        let itemID = UUID()
        let dir = archiveDir.appendingPathComponent(itemID.uuidString, isDirectory: true)
        var downloaded: [(name: String, data: Data)] = []
        do {
            guard !refs.isEmpty else { throw failure("服务器未返回图片") }
            guard let endpoint = activeEndpoint else { throw failure("任务端点不可用") }

            for (i, r) in refs.enumerated() {
                var comps = URLComponents(url: endpoint.appendingPathComponent("view"),
                                          resolvingAgainstBaseURL: false)!
                comps.queryItems = [
                    URLQueryItem(name: "filename", value: r.0),
                    URLQueryItem(name: "subfolder", value: r.1),
                    URLQueryItem(name: "type", value: r.2),
                ]
                guard let url = comps.url else { throw failure("图片地址无效") }
                var request = URLRequest(url: url)
                request.timeoutInterval = 30
                let (data, response) = try await localSession.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let img = NSImage(data: data) else { throw failure("下载图片失败") }
                let ext = URL(fileURLWithPath: r.0).pathExtension
                let name = String(format: "%02d", i + 1) + (ext.isEmpty ? "" : ".\(ext)")
                downloaded.append((name, data))
                images.append(img)
            }

            status = "图片已下载，正在保存到本软件归档…"
            let reference = snapshot.0 == "img2img" ? uploadedReference : nil
            if snapshot.0 == "img2img" && reference == nil { throw failure("参考图归档数据缺失") }
            guard !historyReadFailed else { throw failure("历史记录受保护，拒绝写入归档") }
            let filesToArchive = downloaded
            try await Task.detached {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                for image in filesToArchive {
                    try image.data.write(to: dir.appendingPathComponent(image.name), options: .atomic)
                }
                if let reference {
                    try reference.write(to: dir.appendingPathComponent("reference.png"), options: .atomic)
                }
            }.value
            let referenceFile = reference == nil ? nil : "reference.png"
            let item = HistoryItem(id: itemID, date: Date(), mode: snapshot.0,
                                   prompt: snapshot.1, negative: snapshot.2,
                                   width: snapshot.3, height: snapshot.4,
                                   steps: snapshot.5, seed: snapshot.6, batch: snapshot.7,
                                   unet: snapshot.9, clip: snapshot.10, vae: snapshot.11,
                                   strength: snapshot.8, files: downloaded.map(\.name), seconds: seconds,
                                   referenceFile: referenceFile)
            let updated = [item] + history
            try persistHistory(updated)
            history = updated
            isRunning = false
            progress = 1
            status = "完成 · \(downloaded.count) 张 · 用时 \(seconds) 秒 · 已存档"
        } catch {
            isRunning = false
            let preview = images.isEmpty ? "" : "已下载 \(images.count) 张，可在界面预览；"
            status = "\(preview)下载或存档失败：\(error.localizedDescription)；本软件归档可能不完整，请在 ComfyUI 查看输出"
        }
    }

    func cancel() {
        guard isRunning, !isSaving else { return }
        cancellationRequested = true
        status = "正在请求取消…"
    }

    private func cancelServerTask(_ id: String) async {
        // ComfyUI 的 interrupt 是全局操作，检查与调用之间存在竞争，不能安全用于共享服务。
        do {
            guard let endpoint = activeEndpoint else { throw failure("任务端点不可用") }
            var request = URLRequest(url: endpoint.appendingPathComponent("queue"))
            request.httpMethod = "POST"
            request.timeoutInterval = 10
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["delete": [id]])
            let (_, response) = try await localSession.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw failure("队列请求失败") }
            status = "已请求移除排队任务；若任务已开始，将继续运行，请在 ComfyUI 中检查"
        } catch {
            status = "取消请求失败；任务可能仍在队列或运行中，请检查 ComfyUI"
        }
    }

    func revealFolder() {
        guard !historyReadFailed else { status = "历史记录受保护，拒绝创建归档"; return }
        do {
            try FileManager.default.createDirectory(at: archiveDir, withIntermediateDirectories: true)
            guard NSWorkspace.shared.open(archiveDir) else { throw failure("Finder 未能打开归档目录") }
        } catch {
            status = "无法打开归档：\(error.localizedDescription)"
        }
    }

    // MARK: 文档 → 提示词

    /// 优先使用设置中填写的 Key；留空时兼容读取 oMLX 的 ~/.omlx/settings.json
    private func resolvedLLMKey() throws -> String {
        try migrateCredential(defaults: .standard, store: credentialStore)
        if let override = try credentialStore.read(), !override.isEmpty { return override }
        let p = NSString(string: "~/.omlx/settings.json").expandingTildeInPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: p)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let auth = obj["auth"] as? [String: Any],
              let key = auth["api_key"] as? String else { return "" }
        return key
    }

    /// 从 PDF / Word / 纯文本中抽取文本
    nonisolated private static func extractText(_ path: String) -> String? {
        let ext = (path as NSString).pathExtension.lowercased()
        if ext == "pdf" {
            guard let tool = ["/opt/homebrew/bin/pdftotext", "/usr/local/bin/pdftotext", "/usr/bin/pdftotext"]
                .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
            return runTool(tool, ["-enc", "UTF-8", "-l", "12", path, "-"])
        }
        if ext == "docx" || ext == "doc" || ext == "rtf" {
            return runTool("/usr/bin/textutil", ["-convert", "txt", "-stdout", path])
        }
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    nonisolated private static func runTool(_ launch: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launch)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func chooseDocument(_ path: String) {
        docPath = path
        docChars = 0
        documentText = ""
        generatedPrompt = ""
        isAnalyzing = false
        let request = UUID()
        documentRequest = request
        analyzeStatus = "正在后台读取文件…"
        Task {
            let raw = await Task.detached { Self.extractText(path) }.value
            guard request == self.documentRequest else { return }
            guard let raw else {
                self.analyzeStatus = "读取失败，请检查文件或 PDF 文本提取工具"
                return
            }
            let cleaned = raw.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            self.documentText = cleaned
            self.docChars = cleaned.count
            let scope = (path as NSString).pathExtension.lowercased() == "pdf" ? "（仅提取前12页）" : ""
            self.analyzeStatus = "已提取 \(cleaned.count) 字\(scope)，分析最多使用前6000字"
        }
    }

    func analyzeDocument() {
        guard !isAnalyzing else { return }
        guard !llmModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            analyzeStatus = "请填写 oMLX 模型名称"
            return
        }
        guard docChars > 0, !docPath.isEmpty else {
            analyzeStatus = "请先选择文件"
            return
        }
        #if APP_TESTING
        analyzeStatus = "测试模式禁止访问真实 oMLX"
        return
        #endif
        guard let chatBase = localEndpoint(AppSettings.llmBase) else {
            analyzeStatus = "文本服务地址无效，请在设置中检查"
            return
        }
        let chatURL = chatBase.appendingPathComponent("v1/chat/completions")
        let key: String
        do { key = try resolvedLLMKey() } catch {
            analyzeStatus = "钥匙串读取或迁移失败，旧密钥已保留"
            return
        }
        guard !key.isEmpty else {
            analyzeStatus = "找不到本地文本模型密钥；请在设置中填写"
            return
        }
        let excerpt = String(documentText.prefix(6000))
        let requestID = documentRequest

        isAnalyzing = true
        analyzeStatus = "本地模型分析中…"
        generatedPrompt = ""

        let system = """
        你是学术出版配图顾问。根据用户提供的论文内容，写一段英文图像生成提示词，\
        描述一幅能概括该研究主题的概念示意图。要求：\
        1) 尽量避免在画面中出现文字、字母、数字、公式或标签，以减少文字渲染错误；\
        2) 用物体、结构、光线、色彩来隐喻研究内容（例如"神经网络"用发光的分层网格表示）；\
        3) 指明构图、色调、材质、渲染风格（如 3D render / illustration / cinematic lighting）；\
        4) 长度控制在 60–120 个英文单词；\
        5) 只输出提示词本身，不要任何解释、标题或引号。
        """
        var user = "以下是论文内容节选：\n\n\(excerpt)"
        let h = hint.trimmingCharacters(in: .whitespacesAndNewlines)
        if !h.isEmpty { user += "\n\n额外要求（画面要体现）：\(h)" }

        var req = URLRequest(url: chatURL)
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": llmModel,
            "messages": [["role": "system", "content": system],
                         ["role": "user", "content": user]],
            "max_tokens": 900,
            "temperature": 0.7,
            "chat_template_kwargs": ["enable_thinking": false],
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        localSession.dataTask(with: req) { data, response, err in
            Task { @MainActor in
                guard self.documentRequest == requestID else { return }
                self.isAnalyzing = false
                if let err {
                    self.analyzeStatus = "请求失败：\(err.localizedDescription)"
                    return
                }
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    self.analyzeStatus = "文本服务返回 HTTP 错误"
                    return
                }
                guard let data,
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = obj["choices"] as? [[String: Any]],
                      let msg = choices.first?["message"] as? [String: Any] else {
                    self.analyzeStatus = "模型返回异常"
                    return
                }
                var text = (msg["content"] as? String) ?? ""
                if text.isEmpty, let r = msg["reasoning_content"] as? String {
                    text = r
                }
                text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    self.analyzeStatus = "模型没有返回内容"
                    return
                }
                self.generatedPrompt = text
                self.analyzeStatus = "提示词已生成（\(text.count) 字符）"
            }
        }.resume()
    }

    func useGeneratedPrompt() {
        guard !generatedPrompt.isEmpty else { return }
        prompt = generatedPrompt
        tab = 0
        status = "提示词已填入，点「生成」出图"
    }

    // MARK: 历史记录

    func loadHistory() {
        guard FileManager.default.fileExists(atPath: historyFile.path) else { return }
        do {
            let data = try Data(contentsOf: historyFile)
            history = try JSONDecoder().decode([HistoryItem].self, from: data)
            historySnapshot = data
            historyReadFailed = false
        } catch {
            historyReadFailed = true
            status = "历史记录读取失败，已保护原文件不被覆盖"
        }
    }

    private func persistHistory(_ items: [HistoryItem]) throws {
        guard !historyReadFailed else { throw failure("原历史文件读取失败，拒绝覆盖") }
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        let lockURL = supportDir.appendingPathComponent("history.lock")
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw failure("无法打开历史记录锁") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw failure("无法锁定历史记录") }
        defer { flock(fd, LOCK_UN) }

        if FileManager.default.fileExists(atPath: historyFile.path) {
            let diskData = try Data(contentsOf: historyFile)
            guard diskData == historySnapshot else {
                throw failure("历史记录已被其他窗口修改，请重启后重试；本次图片仍保存在归档文件夹")
            }
        } else if historySnapshot != nil {
            throw failure("历史记录文件已被移除，拒绝覆盖")
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        let data = try enc.encode(items)
        try data.write(to: historyFile, options: .atomic)
        historySnapshot = data
    }

    func imageURL(for item: HistoryItem, file: String) -> URL {
        archiveDir.appendingPathComponent(item.id.uuidString).appendingPathComponent(file)
    }

    func reuse(_ item: HistoryItem) {
        prompt = item.prompt
        negative = item.negative
        width = item.width
        height = item.height
        steps = item.steps
        seed = item.seed
        batch = item.batch
        strength = item.strength
        if unetList.contains(item.unet) { unet = item.unet }
        if clipList.contains(item.clip) { clip = item.clip }
        if vaeList.contains(item.vae) { vae = item.vae }
        mode = item.mode
        refImagePath = ""
        if item.mode == "img2img" {
            if let name = item.referenceFile, FileManager.default.fileExists(atPath: imageURL(for: item, file: name).path) {
                refImagePath = imageURL(for: item, file: name).path
                status = "已载入历史参数和参考图；结果可能不同"
            } else {
                status = "已载入参数，但历史记录缺少参考图，请重新选择"
            }
        } else {
            status = "已载入历史参数；结果可能不同"
        }
    }

}

// MARK: - 主界面

struct ContentView: View {
    @ObservedObject var g: Generator

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles.rectangle.stack")
                        .font(.title2).foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("ComfyDraw").font(.headline)
                        Text("创作工作台").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Circle().fill(g.backendOK ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                    Text(g.backendOK ? "引擎已连接" : (g.engineStarting ? "引擎启动中" : "引擎未连接"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 6)

                Picker("", selection: $g.tab) {
                    Text("文生图").tag(0)
                    Text("图生图").tag(1)
                    Text("文档").tag(2)
                    Text("历史").tag(3)
                    Text("设置").tag(4)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(12)

                Divider()

                if g.tab == 3 {
                    historyList
                } else if g.tab == 2 {
                    docPanel
                } else if g.tab == 4 {
                    settingsPanel
                } else {
                    controls
                }
            }
            .frame(minWidth: 320, idealWidth: 380, maxWidth: 460)
            .background(Color(nsColor: .windowBackgroundColor))

            preview.frame(minWidth: 380)
        }
        .frame(minHeight: 600)
        .onChange(of: g.tab) { _, v in
            g.mode = (v == 1) ? "img2img" : "txt2img"
            if v == 3 { g.selectedHistory = g.history.first }
            if v == 4 { g.detectEngines() }
        }
    }

    // MARK: 设置

    private var settingsPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("设置").font(.title3.weight(.semibold))
                    if g.usingLegacyDirectory { Text("使用旧目录，原位置保留").font(.caption) }
                    Text("请避免不同版本同时写入同一历史目录。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("一般无需修改。换电脑或改过安装位置时，在这里指定即可。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("绘图引擎").font(.headline)
                    Toggle("打开时自动启动本机 ComfyUI", isOn: $g.autoStartEngine)
                        .toggleStyle(.switch)
                    Text("已检测到：\(g.detectedEngines)")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        TextField("ComfyUI 目录（留空自动检测）", text: $g.engineRoot)
                            .textFieldStyle(.roundedBorder)
                        Button("选择…") { g.chooseEngineFolder() }
                            .controlSize(.small)
                    }
                    Button("重新检测") { g.detectEngines() }
                        .buttonStyle(.link).font(.caption)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("后端地址").font(.headline)
                    TextField("http://127.0.0.1:8188", text: $g.backendBase)
                        .textFieldStyle(.roundedBorder)
                    Text("仅支持本机回环地址。若 ComfyUI 使用其他本机端口，可在此修改端口。")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("文档分析（可选）").font(.headline)
                    TextField("http://127.0.0.1:8000", text: $g.llmBase)
                        .textFieldStyle(.roundedBorder)
                    SecureField("API Key（留空则读取 ~/.omlx/settings.json）", text: $g.llmKey)
                        .textFieldStyle(.roundedBorder)
                    Button("删除已保存的 Key") {
                        let alert = NSAlert()
                        alert.messageText = "删除已保存的 Key？"
                        alert.informativeText = "将删除钥匙串及旧偏好设置中的手动 Key，不会删除 oMLX 配置。"
                        alert.addButton(withTitle: "删除")
                        alert.addButton(withTitle: "取消")
                        if alert.runModal() == .alertFirstButtonReturn { g.deleteStoredKey() }
                    }
                    .disabled(g.isAnalyzing)
                    Text("Key 保存在系统钥匙串；留空沿用已存 Key，未设置时读取本机 oMLX 配置。")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button("保存并重连") { g.saveSettings() }
                    .disabled(g.isAnalyzing || g.isRunning || g.engineStarting)
                    .buttonStyle(.borderedProminent)

                if !g.settingsMessage.isEmpty {
                    Text(g.settingsMessage)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("ComfyDraw 是非官方第三方前端，与 ComfyUI 官方无隶属关系。")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }
            .padding(18)
        }
    }

    // MARK: 控制面板

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(g.tab == 0 ? "文字创作" : "参考图创作").font(.title3.weight(.semibold))
                    Text(g.tab == 0 ? "描述你想要的画面，然后开始生成。" : "选择一张图片，再描述希望如何调整。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !g.backendOK {
                    Label(g.engineStarting ? "正在后台启动本地绘图引擎，请稍候。" : "本地引擎未连接，可点击下方“重试连接与启动”。", systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if g.tab == 1 { referencePicker }

                Group {
                    Text("提示词").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $g.prompt)
                        .font(.body)
                        .frame(height: 92)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))

                    Text("当前 CFG=1，反向提示词不起作用，已禁用。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("模型设置").font(.headline)
                    Text("当前工作流面向 Qwen Image 的 GGUF 组合；图生图为参考图重绘，不等同于指令式图片编辑。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if g.unetList.isEmpty || g.clipList.isEmpty || g.vaeList.isEmpty {
                        Text("模型列表尚未加载，请检查后端及模型配置，然后刷新。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if !g.modelLooksQwen {
                        Label("当前工作流面向 Qwen Image，所选模型可能无法正常生成。",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Text("图像模型").font(.caption2).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                        Picker("", selection: $g.unet) {
                            ForEach(g.unetList, id: \.self) { Text(shortName($0)).tag($0) }
                        }.labelsHidden()
                    }
                    HStack {
                        Text("文本编码").font(.caption2).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                        Picker("", selection: $g.clip) {
                            ForEach(g.clipList, id: \.self) { Text(shortName($0)).tag($0) }
                        }.labelsHidden()
                    }
                    HStack {
                        Text("VAE").font(.caption2).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                        Picker("", selection: $g.vae) {
                            ForEach(g.vaeList, id: \.self) { Text(shortName($0)).tag($0) }
                        }.labelsHidden()
                    }
                }

                Divider()

                if g.tab == 0 {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("宽度").font(.caption).foregroundStyle(.secondary)
                            Picker("", selection: $g.width) {
                                ForEach([512, 768, 1024, 1280, 1536], id: \.self) { Text("\($0)").tag($0) }
                            }.labelsHidden()
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("高度").font(.caption).foregroundStyle(.secondary)
                            Picker("", selection: $g.height) {
                                ForEach([512, 768, 1024, 1280, 1536], id: \.self) { Text("\($0)").tag($0) }
                            }.labelsHidden()
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("数量").font(.caption).foregroundStyle(.secondary)
                            Picker("", selection: $g.batch) {
                                ForEach(1...4, id: \.self) { Text("\($0) 张").tag($0) }
                            }.labelsHidden()
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("修改强度").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text(String(format: "%.2f", g.strength)).font(.caption.monospacedDigit())
                        }
                        Slider(value: $g.strength, in: 0.2...0.95, step: 0.05)
                        Text("越低越接近原图，越高越听从提示词")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("步数").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(g.steps)").font(.caption.monospacedDigit())
                    }
                    Slider(value: Binding(get: { Double(g.steps) },
                                          set: { g.steps = Int($0) }), in: 4...40, step: 1)
                }

                HStack {
                    Text("种子").font(.caption).foregroundStyle(.secondary)
                    TextField("42", value: $g.seed, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                    Button("随机") { g.seed = Int.random(in: 1...999_999_999) }
                        .buttonStyle(.link)
                }

                Divider()

                if g.isRunning {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        HStack {
                            Text(g.status).font(.caption).lineLimit(2)
                            Spacer()
                            if !g.isSaving {
                                Button("取消") { g.cancel() }.controlSize(.small)
                            }
                        }
                    }
                } else {
                    Button { g.generate() } label: {
                        Label(g.tab == 0 ? "生成 \(g.batch) 张" : "按参考图生成",
                              systemImage: "sparkles")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!g.backendOK || g.engineStarting)
                }

                if !g.isRunning {
                    Text(g.status).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 12) {
                    Button("打开本软件归档") { g.revealFolder() }.buttonStyle(.link).font(.caption)
                    Button(g.backendOK ? "刷新连接与模型" : "重试连接与启动") { g.refresh() }
                        .buttonStyle(.link).font(.caption).disabled(g.engineStarting)
                }

                Spacer(minLength: 0)
            }
            .padding(18)
        }
    }

    private var referencePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("参考图").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                if let p = referenceURL, let img = NSImage(contentsOf: p) {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.12))
                        .frame(width: 64, height: 64)
                        .overlay(Image(systemName: "photo").foregroundStyle(.tertiary))
                }
                Button("选择图片…") { chooseReference() }
                if !g.refImagePath.isEmpty {
                    Button("清除") { g.refImagePath = "" }.buttonStyle(.link)
                }
            }
        }
    }

    private var referenceURL: URL? {
        g.refImagePath.isEmpty ? nil : URL(fileURLWithPath: g.refImagePath)
    }

    private func chooseReference() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .image]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            g.refImagePath = url.path
        }
    }

    // MARK: 文档面板

    private var docPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("文档转提示词").font(.title3.weight(.semibold))
                Text("选择论文或资料，由本地模型根据文本节选编写绘图提示词。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("PDF 最多提取前 12 页；分析使用提取文本的前 6000 个字符。扫描版文件暂不支持 OCR。PDF 提取需要安装 pdftotext，本地分析需要 oMLX 服务和模型。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button("选择文件…") { chooseDocument() }
                    if !g.docPath.isEmpty {
                        Text((g.docPath as NSString).lastPathComponent)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }

                if g.docChars > 0 {
                    Text("已提取 \(g.docChars) 字")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("oMLX 模型名称").font(.caption).foregroundStyle(.secondary)
                    TextField("填写 oMLX 中的模型名称", text: $g.llmModel)
                        .textFieldStyle(.roundedBorder)
                    Text("需要与 oMLX 中的模型名称一致。文档节选会发送给本机 oMLX 服务。")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("画面要体现什么（可选）").font(.caption).foregroundStyle(.secondary)
                    TextField("例如：突出多尺度特征融合", text: $g.hint)
                        .textFieldStyle(.roundedBorder)
                }

                Button {
                    g.analyzeDocument()
                } label: {
                    Label(g.isAnalyzing ? "分析中…" : "分析并生成提示词",
                          systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(g.isAnalyzing || g.docChars == 0)

                if g.isAnalyzing { ProgressView().controlSize(.small) }

                Text(g.analyzeStatus)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(3)

                if !g.generatedPrompt.isEmpty {
                    Divider()
                    Text("生成的提示词").font(.caption).foregroundStyle(.secondary)
                    Text(g.generatedPrompt)
                        .font(.caption)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8)
                            .fill(Color(nsColor: .textBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.25)))

                    HStack(spacing: 10) {
                        Button("填入绘图提示词") { g.useGeneratedPrompt() }
                            .buttonStyle(.borderedProminent)
                        Button("复制") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(g.generatedPrompt, forType: .string)
                        }
                        .buttonStyle(.link)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(18)
        }
    }

    private func chooseDocument() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .plainText, .rtf]
        if let docx = UTType(filenameExtension: "docx"), let doc = UTType(filenameExtension: "doc") {
            panel.allowedContentTypes += [docx, doc]
        }
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            g.chooseDocument(url.path)
        }
    }

    // MARK: 历史列表

    private var historyList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                if g.history.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath").font(.title2).foregroundStyle(.tertiary)
                        Text("还没有生成记录").font(.headline)
                        Text("成功保存的图片会出现在这里。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(.top, 48)
                }
                ForEach(g.history) { item in
                    Button {
                        g.selectedHistory = item
                    } label: {
                        HStack(spacing: 10) {
                            if let name = item.files.first,
                               let img = NSImage(contentsOf: g.imageURL(for: item, file: name)) {
                                Image(nsImage: img)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 52, height: 52)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.prompt).font(.caption).lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                Text("\(item.files.count) 张 · \(stamp(item.date)) · \(item.seconds)s")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(g.selectedHistory?.id == item.id
                                      ? Color.accentColor.opacity(0.12)
                                      : Color.secondary.opacity(0.06))
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("复用参数") {
                            g.reuse(item)
                            g.tab = item.mode == "img2img" ? 1 : 0
                        }
                    }
                }
            }
            .padding(12)
        }
    }

    private func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: d)
    }

    // MARK: 预览区

    private var preview: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)
            if g.tab == 3 {
                historyDetail
            } else if g.tab == 2 {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 54)).foregroundStyle(.tertiary)
                    Text(g.generatedPrompt.isEmpty
                         ? "从文档节选开始创作"
                         : "提示词已生成")
                        .font(.headline)
                    Text(g.generatedPrompt.isEmpty
                         ? "在左侧选择文件，添加画面要求并开始分析。"
                         : "在左侧点击“填入绘图提示词”，检查后即可生成。")
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            } else if !g.images.isEmpty {
                ScrollView {
                    LazyVGrid(columns: gridColumns(g.images.count), spacing: 10) {
                        ForEach(Array(g.images.enumerated()), id: \.offset) { _, img in
                            Image(nsImage: img)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                        }
                    }
                    .padding(16)
                }
            } else if g.isRunning {
                VStack(spacing: 14) {
                    ProgressView().controlSize(.large)
                    Text(g.status).foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "photo.artframe")
                        .font(.system(size: 56)).foregroundStyle(.tertiary)
                    Text(g.backendOK ? "你的画布已准备好" : "连接绘图后端")
                        .font(.headline)
                    Text(g.backendOK ? "在左侧输入画面描述，生成的图片会显示在这里。" : (g.engineStarting ? "正在启动本地绘图引擎，请稍候。" : "本地引擎未连接，请查看左侧状态或重试。"))
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }
            }
        }
    }

    @ViewBuilder
    private var historyDetail: some View {
        if let item = g.selectedHistory {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    LazyVGrid(columns: gridColumns(item.files.count), spacing: 10) {
                        ForEach(item.files, id: \.self) { f in
                            if let img = NSImage(contentsOf: g.imageURL(for: item, file: f)) {
                                Image(nsImage: img)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.prompt).font(.callout)
                        Text((item.mode == "img2img" ? "参考图尺寸" : "\(item.width)×\(item.height)")
                             + " · \(item.steps) 步 · 种子 \(item.seed)"
                             + " · \(shortName(item.unet))"
                             + (item.mode == "img2img" ? " · 强度 \(String(format: "%.2f", item.strength))" : ""))
                            .font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            Button("复用这些参数") {
                                g.reuse(item)
                                g.tab = item.mode == "img2img" ? 1 : 0
                            }
                                .buttonStyle(.borderedProminent)
                            Button("在 Finder 中显示") {
                                NSWorkspace.shared
                                    .selectFile(nil, inFileViewerRootedAtPath:
                                        g.archiveDir.appendingPathComponent(item.id.uuidString).path)
                            }
                            .buttonStyle(.link)
                        }
                    }
                }
                .padding(20)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 52)).foregroundStyle(.tertiary)
                Text("左侧选一条记录查看").foregroundStyle(.secondary)
            }
        }
    }

    private func gridColumns(_ n: Int) -> [GridItem] {
        n > 1 ? [GridItem(.adaptive(minimum: 220), spacing: 10)] : [GridItem(.flexible())]
    }

    private func shortName(_ s: String) -> String {
        s.replacingOccurrences(of: "qwen-image-2.1-UC-", with: "")
         .replacingOccurrences(of: "qwen3vl_8b_", with: "")
         .replacingOccurrences(of: "qwen_image_2.1_vae_", with: "vae ")
         .replacingOccurrences(of: ".safetensors", with: "")
         .replacingOccurrences(of: ".gguf", with: "")
    }
}

// MARK: - 入口

#if !APP_TESTING
@main
struct ComfyDrawApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var generator = Generator()
    var body: some Scene {
        WindowGroup("ComfyDraw") { ContentView(g: generator) }
            .windowResizability(.contentMinSize)
            .commands { CommandGroup(replacing: .newItem) {} }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard LocalEngine.shared.activeGenerations > 0 else { return .terminateNow }
        Task { @MainActor in
            do {
                let alert = NSAlert()
                alert.messageText = "绘图任务或保存可能仍在进行"
                alert.informativeText = "退出将停止本软件等待和归档；绘图引擎会暂时留在后台，未完成的图片可在 ComfyUI 输出文件夹中查找。"
                alert.addButton(withTitle: "退出并保留引擎")
                alert.addButton(withTitle: "取消退出")
                if alert.runModal() != .alertFirstButtonReturn {
                    sender.reply(toApplicationShouldTerminate: false)
                    return
                }
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
#endif
