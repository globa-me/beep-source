import Foundation

struct SoundSource: Codable, Equatable {
    var name: String
    var process: String
    var pid: Int32
    var bundleID: String
    var appPath: String
    static let unknown = SoundSource(name: "Источник не определён", process: "Общий звуковой выход", pid: 0, bundleID: "", appPath: "")
}
struct SoundEvent: Codable, Identifiable, Equatable {
    var id = UUID()
    var source: SoundSource
    var start: Date
    var end: Date
    var peak: Float
    var active: Bool
    var duration: Double { max(0.001, end.timeIntervalSince(start)) }
    var decibels: Double { 20 * log10(Double(max(peak, 0.000001))) }
}

// Pure event grouping, independent of HAL or UI. Silence confirms the end but
// does not inflate the measured duration. Keep even a single-sample click.
struct EventGrouper {
    var current: SoundEvent?
    let gap: Double = 0.22
    mutating func consume(start: Date, end: Date, peak: Float, source: SoundSource) -> [SoundEvent] {
        var finished: [SoundEvent] = []
        if let event = current, start.timeIntervalSince(event.end) > gap {
            var closed = event; closed.active = false; finished.append(closed); current = nil
        }
        if current == nil {
            current = SoundEvent(source: source, start: start, end: end, peak: peak, active: true)
        } else if var event = current {
            event.end = max(event.end, end)
            event.peak = max(event.peak, peak)
            current = event
        }
        return finished
    }
    mutating func finishIfSilent(at now: Date, force: Bool = false) -> SoundEvent? {
        guard var event = current, force || now.timeIntervalSince(event.end) > gap else { return nil }
        event.active = false; current = nil; return event
    }
}
