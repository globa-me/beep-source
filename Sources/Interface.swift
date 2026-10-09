import SwiftUI
import AppKit

private let accent = Color(red: 0.15, green: 0.43, blue: 0.94)
private let clock: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()
private let calendar: DateFormatter = { let f = DateFormatter(); f.dateFormat = "d MMM"; f.locale = Locale(identifier: "ru_RU"); return f }()
private let fullDate: DateFormatter = { let f = DateFormatter(); f.dateFormat = "dd.MM.yyyy HH:mm:ss.SSS"; return f }()
private var iconCache: [String: NSImage] = [:]
private func appIcon(_ source: SoundSource) -> NSImage {
    if let icon = iconCache[source.appPath] { return icon }
    let icon = source.appPath.isEmpty ? NSImage(systemSymbolName: "gearshape.fill", accessibilityDescription: "Системный процесс")!
        : NSWorkspace.shared.icon(forFile: source.appPath)
    iconCache[source.appPath] = icon; return icon
}
private func duration(_ seconds: Double) -> String {
    if seconds < 1 { return "\(max(1, Int(seconds * 1000))) мс" }
    if seconds < 60 { return String(format: "%.1f с", seconds) }
    return "\(Int(seconds / 60)) мин \(Int(seconds) % 60) с"
}

