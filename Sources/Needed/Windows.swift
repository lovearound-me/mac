import AppKit
import SwiftUI

/// The settings and the book: ordinary windows, for what takes longer than a
/// glance. The app stays in the menu bar only, without a Dock icon, so a
/// window is brought to the front each time it is asked for.
@MainActor
final class Windows {
    private let model: AppModel
    private var settings: NSWindow?
    private var book: NSWindow?
    /// The contact the book shows, set from outside ("Изменить" in the menu).
    private let bookSelection = BookSelection()

    init(model: AppModel) {
        self.model = model
    }

    /// Nothing to show once signed out (or the account is gone).
    func closeAll() {
        settings?.close()
        book?.close()
    }

    func showSettings() {
        settings = show(settings, title: tr("Настройки"), autosave: "Settings", resizable: false) {
            SettingsView()
        }
    }

    func showBook(contact: String? = nil) {
        if let contact {
            bookSelection.id = contact
        }
        book = show(book, title: tr("Книга"), autosave: "Book", resizable: true) { [bookSelection] in
            BookView().environmentObject(bookSelection)
        }
    }

    private func show<Content: View>(_ existing: NSWindow?, title: String, autosave: String, resizable: Bool,
                                     content: () -> Content) -> NSWindow {
        let window = existing ?? {
            var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            if resizable { style.insert(.resizable) }
            let window = NSWindow(contentRect: .zero, styleMask: style, backing: .buffered, defer: false)
            window.title = title
            window.titlebarAppearsTransparent = true
            window.backgroundColor = .paper
            window.isReleasedWhenClosed = false
            // The view's own size, and its limits for a resizable window.
            let hosting = NSHostingController(rootView: content()
                .environmentObject(model)
                .foregroundColor(.ink)
                .font(.system(size: 13)))
            window.contentViewController = hosting
            window.setContentSize(hosting.view.fittingSize)
            window.center()
            window.setFrameAutosaveName(autosave)
            return window
        }()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return window
    }
}

/// Which contact the book window shows on the right.
@MainActor
final class BookSelection: ObservableObject {
    @Published var id: String?
}
