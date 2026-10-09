import AppKit
import SwiftUI
import ServiceManagement

final class SoundStore: ObservableObject {
    @Published var events: [SoundEvent] = []
    @Published var monitoring = true
    @Published var status = "Подключаюсь к аудио macOS…"
    @Published var processCount = 0
    @Published var confirmed = false
    @Published var issue = ""
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    let engine = AudioEngine()
    private let io = DispatchQueue(label: "com.g2.beepsource.history", qos: .utility)
    private var timer: Timer?
    private var dirty = false
    private var historyWritable = true
    private var observers: [NSObjectProtocol] = []
    let historyURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        historyURL = support.appendingPathComponent("Beep Source/history.json")
        do {
            if FileManager.default.fileExists(atPath: historyURL.path) {
                events = try JSONDecoder().decode([SoundEvent].self, from: Data(contentsOf: historyURL))
                for i in events.indices { events[i].active = false }
                prune()
            }
        } catch {
            // Preserve unreadable history rather than overwriting the only copy.
            let backup = historyURL.deletingLastPathComponent().appendingPathComponent("history-unreadable-\(Int(Date().timeIntervalSince1970)).json")
            do { try FileManager.default.moveItem(at: historyURL, to: backup) }
            catch { historyWritable = false; issue = "История не читается. Исходный файл сохранён; автоматическая запись отключена." }
            if issue.isEmpty { issue = "Не удалось прочитать прежнюю историю. Её копия сохранена рядом с журналом." }
        }
        engine.onEvents = { [weak self] changes in
            guard let self else { return }
            var inserted = false
            for event in changes {
                if let index = self.events.firstIndex(where: { $0.id == event.id }) { self.events[index] = event }
                else { self.events.insert(event, at: 0); inserted = true }
            }
            if inserted { self.events.sort { $0.start > $1.start } }
            self.prune(); self.dirty = true
        }
        engine.onStatus = { [weak self] message, count, confirmed in
            self?.status = message; self?.processCount = count; self?.confirmed = confirmed
        }
        engine.onIssue = { [weak self] in self?.issue = $0 }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.save() }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.engine.stop() })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.monitoring else { return }; self.engine.start()
        })
        engine.start()
    }
    private func prune() {
        let cutoff = Date().addingTimeInterval(-30 * 86400)
        events = Array(events.filter { $0.end >= cutoff || $0.active }.prefix(5000))
    }
    func toggleMonitoring() {
        monitoring.toggle(); issue = ""
        if monitoring { engine.start() } else { engine.stop() }
    }
    func restart() { issue = ""; monitoring = true; engine.restart() }
    func clear() {
        let alert = NSAlert()
        alert.messageText = "Очистить историю звуков?"
        alert.informativeText = "Все сохранённые события будут удалены. Наблюдение продолжится."
        alert.addButton(withTitle: "Отмена"); alert.addButton(withTitle: "Очистить")
        if alert.runModal() == .alertSecondButtonReturn {
            // Stop/drain first so an existing live sound cannot repopulate old events.
            let wasMonitoring = monitoring
            engine.stop {
                self.events.removeAll(); self.dirty = true; self.save()
                if wasMonitoring { self.engine.start() }
            }
        }
    }
    func save(wait: Bool = false) {
        guard dirty, historyWritable else { if wait { io.sync {} }; return }
        let snapshot = events, url = historyURL
        dirty = false
        let write = {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.issue = "Не удалось сохранить историю: \(error.localizedDescription)"; self?.dirty = true
                }
            }
        }
        if wait { io.sync(execute: write) } else { io.async(execute: write) }
    }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            if SMAppService.mainApp.status == .requiresApproval {
                issue = "Разрешите запуск Beep Source в настройках macOS → Основные → Объекты входа."
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch { issue = "Не удалось изменить автозапуск: \(error.localizedDescription)" }
    }
    func openPermissions() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
    func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Beep Source.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        func quote(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let date = ISO8601DateFormatter()
        let lines = events.map { e in
            [quote(date.string(from: e.start)), quote(e.source.name), quote(e.source.process), String(e.source.pid),
             String(format: "%.3f", e.duration), String(format: "%.1f", e.decibels), quote(e.source.bundleID)].joined(separator: ",")
        }
        do { try ("Время,Приложение,Процесс,PID,Длительность (сек),Пик (dBFS),Bundle ID\n" + lines.joined(separator: "\n")).write(to: url, atomically: true, encoding: .utf8) }
        catch { issue = "Экспорт не удался: \(error.localizedDescription)" }
    }
}