struct MainView: View {
    @ObservedObject var store: SoundStore
    @State private var search = ""
    @State private var shortOnly = false
    @State private var recentSince: Date?
    @State private var selection: UUID?
    private var filtered: [SoundEvent] {
        store.events.filter { event in
            (!shortOnly || event.duration <= 3) && (recentSince == nil || event.end >= recentSince!)
            && (search.isEmpty || "\(event.source.name) \(event.source.process) \(event.source.bundleID) \(event.source.pid)".localizedCaseInsensitiveContains(search))
        }
    }
    private var selected: SoundEvent? { store.events.first { $0.id == selection } }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "waveform").font(.system(size: 27, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 52, height: 52).background(accent.gradient, in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Beep Source").font(.system(size: 25, weight: .semibold))
                    HStack(spacing: 6) {
                        Circle().fill(store.monitoring ? Color.green : .orange).frame(width: 7, height: 7)
                        Text("\(store.status) · \(store.processCount) процессов").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button { store.toggleMonitoring() } label: {
                    Label(store.monitoring ? "Пауза" : "Продолжить", systemImage: store.monitoring ? "pause.fill" : "play.fill")
                }.controlSize(.large)
                Menu {
                    Toggle("Запускать при входе в macOS", isOn: Binding(get: { store.loginEnabled }, set: store.setLogin))
                    Button("Разрешение на системное аудио…", action: store.openPermissions)
                    Button("Перезапустить наблюдение", action: store.restart)
                    Divider()
                    Button("Экспортировать историю…", action: store.export)
                    Button("Очистить историю…", action: store.clear)
                    Divider()
                    Button("О Beep Source") { showAbout() }
                    Button("Выйти из Beep Source") { NSApp.terminate(nil) }
                } label: { Image(systemName: "ellipsis").frame(width: 18) }.menuStyle(.borderlessButton).frame(width: 30)
            }.padding(24)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("История звуков").font(.system(size: 16, weight: .semibold))
                    Text("\(filtered.count)").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        recentSince = Date().addingTimeInterval(-30); shortOnly = false; search = ""
                    } label: { Label("Только что слышал звук", systemImage: "ear") }
                    .help("Показать события за последние 30 секунд и все новые")
                }
                HStack(spacing: 12) {
                    HStack(spacing: 7) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Найти приложение или процесс", text: $search).textFieldStyle(.plain)
                        if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary) }
                    }.padding(9).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    Toggle("Короткие · до 3 с", isOn: $shortOnly).toggleStyle(.checkbox)
                    if recentSince != nil { Button("Вся история") { recentSince = nil } }
                }
            }.padding(.horizontal, 24).padding(.vertical, 17)
            if !store.issue.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(store.issue).font(.system(size: 12)).textSelection(.enabled)
                    Spacer()
                    Button { store.issue = "" } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }.padding(12).background(Color.orange.opacity(0.08)).padding(.horizontal, 24).padding(.bottom, 12)
            }
            if filtered.isEmpty {
                Spacer()
                Image(systemName: search.isEmpty && recentSince == nil ? "waveform.path" : "line.3.horizontal.decrease.circle")
                    .font(.system(size: 44, weight: .light)).foregroundStyle(accent.opacity(0.65))
                Text(store.events.isEmpty ? "Здесь появятся звуки" : "Подходящих событий пока нет").font(.system(size: 18, weight: .medium)).padding(.top, 10)
                Text(store.events.isEmpty ? "Когда приложение что-то проиграет, вы увидите время и источник.\nОкно можно закрыть — наблюдение продолжится в строке меню." : "Измените фильтры или дождитесь следующего звука.")
                    .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(5).padding(.top, 4)
                if !store.confirmed {
                    Button("Проверить разрешение на системное аудио", action: store.openPermissions).padding(.top, 12)
                    Text("Разрешение: Настройки системы → Конфиденциальность и безопасность →\nЗапись экрана и системного аудио. После включения перезапустите наблюдение.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.top, 4)
                }
                Spacer()
            } else {
                HStack {
                    Text("ВРЕМЯ").frame(width: 110, alignment: .leading)
                    Text("ИСТОЧНИК").frame(maxWidth: .infinity, alignment: .leading)
                    Text("ДЛИТЕЛЬНОСТЬ").frame(width: 130, alignment: .trailing)
                    Text("ПИК").frame(width: 90, alignment: .trailing)
                }.font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 36).padding(.bottom, 8)
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(filtered) { event in
                            EventRow(event: event, selected: selection == event.id)
                                .contentShape(Rectangle()).onTapGesture { selection = selection == event.id ? nil : event.id }
                        }
                    }.padding(.horizontal, 24).padding(.bottom, 16)
                }
            }
            if let event = selected {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(event.source.process) · PID \(event.source.pid)").font(.system(size: 12, weight: .medium))
                    Text("\(fullDate.string(from: event.start)) → \(fullDate.string(from: event.end)) · \(event.source.bundleID.isEmpty ? "Без Bundle ID" : event.source.bundleID)")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    if !event.source.appPath.isEmpty { Text(event.source.appPath).font(.system(size: 11)).foregroundStyle(.secondary) }
                    if event.source.appPath.isEmpty { Text("Системный процесс может воспроизводить уведомление от другого приложения.").font(.system(size: 11)).foregroundStyle(.secondary) }
                }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.vertical, 12)
            }
            Divider()
            HStack {
                Image(systemName: "internaldrive").font(.system(size: 11))
                Text("Локальная история · 30 дней / 5 000 событий").font(.system(size: 11))
                Spacer()
                Text("Аудиозаписи не сохраняются").font(.system(size: 11))
            }.foregroundStyle(.secondary).padding(.horizontal, 24).padding(.vertical, 12)
        }.frame(minWidth: 850, minHeight: 560).background(Color(nsColor: .windowBackgroundColor)).tint(accent)
    }
    private func showAbout() {
        let alert = NSAlert(); alert.messageText = "Beep Source 1.0"
        alert.informativeText = "Журнал звука приложений и системных процессов.\n\nОбнаруживает цифровой сигнал выше −65 dBFS. Пик показывает уровень сигнала, а не физическую громкость динамиков. Соседние звуки объединяются при паузе меньше 220 мс.\n\nНовый процесс может проиграть звук до подключения наблюдения. Системные уведомления иногда видны только как общий процесс; вкладку браузера определить нельзя.\n\nИстория хранится локально в Library/Application Support/Beep Source. Записи звука не создаются; сеть не используется."
        alert.addButton(withTitle: "Понятно"); alert.runModal()
    }
}
private struct EventRow: View {
    let event: SoundEvent
    let selected: Bool
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(clock.string(from: event.start)).font(.system(size: 13, weight: .medium, design: .monospaced))
                Text(Calendar.current.isDateInToday(event.start) ? "Сегодня" : calendar.string(from: event.start)).font(.system(size: 10)).foregroundStyle(.secondary)
            }.frame(width: 110, alignment: .leading)
            HStack(spacing: 10) {
                Image(nsImage: appIcon(event.source)).resizable().scaledToFit().frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text(event.source.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(event.source.process).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 5) {
                if event.active { Circle().fill(Color.green).frame(width: 6, height: 6) }
                Text(event.active ? "\(duration(event.duration)) · сейчас" : duration(event.duration)).font(.system(size: 12, design: .monospaced))
            }.frame(width: 130, alignment: .trailing)
            Text(String(format: "%.0f dBFS", event.decibels)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                .frame(width: 90, alignment: .trailing).help("Пиковый уровень цифрового сигнала. 0 dBFS — максимум.")
        }.padding(.horizontal, 12).padding(.vertical, 12)
            .background(selected ? accent.opacity(0.11) : Color(nsColor: .controlBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 9))
    }
}
