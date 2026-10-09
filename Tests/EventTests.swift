import Foundation

@main struct Tests {
    static func main() throws {
        let source = SoundSource(name: "Test", process: "player", pid: 42, bundleID: "test.player", appPath: "")
        let t = Date(timeIntervalSince1970: 1000)
        var g = EventGrouper()
        assert(g.consume(start: t, end: t.addingTimeInterval(0.03), peak: 0.5, source: source).isEmpty)
        assert(g.finishIfSilent(at: t.addingTimeInterval(0.2)) == nil)
        let first = g.finishIfSilent(at: t.addingTimeInterval(0.4))!
        assert(abs(first.duration - 0.03) < 0.000001 && !first.active)
        assert(first.source.pid == 42 && abs(first.decibels + 6.0205999) < 0.0001)
        // Nearby frames merge; separated beeps stay separate, even in a single drain.
        _ = g.consume(start: t, end: t.addingTimeInterval(0.1), peak: 0.2, source: source)
        let id = g.current!.id
        _ = g.consume(start: t.addingTimeInterval(0.2), end: t.addingTimeInterval(0.3), peak: 0.8, source: source)
        assert(g.current!.id == id && g.current!.peak == 0.8)
        let closed = g.consume(start: t.addingTimeInterval(0.7), end: t.addingTimeInterval(0.701), peak: 0.1, source: source)
        assert(closed.count == 1 && closed[0].id == id && g.current!.id != id)
        let click = g.finishIfSilent(at: t.addingTimeInterval(0.72), force: true)!
        assert(abs(click.duration - 0.001) < 0.000001)
        let data = try JSONEncoder().encode([first, click])
        let decoded = try JSONDecoder().decode([SoundEvent].self, from: data)
        assert(decoded == [first, click])
        print("PASS: short click, silence cutoff, split/merge, peak, process identity, JSON round-trip")
    }
}
