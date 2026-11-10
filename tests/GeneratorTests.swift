import Foundation
import AppKit

final class MemoryDefaults: UserDefaults {
    var values: [String: String] = [:]
    override func string(forKey defaultName: String) -> String? { values[defaultName] }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value as? String }
    override func removeObject(forKey defaultName: String) { values.removeValue(forKey: defaultName) }
}

final class MockCredentials: CredentialStore {
    var value: String?
    var failWrite = false
    var failRead = false
    var writes = 0
    func read() throws -> String? {
        if failRead { throw NSError(domain: "mock", code: 2) }
        return value
    }
    func write(_ value: String) throws {
        writes += 1
        if failWrite { throw NSError(domain: "mock", code: 1) }
        self.value = value
    }
    func delete() throws { value = nil }
}

@main
struct GeneratorTests {
    @MainActor static func main() async {
        let scenario = CommandLine.arguments[1]
        let invalid = ["https://127.0.0.1:8188", "http://example.com", "http://127.0.0.1:0", "http://127.0.0.1:65536", "http://127.0.0.1:", "http://127.0.0.1/x", "http://127.0.0.1/%2f", "http://u@127.0.0.1", "http://127.0.0.1?x=1", "http://127.0.0.1#x"]
        guard invalid.allSatisfy({ localEndpoint($0) == nil }),
              localEndpoint("http://localhost:8188/")?.absoluteString == "http://127.0.0.1:8188" else { exit(20) }
        let defaults = MemoryDefaults()
        let store = MockCredentials()
        defaults.set("test-value", forKey: AppSettings.llmKeyKey)
        store.failWrite = true
        do { try migrateCredential(defaults: defaults, store: store); exit(21) } catch {}
        guard defaults.string(forKey: AppSettings.llmKeyKey) == "test-value" else { exit(22) }
        store.failWrite = false
        do { try migrateCredential(defaults: defaults, store: store) } catch { exit(23) }
        guard store.value == "test-value", defaults.string(forKey: AppSettings.llmKeyKey) == nil else { exit(24) }
        let oldWrites = store.writes
        do { try saveCredential("different", store: store); exit(25) } catch {}
        guard store.value == "test-value", store.writes == oldWrites else { exit(26) }
        store.failRead = true
        do { try saveCredential("different", store: store); exit(27) } catch {}
        guard store.value == "test-value", store.writes == oldWrites else { exit(28) }
        store.failRead = false
        do { try saveCredential("test-value", store: store) } catch { exit(29) }
        guard store.writes == oldWrites else { exit(30) }
        let emptyStore = MockCredentials()
        emptyStore.failWrite = true
        do { try saveCredential("new", store: emptyStore); exit(31) } catch {}
        guard emptyStore.value == nil else { exit(32) }
        let g = Generator()
        let readyDeadline = Date().addingTimeInterval(8)
        while !(g.backendOK && g.unetList.contains(g.unet) && g.clipList.contains(g.clip) && g.vaeList.contains(g.vae)) && Date() < readyDeadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        guard g.backendOK && g.unetList.contains(g.unet) && g.clipList.contains(g.clip) && g.vaeList.contains(g.vae) else {
            print("模拟后端初始化失败: \(g.status)")
            exit(13)
        }
        g.prompt = "isolation test"
        g.width = 512
        g.height = 768
        g.batch = 2
        if scenario == "img2img" {
            g.mode = "img2img"
            g.refImagePath = URL(fileURLWithPath: ProcessInfo.processInfo.environment["APP_DATA_DIR"]!).appendingPathComponent("input.png").path
        }
        g.generate()
        guard let alternate = ProcessInfo.processInfo.environment["ALT_BASE_URL"],
              let endpoint = localEndpoint(alternate), endpoint != g.configuredURL else { exit(36) }
        g.configuredURL = endpoint
        guard g.configuredURL == endpoint else { exit(37) }
        g.refresh()
        g.backendBase = "http://127.0.0.1:1"
        if scenario == "cancel" {
            try? await Task.sleep(nanoseconds: 500_000_000)
            g.cancel()
        }
        if ["image_cancel", "history_cancel", "history_failure_cancel", "queue_cancel"].contains(scenario) {
            let marker = URL(fileURLWithPath: ProcessInfo.processInfo.environment["APP_DATA_DIR"]!).appendingPathComponent("request-marker")
            let deadline = Date().addingTimeInterval(8)
            while !FileManager.default.fileExists(atPath: marker.path) && Date() < deadline {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            guard FileManager.default.fileExists(atPath: marker.path) else { print("请求未到达"); exit(10) }
            if scenario == "image_cancel" {
                guard g.isSaving && g.isRunning && g.status == "生成完成，正在下载图片…" else { exit(11) }
                g.cancel()
                guard g.isSaving && g.isRunning && g.status == "生成完成，正在下载图片…" else { exit(12) }
            } else {
                g.cancel()
            }
        }
        if scenario == "queue_stall" {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            g.cancel()
            try? await Task.sleep(nanoseconds: 11_000_000_000)
            print("STALL running=\(g.isRunning) status=\(g.status)")
            exit(g.isRunning ? 3 : 0)
        }
        let deadline = Date().addingTimeInterval(15)
        while g.isRunning && Date() < deadline { try? await Task.sleep(nanoseconds: 100_000_000) }
        if scenario == "history_conflict" {
            guard !g.isRunning, g.history.count == 1 else { exit(33) }
            do {
                let original = try Data(contentsOf: g.historyFile)
                var items = try JSONSerialization.jsonObject(with: original) as! [[String: Any]]
                items[0]["prompt"] = "external change"
                let changed = try JSONSerialization.data(withJSONObject: items)
                try changed.write(to: g.historyFile)
                g.configuredURL = localEndpoint(ProcessInfo.processInfo.environment["COMFYUI_BASE_URL"]!)
                g.generate()
                let retryDeadline = Date().addingTimeInterval(15)
                while g.isRunning && Date() < retryDeadline { try? await Task.sleep(nanoseconds: 100_000_000) }
                guard !g.isRunning, g.status.contains("历史记录已被其他窗口修改"), try Data(contentsOf: g.historyFile) == changed else { exit(34) }
            } catch { exit(35) }
            exit(0)
        }
        print("RESULT scenario=\(scenario) running=\(g.isRunning) history=\(g.history.count) images=\(g.images.count) status=\(g.status)")
        guard !g.isRunning else { exit(2) }
        if ["success", "image_cancel", "img2img"].contains(scenario) {
            guard g.history.count == 1, g.images.count == 1, g.status.contains("已存档"), let item = g.history.first,
                  item.prompt == "isolation test", item.width == 512, item.height == 768, item.batch == 2,
                  let file = item.files.first, FileManager.default.fileExists(atPath: g.imageURL(for: item, file: file).path),
                  let bytes = try? Data(contentsOf: g.historyFile),
                  let decoded = try? JSONDecoder().decode([HistoryItem].self, from: bytes), decoded.count == 1 else { exit(4) }
            if scenario == "img2img" {
                guard item.mode == "img2img", let ref = item.referenceFile,
                      let data = try? Data(contentsOf: g.imageURL(for: item, file: ref)),
                      data.starts(with: [137,80,78,71,13,10,26,10]), NSImage(data: data) != nil else { exit(14) }
            }
        } else if ["cancel", "history_cancel", "history_failure_cancel", "queue_cancel"].contains(scenario) {
            guard g.history.isEmpty, g.images.isEmpty, !g.isSaving, g.status.contains("移除排队任务") else { exit(5) }
        } else {
            guard g.history.isEmpty, !g.status.contains("已存档") else { exit(6) }
            if scenario == "save_error" && (g.images.count != 1 || !g.status.contains("可在界面预览")) { exit(15) }
            if scenario == "fail_history" && !g.status.contains("停止等待") { exit(7) }
            if ["bad_image", "corrupt", "save_error"].contains(scenario) && !g.status.contains("存档失败") { exit(8) }
        }
    }
}
