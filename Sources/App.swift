import AppKit
import SwiftUI
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var store: SoundStore!
    var window: NSWindow!
    var statusItem: NSStatusItem!
    var quitting = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        store = SoundStore()
        let menu = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Показать Beep Source", action: #selector(showWindow), keyEquivalent: "0")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Выйти из Beep Source", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let item = NSMenuItem(); item.submenu = appMenu; menu.addItem(item)
        let edit = NSMenu(title: "Правка")
        edit.addItem(withTitle: "Копировать", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Вставить", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Выбрать всё", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem(title: "Правка", action: nil, keyEquivalent: ""); editItem.submenu = edit; menu.addItem(editItem)
        NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 690), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Beep Source"; window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 850, height: 600)
        window.contentView = NSHostingView(rootView: MainView(store: store))
        window.isReleasedWhenClosed = false; window.delegate = self
        window.setFrameAutosaveName("BeepSourceMain")
        window.center()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Beep Source — история звуков")
            button.image?.isTemplate = true; button.toolTip = "Beep Source — нажмите, чтобы увидеть источники звука"
            button.target = self; button.action = #selector(statusClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        let launchEvent = NSAppleEventManager.shared().currentAppleEvent
        let loginLaunch = launchEvent?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
            || launchEvent?.paramDescriptor(forKeyword: keyAELaunchedAsLogInItem)?.booleanValue == true
        if !loginLaunch && !ProcessInfo.processInfo.arguments.contains("--background") { showWindow() }
    }
    @objc func statusClick() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "Открыть историю", action: #selector(showWindow), keyEquivalent: "")
            menu.addItem(withTitle: store.monitoring ? "Приостановить" : "Продолжить", action: #selector(toggle), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
            for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
            statusItem.menu = menu; statusItem.button?.performClick(nil); statusItem.menu = nil
        } else { showWindow() }
    }
    @objc func toggle() { store.toggleMonitoring() }
    @objc func showWindow() {
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) { NSApp.setActivationPolicy(.accessory) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitting { return .terminateNow }
        quitting = true
        store.engine.stop { self.store.save(wait: true); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

@main struct BeepSource {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
