import AppKit
import SwiftUI

@main
enum NeededApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Menu bar only: no Dock icon, no main window (also LSUIElement in Info.plist).
        app.setActivationPolicy(.accessory)
        app.mainMenu = mainMenu(delegate)
        app.run()
    }

    /// Never shown (accessory apps have no menu bar), but ⌘X/⌘C/⌘V/⌘A/⌘Z in
    /// text fields, ⌘, and ⌘W are this menu's key equivalents: without it they
    /// do nothing.
    private static func mainMenu(_ delegate: AppDelegate) -> NSMenu {
        let edit = NSMenu(title: tr("Правка"))
        edit.addItem(withTitle: tr("Отменить"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: tr("Повторить"), action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: tr("Вырезать"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: tr("Копировать"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: tr("Вставить"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: tr("Выбрать все"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let window = NSMenu(title: tr("Окно"))
        let settings = window.addItem(withTitle: tr("Настройки…"), action: #selector(AppDelegate.openSettings), keyEquivalent: ",")
        settings.target = delegate
        window.addItem(withTitle: tr("Закрыть"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: tr("Закрыть приложение"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let main = NSMenu()
        for submenu in [edit, window] {
            let item = NSMenuItem()
            item.submenu = submenu
            main.addItem(item)
        }
        return main
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel!
    private var status: StatusBar!
    private var windows: Windows!
    private var updates: Updates!

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Before anything reads the settings or the session.
        Migration.run()
        // Created early: a lovearound:// link that launched the app arrives before didFinish.
        model = AppModel()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        updates = Updates()
        status = StatusBar(model: model)
        status.onCheckUpdates = { [weak self] in self?.updates.checkNow() }
        windows = Windows(model: model)
        model.onOpenSettings = { [weak self] in self?.openSettings() }
        model.onSignOut = { [weak self] in self?.windows.closeAll() }
        model.onOpenBook = { [weak self] contact in
            self?.status.close()
            self?.windows.showBook(contact: contact)
        }
        model.onIconChange = { [weak self] in self?.status.updateIcon() }
        model.onReceive = { [weak self] color in self?.status.flashIcon(color) }
        model.onShowMenu = { [weak self] in self?.status.show() }

        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.model.stream.restart() }
        }

        model.start()
        if Strings.reopenSettings && model.signedIn {
            openSettings()
        } else if !model.signedIn || model.route != .main {
            status.show()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(model.handle(url:))
    }

    @objc func openSettings() {
        guard model.signedIn else { return }
        status.close()
        windows.showSettings()
    }
}

/// The heart in the menu bar: a click opens the popover, a right click a small
/// menu with the pause, settings, updates and quitting.
@MainActor
final class StatusBar: NSObject, NSPopoverDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let model: AppModel
    private var tint: NSColor?
    var onCheckUpdates: () -> Void = {}

    init(model: AppModel) {
        self.model = model
        super.init()

        let hosting = NSHostingController(rootView: RootView().environmentObject(model))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.delegate = self

        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        updateIcon()
    }

    /// Each opening starts on the people. Except a half-filled new contact:
    /// its link is often being copied elsewhere.
    func popoverDidClose(_ notification: Notification) {
        if case .add = model.route { return }
        model.route = .main
    }

    @objc private func clicked() {
        guard let event = NSApp.currentEvent else { return toggle() }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showMenu()
        } else {
            toggle()
        }
    }

    private func toggle() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            show()
        }
    }

    func show() {
        guard let button = item.button else { return }
        if !popover.isShown {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        popover.contentViewController?.view.window?.makeKey()
    }

    private func showMenu() {
        popover.performClose(nil)
        let menu = NSMenu()
        if model.signedIn {
            if model.isPaused {
                // No action: shown greyed, as a status line.
                menu.addItem(NSMenuItem(title: model.pauseText, action: nil, keyEquivalent: ""))
                menu.addItem(menuItem(tr("Снять паузу"), #selector(resume)))
            } else {
                menu.addItem(menuItem(tr("Пауза на час"), #selector(pauseHour)))
                menu.addItem(menuItem(tr("Пауза до утра"), #selector(pauseUntilMorning)))
                menu.addItem(menuItem(tr("Пауза, пока не сниму"), #selector(pauseUntilResumed)))
            }
            menu.addItem(.separator())
            menu.addItem(menuItem(tr("Книга…"), #selector(openBook)))
            menu.addItem(menuItem(tr("Настройки…"), #selector(openSettings), key: ","))
            menu.addItem(.separator())
        }
        menu.addItem(menuItem(tr("Проверить обновления…"), #selector(checkUpdates)))
        menu.addItem(menuItem(tr("Закрыть приложение"), #selector(quit), key: "q"))
        // A status item shows its menu on a click: set for this one click only,
        // so a left click keeps opening the popover.
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    private func menuItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.target = self
        return menuItem
    }

    @objc private func resume() { model.resume() }
    @objc private func pauseHour() { model.pause(.hour) }
    @objc private func pauseUntilMorning() { model.pause(.untilMorning) }
    @objc private func pauseUntilResumed() { model.pause(.untilResumed) }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func checkUpdates() { onCheckUpdates() }

    @objc private func openSettings() {
        model.onOpenSettings()
    }

    @objc private func openBook() {
        model.onOpenBook(nil)
    }

    func close() {
        popover.performClose(nil)
    }

    func updateIcon() {
        let name = model.isPaused ? "heart.slash.circle" : "heart.circle.fill"
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: model.isPaused ? tr("Сердечко на паузе") : tr("Сердечко")) else { return }
        if let tint {
            let image = base.withSymbolConfiguration(config.applying(NSImage.SymbolConfiguration(hierarchicalColor: tint)))
            image?.isTemplate = false
            item.button?.image = image
        } else {
            let image = base.withSymbolConfiguration(config)
            image?.isTemplate = true
            item.button?.image = image
        }
    }

    /// The icon briefly takes the signal color when a signal arrives.
    func flashIcon(_ color: NSColor) {
        tint = color
        updateIcon()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            if tint == color {
                tint = nil
                updateIcon()
            }
        }
    }
}
