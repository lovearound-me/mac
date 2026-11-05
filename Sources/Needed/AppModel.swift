import AppKit
import ServiceManagement
import SwiftUI

/// The popover's screens. The book and the settings are windows of their own.
enum Route: Equatable {
    case main
    case add(invite: String?)
}

enum PauseLength {
    case hour, untilMorning, untilResumed
}

/// App state behind the menu. Contact colors, the own signal color and all
/// settings stay on this Mac: the server only knows contacts and labels.
@MainActor
final class AppModel: ObservableObject {
    let auth = Auth()
    let api: API
    let stream: Stream
    let overlay = Overlay()

    @Published private(set) var signedIn = false
    @Published private(set) var email: String?
    @Published private(set) var myUID: String?
    @Published private(set) var inviteURL: String?
    @Published private(set) var contacts: [Contact] = []
    @Published var route: Route = .main
    /// The contact that was just sent a signal, for "Улетело ♥".
    @Published private(set) var sent: String?
    @Published var problem: String?
    @Published var waitingForBrowser = false
    /// The stream is connected. A reconnect of a few
    /// seconds (after sleep, a new network, a settings change) does not count.
    @Published private(set) var online = false
    /// No connection for a while (or none since launch): the menu says signals
    /// won't arrive. Not just `!online`, which would flash on every launch.
    @Published private(set) var offline = false
    /// The device just made in Settings → Устройства: its token is shown once,
    /// so it outlives the popover closing.
    @Published var createdDevice: (name: String, token: String)?

    @Published var myColor: Int { didSet { defaults.set(myColor, forKey: "myColor") } }
    @Published var sound: Bool { didSet { defaults.set(sound, forKey: "sound") } }
    @Published var calm: Bool { didSet { defaults.set(calm, forKey: "calm") } }
    /// How many emoji float up with a signal; 0 is the glow alone.
    @Published var emojiCount: Int { didSet { defaults.set(emojiCount, forKey: "emojiCount") } }
    /// No signals while something is full screen or a display is mirrored.
    @Published var quietWhenPresenting: Bool { didSet { defaults.set(quietWhenPresenting, forKey: "quietWhenPresenting") } }
    /// An incoming signal glows at most once per this many seconds, one of `gaps`.
    @Published var minGap: TimeInterval { didSet { defaults.set(minGap, forKey: "minGap") } }
    /// "Сердечки от кого-нибудь на свете": the stream asks for signals to anyone.
    @Published var acceptAnyone: Bool {
        didSet {
            defaults.set(acceptAnyone, forKey: "acceptAnyone")
            stream.anyone = acceptAnyone
            stream.restart()
        }
    }
    /// When this Mac last sent a signal to anyone: one an hour.
    @Published private(set) var anyoneSentAt: Date? { didSet { defaults.set(anyoneSentAt, forKey: "anyoneSentAt") } }
    @Published private(set) var anyoneSending = false
    @Published private(set) var contactColors: [String: Int] { didSet { defaults.set(contactColors, forKey: "contactColors") } }
    /// When each contact was last sent a signal from this Mac, for "Недавние".
    private var lastSent: [String: Date] { didSet { defaults.set(lastSent, forKey: "lastSent") } }
    @Published private(set) var pausedUntil: Date? {
        didSet {
            defaults.set(pausedUntil, forKey: "pausedUntil")
            onIconChange()
        }
    }
    @Published private(set) var launchAtLogin = false

    var onIconChange: () -> Void = {}
    var onReceive: (NSColor) -> Void = { _ in }
    var onShowMenu: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    /// Opens the book, on this contact if one is given.
    var onOpenBook: (String?) -> Void = { _ in }
    var onSignOut: () -> Void = {}

    private let defaults = UserDefaults.standard
    private var sentReset: Task<Void, Never>?
    private var lastShown: Date?
    private var pendingAdd: String?
    private var goingOffline: Task<Void, Never>?
    /// Order changes go to the server one after another, in the order made.
    private var saving: Task<Void, Never>?
    private var reorderSave: Task<Void, Never>?

