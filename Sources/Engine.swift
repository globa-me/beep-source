import AppKit
import CoreAudio

private func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
}
private func processIDs() -> [AudioObjectID]? {
    var a = address(kAudioHardwarePropertyProcessObjectList)
    var bytes: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &bytes) == noErr else { return nil }
    guard bytes > 0 else { return [] }
    var values = [AudioObjectID](repeating: 0, count: Int(bytes) / MemoryLayout<AudioObjectID>.size)
    let status = values.withUnsafeMutableBytes { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &bytes, $0.baseAddress!) }
    return status == noErr ? Array(values.prefix(Int(bytes) / MemoryLayout<AudioObjectID>.size)) : nil
}
private func processPID(_ id: AudioObjectID) -> Int32? {
    var a = address(kAudioProcessPropertyPID), pid: Int32 = 0
    var bytes = UInt32(MemoryLayout<Int32>.size)
    return AudioObjectGetPropertyData(id, &a, 0, nil, &bytes, &pid) == noErr ? pid : nil
}
private func bundleID(_ id: AudioObjectID) -> String {
    var a = address(kAudioProcessPropertyBundleID)
    var value: Unmanaged<CFString>?
    var bytes = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &a, 0, nil, &bytes, $0) }
    guard status == noErr else { return "" }
    return value?.takeRetainedValue() as String? ?? ""
}
private func sourceFor(_ id: AudioObjectID, pid: Int32) -> SoundSource {
    var buffer = [CChar](repeating: 0, count: 4096)
    let size = UInt32(buffer.count)
    let n = BSProcessPath(pid, &buffer, size)
    let path = n > 0 ? String(cString: buffer) : ""
    let app = NSRunningApplication(processIdentifier: pid)
    var appPath = app?.bundleURL?.path ?? ""
    if appPath.isEmpty, let range = path.range(of: ".app/") { appPath = String(path[..<range.lowerBound]) + ".app" }
    let bundle = appPath.isEmpty ? nil : Bundle(path: appPath)
    let process = path.isEmpty ? "Процесс \(pid)" : URL(fileURLWithPath: path).lastPathComponent
    let name = app?.localizedName ?? (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
        ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
        ?? (appPath.isEmpty ? process : URL(fileURLWithPath: appPath).deletingPathExtension().lastPathComponent)
    return SoundSource(name: name, process: process, pid: pid, bundleID: bundleID(id), appPath: appPath)
}

private final class ProcessMeter {
    let pointer: OpaquePointer
    let source: SoundSource
    var grouper = EventGrouper()
    var dropped: UInt64 = 0
    init(pointer: OpaquePointer, source: SoundSource) { self.pointer = pointer; self.source = source }
    deinit { BSMonitorDestroy(pointer) }
}

final class AudioEngine {
    private let queue = DispatchQueue(label: "com.g2.beepsource.monitor", qos: .utility)
    private var meters: [AudioObjectID: ProcessMeter] = [:]
    private var global: ProcessMeter?
    private var pendingGlobal: [SoundEvent] = []
    private var knownIntervals: [SoundEvent] = []
    private var frames = [BSFrame](repeating: BSFrame(), count: 2048)
    private var timer: DispatchSourceTimer?
    private var listener: AudioObjectPropertyListenerBlock?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var pendingDeviceRestart: DispatchWorkItem?
    private var enabled = false
    private var lastReconcile = 0.0
    private var reportedError = ""
    private var retries: [AudioObjectID: (attempts: Int, next: Double)] = [:]
    private var seenAudio = false
    var onEvents: (([SoundEvent]) -> Void)?
    var onStatus: ((String, Int, Bool) -> Void)?
    var onIssue: ((String) -> Void)?

    func start() { queue.async { self.startOnQueue() } }
    func stop(completion: (() -> Void)? = nil) {
        queue.async {
            self.enabled = false
            self.timer?.cancel(); self.timer = nil
            if let listener = self.listener {
                var a = address(kAudioHardwarePropertyProcessObjectList)
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, self.queue, listener)
            }
            self.listener = nil
            self.pendingDeviceRestart?.cancel(); self.pendingDeviceRestart = nil
            if let block = self.deviceListener {
                for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice] {
                    var a = address(selector)
                    AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, self.queue, block)
                }
            }
            self.deviceListener = nil
            for meter in self.meters.values { BSMonitorStop(meter.pointer) }
            if let global = self.global { BSMonitorStop(global.pointer) }
            self.drain(force: true)
            self.meters.removeAll()
            self.global = nil
            self.retries.removeAll()
            self.publishStatus("Наблюдение на паузе")
            if let completion { DispatchQueue.main.async(execute: completion) }
        }
    }
    func restart() { stop { self.start() } }
    private func startOnQueue() {
        guard !enabled else { return }
        enabled = true
        seenAudio = false
        reportedError = ""
        var error: Int32 = 0
        if let pointer = BSMonitorCreate(0, &error) {
            global = ProcessMeter(pointer: pointer, source: .unknown)
        } else { issue("Не удалось подключить общий выход: Core Audio \(error). Проверьте разрешение на системное аудио.") }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.reconcile() }
        listener = block
        var a = address(kAudioHardwarePropertyProcessObjectList)
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, queue, block)
        if status != noErr { issue("Не удалось подписаться на новые процессы: \(status). Используется периодическая проверка.") }
        let devices: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.enabled else { return }
            self.pendingDeviceRestart?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.restart() }
            self.pendingDeviceRestart = work
            self.queue.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
        deviceListener = devices
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice] {
            var a = address(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, queue, devices)
        }
        reconcile()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(180), leeway: .milliseconds(30))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.drain()
            if BSHostTime() - self.lastReconcile > 3 { self.reconcile() }
        }
        self.timer = timer; timer.resume()
    }
    private func reconcile() {
        guard enabled else { return }
        lastReconcile = BSHostTime()
        guard let ids = processIDs() else {
            issue("macOS не вернула список аудиопроцессов. Попробуйте перезапустить наблюдение.")
            return
        }
        let valid = Set(ids.filter { processPID($0) != ProcessInfo.processInfo.processIdentifier })
        retries = retries.filter { valid.contains($0.key) }
        for id in Array(meters.keys) where !valid.contains(id) || processPID(id) != meters[id]?.source.pid {
            if let meter = meters[id] {
                BSMonitorStop(meter.pointer)
                drainMeter(meter, force: true)
            }
            meters.removeValue(forKey: id)
        }
        for id in valid where meters[id] == nil {
            if let retry = retries[id], BSHostTime() < retry.next { continue }
            guard let pid = processPID(id), pid > 0 else { continue }
            var error: Int32 = 0
            if let pointer = BSMonitorCreate(id, &error) {
                meters[id] = ProcessMeter(pointer: pointer, source: sourceFor(id, pid: pid))
                retries.removeValue(forKey: id)
            } else {
                let attempts = (retries[id]?.attempts ?? 0) + 1
                retries[id] = (attempts, BSHostTime() + min(60, 3 * pow(2, Double(min(attempts, 5)))))
                issue("Не удалось наблюдать процесс \(pid): Core Audio \(error). Проверьте разрешение на системное аудио.")
            }
        }
        publishStatus(enabled ? (seenAudio ? "Звуки обнаруживаются" : "Ожидаю звук") : "Наблюдение на паузе")
    }
    private func drain(force: Bool = false) {
        for meter in meters.values { drainMeter(meter, force: force) }
        if let global { drainMeter(global, force: force, isGlobal: true) }
        let cutoff = Date().addingTimeInterval(-0.6)
        var emitted: [SoundEvent] = []
        pendingGlobal.removeAll { event in
            guard force || event.end < cutoff else { return false }
            let overlaps = knownIntervals.contains { known in
                known.start <= event.end.addingTimeInterval(0.05) && known.end >= event.start.addingTimeInterval(-0.05)
            }
            if !overlaps { emitted.append(event) }
            return true
        }
        if !emitted.isEmpty { DispatchQueue.main.async { [weak self] in self?.onEvents?(emitted) } }
        // Keep overlap evidence through long global events, but bound memory.
        if global?.grouper.current == nil && pendingGlobal.isEmpty { knownIntervals.removeAll { $0.end < Date().addingTimeInterval(-10) } }
        if knownIntervals.count > 10000 { knownIntervals.removeFirst(knownIntervals.count - 10000) }
    }
    private func drainMeter(_ meter: ProcessMeter, force: Bool, isGlobal: Bool = false) {
        let count = BSMonitorDrain(meter.pointer, &frames, Int32(frames.count))
        let hostNow = BSHostTime(), dateNow = Date()
        var changed: [SoundEvent] = []
        for frame in frames.prefix(Int(count)) {
            let start = dateNow.addingTimeInterval(frame.start - hostNow)
            let end = dateNow.addingTimeInterval(frame.end - hostNow)
            changed += meter.grouper.consume(start: start, end: end, peak: frame.peak, source: meter.source)
        }
        if count > 0 {
            if !seenAudio { seenAudio = true; publishStatus("Звуки обнаруживаются") }
            if !isGlobal, let active = meter.grouper.current { changed.append(active) }
        }
        if let finished = meter.grouper.finishIfSilent(at: dateNow, force: force) { changed.append(finished) }
        let dropped = BSMonitorDropped(meter.pointer)
        if dropped > meter.dropped { meter.dropped = dropped; issue("Обработка задержалась: часть звуковых данных пропущена. Журнал может быть неполным.") }
        if isGlobal { pendingGlobal += changed }
        else if !changed.isEmpty {
            for event in changed {
                if let index = knownIntervals.firstIndex(where: { $0.id == event.id }) { knownIntervals[index] = event }
                else { knownIntervals.append(event) }
            }
            DispatchQueue.main.async { [weak self] in self?.onEvents?(changed) }
        }
    }
    private func publishStatus(_ status: String) {
        let count = meters.count, confirmed = seenAudio
        DispatchQueue.main.async { [weak self] in self?.onStatus?(status, count, confirmed) }
    }
    private func issue(_ message: String) {
        guard message != reportedError else { return }; reportedError = message
        DispatchQueue.main.async { [weak self] in self?.onIssue?(message) }
    }
}