    init() {
        api = API(auth: auth)
        stream = Stream(auth: auth)
        let defaults = UserDefaults.standard
        myColor = defaults.object(forKey: "myColor") as? Int ?? 1
        sound = defaults.bool(forKey: "sound")
        calm = defaults.bool(forKey: "calm")
        emojiCount = defaults.object(forKey: "emojiCount") as? Int ?? Overlay.defaultEmojiCount
        quietWhenPresenting = defaults.object(forKey: "quietWhenPresenting") as? Bool ?? true
        minGap = Self.gaps[Self.gapIndex(defaults.object(forKey: "minGap") as? TimeInterval ?? 1)]
        acceptAnyone = defaults.object(forKey: "acceptAnyone") as? Bool ?? true
        anyoneSentAt = defaults.object(forKey: "anyoneSentAt") as? Date
        contactColors = defaults.dictionary(forKey: "contactColors") as? [String: Int] ?? [:]
        lastSent = defaults.dictionary(forKey: "lastSent") as? [String: Date] ?? [:]
        pausedUntil = defaults.object(forKey: "pausedUntil") as? Date

        stream.anyone = acceptAnyone
        stream.onSignal = { [weak self] in self?.receive() }
        stream.onAuthLost = { [weak self] in self?.signOut() }
        stream.onOnline = { [weak self] up in self?.connectionChanged(up) }
        stream.onSync = { [weak self] in
            Task {
                // Not halfway through saving a new order: that would show it half-applied.
                await self?.saving?.value
                await self?.reload()
            }
        }

        // A pause ends by itself.
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                if let self, let until = self.pausedUntil, until <= Date() { self.pausedUntil = nil }
            }
        }

        if !defaults.bool(forKey: "loginItemSetUp") {
            defaults.set(true, forKey: "loginItemSetUp")
            try? SMAppService.mainApp.register()
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func start() {
        guard let session = auth.session else { return }
        signedIn = true
        email = session.email
        myUID = session.uid
        // The stream reloads the contacts once it is connected.
        stream.start()
        connectionChanged(online)
    }

    func reload() async {
        do {
            let me = try await api.me()
            myUID = me.uid
            inviteURL = me.invite_url
            contacts = try await api.contacts()
            problem = nil
        } catch let error as AuthError where error.endsSession {
            signOut()
        } catch {
            problem = tr("Нет связи с сервером. Попробуем ещё раз чуть позже.")
        }
    }

    private func connectionChanged(_ up: Bool) {
        goingOffline?.cancel()
        if up {
            online = true
            offline = false
        } else {
            goingOffline = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if !Task.isCancelled {
                    online = false
                    offline = true
                }
            }
        }
    }

    // ---- signals ------------------------------------------------------------

    func send(_ contact: Contact) {
        sent = contact.id
        lastSent[contact.id] = Date()
        sentReset?.cancel()
        sentReset = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if !Task.isCancelled { sent = nil }
        }
        // The sender sees the glow too, in the contact's color: silent, and even on pause.
        overlay.play(color: NSColor(hex: color(for: contact).color), emoji: Overlay.warm, count: emojiCount, calm: calmEffect)
        Task {
            do {
                try await api.signal(contact.id)
                problem = nil
            } catch let error as AuthError where error.endsSession {
                sent = nil
                signOut()
                problem = tr("Нужно войти заново")
            } catch {
                sent = nil
                problem = tr("Не улетело, проверь интернет")
            }
        }
    }

    /// "Кому-нибудь на свете": one random person online who takes them. The
    /// server spends the hour on the try and accepts it even with nobody
    /// online, so "Улетело" is all the sender ever learns.
    func sendToAnyone() {
        guard anyoneWait() == nil, !anyoneSending else { return }
        anyoneSending = true
        Task {
            defer { anyoneSending = false }
            do {
                try await api.signalAnyone()
                anyoneSentAt = Date()
                problem = nil
                overlay.play(color: Self.starColor, emoji: Overlay.stars, calm: calmEffect)
            } catch let error as AuthError where error.endsSession {
                signOut()
                problem = tr("Нужно войти заново")
            } catch let error as APIError where error.status == 429 {
                // Sent from another device this hour, at a time not known
                // here: wait a whole hour from now, a little longer than needed.
                anyoneSentAt = Date().addingTimeInterval(-120)
                problem = nil
            } catch {
                problem = tr("Не улетело, проверь интернет")
            }
        }
    }

    /// Whole minutes until the next signal to anyone, or nil if it can go now.
    func anyoneWait(at now: Date = Date()) -> Int? {
        guard let anyoneSentAt else { return nil }
        let left = anyoneSentAt.addingTimeInterval(3600).timeIntervalSince(now)
        return left > 0 ? Int((left / 60).rounded(.up)) : nil
    }

    static let starColor = NSColor(hex: 0xF2C46B)

    var signalColor: NSColor {
        NSColor(hex: Palette.at(myColor).color)
    }

    private func receive() {
        guard !isPaused else { return }
        // Not shown, and not saved for later: a signal is about the moment.
        if quietWhenPresenting && Presenting.now { return }
        // The server lets one signal per sender through each second; a rarer
        // glow is this Mac's own choice, and the ones in between are not shown.
        if let lastShown, Date().timeIntervalSince(lastShown) < minGap { return }
        lastShown = Date()
        playEffect()
    }

    /// The right end of "Смайликов за раз".
    static let maxEmoji = 60

    /// The steps of "Свечение не чаще раза в".
    static let gaps: [TimeInterval] = [1, 5, 15, 30, 60, 300, 900, 3600]

    /// The step nearest to `gap`, so the slider shows what is in effect.
    static func gapIndex(_ gap: TimeInterval) -> Int {
        gaps.indices.min { abs(gaps[$0] - gap) < abs(gaps[$1] - gap) } ?? 0
    }

    static func gapTitle(_ gap: TimeInterval) -> String {
        switch gap {
        case ..<60: return tr("{n} с", ["n": Int(gap)])
        case ..<3600: return tr("{n} мин", ["n": Int(gap / 60)])
        default: return tr("{n} ч", ["n": Int(gap / 3600)])
        }
    }

    /// The incoming-signal effect, also used by "Показать, как это выглядит".
    func playEffect() {
        overlay.play(color: signalColor, emoji: Overlay.warm, count: emojiCount, calm: calmEffect)
        onReceive(signalColor)
        if sound, let purr = NSSound(named: "Purr") {
            purr.volume = 0.35
            purr.play()
        }
    }

    private var calmEffect: Bool {
        calm || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // ---- pause --------------------------------------------------------------

    var isPaused: Bool {
        guard let pausedUntil else { return false }
        return pausedUntil > Date()
    }

    var pauseText: String {
        guard let pausedUntil, isPaused else { return "" }
        if pausedUntil == .distantFuture { return tr("Пауза, пока не снимешь") }
        let time = pausedUntil.formatted(date: .omitted, time: .shortened)
        return Calendar.current.isDateInToday(pausedUntil) ? tr("Пауза до {time}", ["time": time]) : tr("Пауза до завтра, {time}", ["time": time])
    }

    func pause(_ length: PauseLength) {
        switch length {
        case .hour:
            pausedUntil = Date().addingTimeInterval(3600)
        case .untilMorning:
            let calendar = Calendar.current
            let today8 = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: Date())!
            pausedUntil = today8 > Date() ? today8 : calendar.date(byAdding: .day, value: 1, to: today8)!
        case .untilResumed:
            pausedUntil = .distantFuture
        }
    }

    func resume() {
        pausedUntil = nil
    }

    // ---- contacts -----------------------------------------------------------

    /// Circles on top of the menu, in the order set by hand.
    var closeContacts: [Contact] {
        contacts.filter(\.isClose)
    }

    /// Everyone else, the most recently signalled first, then by name.
    var otherContacts: [Contact] {
        contacts.filter { !$0.isClose }.sorted { a, b in
            let (ta, tb) = (lastSent[a.id] ?? .distantPast, lastSent[b.id] ?? .distantPast)
            return ta != tb ? ta > tb : a.label.localizedStandardCompare(b.label) == .orderedAscending
        }
    }

    /// The whole book by name.
    var contactsByName: [Contact] {
        contacts.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    /// New contacts start among the close ones until there are a couple of rows of them.
    var newContactIsClose: Bool {
        closeContacts.count < 10
    }

    func color(for contact: Contact) -> PaletteColor {
        if let index = contactColors[contact.id] { return Palette.at(index) }
        return Palette.at(contacts.firstIndex(of: contact) ?? 0)
    }

    /// The first color not yet used, for a new contact.
    var nextColor: Int {
        let used = Set(contacts.map { contactColors[$0.id] ?? -1 })
        return Palette.all.indices.first { !used.contains($0) } ?? contacts.count % Palette.all.count
    }

    func addContact(code: String, label: String, color: Int, close: Bool) async throws {
        let contact = try await api.addContact(code: code, label: label, close: close)
        contactColors[contact.id] = color
        contacts.append(contact)
    }

    func updateContact(_ contact: Contact, label: String, color: Int, close: Bool) async throws {
        if label != contact.label || close != contact.isClose {
            try await api.updateContact(contact.id,
                                        label: label != contact.label ? label : nil,
                                        close: close != contact.isClose ? close : nil)
        }
        contactColors[contact.id] = color
        if let index = contacts.firstIndex(where: { $0.id == contact.id }) {
            contacts[index].label = label
            contacts[index].close = close
        }
    }

    /// Into "Рядом" or out of it: shown at once, saved behind.
    func setClose(_ contact: Contact, _ close: Bool) {
        guard let index = contacts.firstIndex(where: { $0.id == contact.id }) else { return }
        contacts[index].close = close
        let previous = saving
        saving = Task {
            await previous?.value
            do {
                try await api.updateContact(contact.id, close: close)
            } catch {
                problem = tr("Не получилось сохранить")
                await reload()
            }
        }
    }

    func remove(_ contact: Contact) async throws {
        try await api.deleteContact(contact.id)
        contacts.removeAll { $0.id == contact.id }
        contactColors[contact.id] = nil
        lastSent[contact.id] = nil
    }

    /// Puts a close contact in the target's circle, the others shift.
    func move(_ contact: Contact, to target: Contact) {
        var close = closeContacts
        guard contact.id != target.id,
              let from = close.firstIndex(where: { $0.id == contact.id }),
              let to = close.firstIndex(where: { $0.id == target.id }) else { return }
        close.insert(close.remove(at: from), at: to)
        reorderClose(close)
    }

    /// A drag in the book: into "Рядом" at this place among the circles,
    /// or out of it with nil.
    func place(_ contact: Contact, closeAt index: Int?) {
        guard let index else {
            if contact.isClose { setClose(contact, false) }
            return
        }
        if !contact.isClose { setClose(contact, true) }
        var close = closeContacts.filter { $0.id != contact.id }
        guard let person = contacts.first(where: { $0.id == contact.id }) else { return }
        close.insert(person, at: min(index, close.count))
        reorderClose(close)
    }

    /// Shown at once; saved a moment after the last change, so a drag across
    /// several circles is one save.
    private func reorderClose(_ close: [Contact]) {
        // The close ones keep their slots in the whole list, in the new order.
        let slots = contacts.indices.filter { contacts[$0].isClose }
        for (slot, person) in zip(slots, close) {
            contacts[slot] = person
        }
        reorderSave?.cancel()
        reorderSave = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            if !Task.isCancelled { savePositions() }
        }
    }

    private func savePositions() {
        let changed = contacts.indices.filter { contacts[$0].position != $0 }
        for index in changed {
            contacts[index].position = index
        }
        let updates = changed.map { (contacts[$0].id, $0) }
        guard !updates.isEmpty else { return }
        let previous = saving
        saving = Task {
            await previous?.value
            do {
                for (id, position) in updates {
                    try await api.updateContact(id, position: position)
                }
            } catch {
                problem = tr("Не получилось сохранить порядок")
                await reload()
            }
        }
    }

    /// For the button of a board that sends to this person (/docs).
    func copyInvite() -> Bool {
        guard let inviteURL else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(inviteURL, forType: .string)
        return true
    }

    /// The code of an invite link on the clipboard, unless it is this user's own.
    var pastedInvite: String? {
        guard let text = NSPasteboard.general.string(forType: .string),
              let code = Self.inviteID(from: text) else { return nil }
        let bare = { (code: String) in code.uppercased().filter { $0 != "-" } }
        if let own = inviteURL.flatMap(Self.inviteID(from:)), bare(own) == bare(code) { return nil }
        return code
    }

    /// The code from an invite link (or the bare code), as typed.
    static func inviteID(from text: String) -> String? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for marker in ["/i/", "lovearound://add/", "needed://add/"] {
            if let range = text.range(of: marker, options: .backwards) {
                text = String(text[range.upperBound...])
            }
        }
        text = text.components(separatedBy: CharacterSet(charactersIn: "/?#")).first ?? ""
        // 10 characters of the server's alphabet, dashes anywhere (`GSSV7-A33HN`).
        // The server never says whether a code is taken, so this is the only
        // check a typo gets: no 0, 1, I, L, O or U.
        let alphabet = Set("23456789ABCDEFGHJKMNPQRSTVWXYZ")
        let code = text.uppercased().filter { $0 != "-" }
        guard code.count == 10, code.allSatisfy(alphabet.contains) else { return nil }
        return text
    }

    // ---- links --------------------------------------------------------------

    func handle(url: URL) {
        guard let scheme = url.scheme, Config.urlSchemes.contains(scheme) else { return }
        switch url.host {
        case "add":
            // The whole link, not url.path: its leading "/" would leave inviteID an empty id.
            guard let invite = Self.inviteID(from: url.absoluteString) else { return }
            if signedIn {
                route = .add(invite: invite)
            } else {
                pendingAdd = invite
            }
            onShowMenu()
        case "signin":
            // The browser can hand over the same link twice (the page's own
            // redirect, then its "back" button, or a restored tab): the first
            // one signs in and uses up the state, so a late copy is no news.
            if signedIn && !waitingForBrowser { return }
            Task {
                do {
                    try await auth.completeGoogle(url)
                    didSignIn()
                } catch {
                    // Unless it's a copy that lost the race to the first one.
                    if !signedIn { problem = error.localizedDescription }
                }
                waitingForBrowser = false
                onShowMenu()
            }
        default:
            break
        }
    }

    // ---- account ------------------------------------------------------------

    func signIn(email: String, password: String) async throws {
        try await auth.signIn(email: email, password: password)
        didSignIn()
    }

    func signInWithGoogle() {
        waitingForBrowser = true
        NSWorkspace.shared.open(auth.googleSignInURL())
    }

    func sendPasswordReset(email: String) async throws {
        try await auth.sendPasswordReset(email: email)
    }

    private func didSignIn() {
        problem = nil
        start()
        if let invite = pendingAdd {
            pendingAdd = nil
            route = .add(invite: invite)
        } else {
            route = .main
        }
    }

    func signOut() {
        stream.stop()
        auth.signOut()
        goingOffline?.cancel()
        offline = false
        createdDevice = nil
        signedIn = false
        email = nil
        myUID = nil
        inviteURL = nil
        contacts = []
        route = .main
        onSignOut()
    }

    func deleteAccount() async throws {
        try await api.deleteMe()
        contactColors = [:]
        lastSent = [:]
        signOut()
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            problem = tr("macOS не дал поменять автозапуск")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
