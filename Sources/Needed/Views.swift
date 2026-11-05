import SwiftUI
import UniformTypeIdentifiers

// The menu's screens, following the mockups: warm paper, brown ink, one
// color per contact.

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if !model.signedIn {
                SignInView()
            } else {
                switch model.route {
                case .main: MainView()
                case .add(let invite): ContactForm(mode: .add(invite: invite)) { model.route = .main }
                }
            }
        }
        .padding(14)
        .frame(width: 330)
        .background(Color.paper)
        .foregroundColor(.ink)
        .font(.system(size: 13))
    }
}

// ---- main ---------------------------------------------------------------------

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @State private var query = ""

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 2) {
                Text(tr("О ком ты сейчас думаешь?"))
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                // Pause and quitting: a right click on the heart in the menu bar.
                IconButton(symbol: "book", help: tr("Книга")) { model.onOpenBook(nil) }
                IconButton(symbol: "gearshape", help: tr("Настройки")) { model.onOpenSettings() }
            }

            if model.offline {
                Banner(symbol: "wifi.slash", text: tr("Нет связи с сервером, сигналы сейчас не приходят. Переподключаемся…"))
            }

            if model.isPaused {
                Banner(symbol: "moon.fill", text: tr("{pause}. Сигналы не придут.", ["pause": model.pauseText])) {
                    Button(tr("Снять")) { model.resume() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(.link)
                }
            }

            CloseCircles()

            if model.contacts.isEmpty {
                VStack(spacing: 6) {
                    Text(tr("Пока никого нет"))
                        .font(.system(size: 14, weight: .semibold))
                    Text(tr("Добавь людей по их ссылке или отправь им свой Love ID, чтобы они могли поддерживать тебя."))
                        .multilineTextAlignment(.center)
                        .foregroundColor(.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 6)

                if let url = model.inviteURL.flatMap(URL.init(string:)) {
                    ShareLink(item: url, message: Text(InviteRow.message)) {
                        Label(tr("Поделиться своим Love ID"), systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(PrimaryButton())
                }
            } else {
                SearchField(text: $query, prompt: tr("Найти — {people}", ["people": peopleCount(model.contacts.count)]))

                if !trimmedQuery.isEmpty {
                    let found = model.contactsByName.filter { $0.label.localizedCaseInsensitiveContains(trimmedQuery) }
                    VStack(spacing: 2) {
                        ForEach(found) { contact in
                            ContactRow(contact: contact)
                        }
                        if found.isEmpty {
                            Text(tr("Никого с таким именем"))
                                .foregroundColor(.muted)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                    }
                } else if !model.otherContacts.isEmpty {
                    // A short book fits whole; a long one shows the recent few.
                    let others = model.otherContacts
                    let shown = others.count <= 5 ? others : Array(others.prefix(4))
                    VStack(alignment: .leading, spacing: 2) {
                        Caption(shown.count < others.count ? tr("Недавние") : tr("Остальные"))
                            .padding(.horizontal, 10)
                            .padding(.bottom, 2)
                        ForEach(shown) { contact in
                            ContactRow(contact: contact)
                        }
                        if shown.count < others.count {
                            LinkRow(symbol: "book", title: tr("Вся книга · {n}", ["n": model.contacts.count])) { model.onOpenBook(nil) }
                                .padding(.horizontal, 6)
                        }
                    }
                }
            }

            if !model.contacts.isEmpty {
                Divider().padding(.vertical, 2)
                InviteRow()
            }

            if let problem = model.problem {
                Text(problem)
                    .font(.system(size: 12))
                    .foregroundColor(.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // Each opening starts from an empty search.
        .onReceive(NotificationCenter.default.publisher(for: NSPopover.didCloseNotification)) { _ in
            query = ""
        }
    }
}

/// A quiet strip under the title: no connection, a pause.
struct Banner<Trailing: View>: View {
    let symbol: String
    let text: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: symbol).foregroundColor(.muted)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundColor(.muted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.field))
    }
}

extension Banner where Trailing == EmptyView {
    init(symbol: String, text: String) {
        self.init(symbol: symbol, text: text) { EmptyView() }
    }
}

/// The own link as one quiet card: the link itself, copied on a click.
/// Sharing lives in the menu; on a Mac the link mostly goes into a chat by hand.
struct InviteRow: View {
    @EnvironmentObject var model: AppModel
    @State private var copied = false
    @State private var hovering = false

    static let message = tr("Добавь меня по этой ссылке и нажимай сердечко, когда думаешь обо мне ♥")

    var body: some View {
        if let link = model.inviteURL {
            Button(action: copy) {
                HStack(spacing: 10) {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.link)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.link.opacity(0.14)))

                    VStack(alignment: .leading, spacing: 1) {
                        Text(tr("Твой Love ID"))
                            .font(.system(size: 11))
                            .foregroundColor(.muted)
                        Text(Self.shown(link))
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 6)

                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        if copied || hovering {
                            Text(copied ? tr("Скопировано") : tr("Скопировать"))
                        }
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(.link)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.field)
                        .overlay(RoundedRectangle(cornerRadius: 10).fill(Color.link.opacity(hovering ? 0.06 : 0)))
                )
                .contentShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering)
            .animation(.easeOut(duration: 0.15), value: copied)
            .help(tr("Кто добавит тебя по этой ссылке, сможет нажимать, когда думает о тебе"))
            .accessibilityLabel(tr("Скопировать свой Love ID"))
        }
    }

    /// The link without the scheme: "lovearound.me/i/…" reads better than a URL.
    static func shown(_ link: String) -> String {
        link.replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
    }

    private func copy() {
        guard model.copyInvite() else { return }
        copied = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
    }
}

/// "Кому-нибудь на свете", the first circle: one signal an hour to a random
/// person online. The ring fills back up over the hour.
struct AnyoneCircle: View {
    @EnvironmentObject var model: AppModel
    @Binding var hovered: String?

    /// Not a contact id: ids come from the server and never look like this.
    static let id = "★anyone"

    var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { context in
            let wait = model.anyoneWait(at: context.date)
            let help = wait.map { tr("Кому-нибудь на свете: снова через {n} мин", ["n": $0]) }
                ?? tr("Кому-нибудь на свете: сигнал уйдёт случайному человеку, раз в час. Он не узнает, от кого.")
            Button(action: model.sendToAnyone) {
                // Sparkles, not a person's letter: this one is for anyone.
                Image(systemName: "sparkles")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundColor(wait == nil ? Color.star : Color.starOff)
                    .frame(width: 50, height: 50)
                    .background(Circle().fill(LinearGradient(colors: Color.anyone, startPoint: .topLeading, endPoint: .bottomTrailing)))
                    .overlay(Circle().strokeBorder(Color.star.opacity(wait == nil ? 1 : 0.25), lineWidth: 3))
                    .overlay(
                        Circle()
                            .inset(by: 1.5)
                            .trim(from: 0, to: wait.map { Double(60 - $0) / 60 } ?? 0)
                            .stroke(Color.star, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    )
                    .scaleEffect(hovered == Self.id ? 1.08 : 1)
                    .opacity(model.anyoneSending ? 0.6 : 1)
                    .contentShape(Circle())
            }
            // Not disabled while waiting: a disabled button shows no tooltip.
            .buttonStyle(.plain)
            .help(help)
            .accessibilityLabel(help)
            .onHover { inside in
                if inside {
                    hovered = Self.id
                } else if hovered == Self.id {
                    hovered = nil
                }
            }
            .animation(.easeOut(duration: 0.15), value: hovered)
        }
    }
}

/// A person in the book: a row with a name, a click sends.
struct ContactRow: View {
    @EnvironmentObject var model: AppModel
    let contact: Contact
    @State private var hover = false

    var body: some View {
        let color = model.color(for: contact)
        let sent = model.sent == contact.id
        HStack(spacing: 4) {
            Button {
                model.send(contact)
            } label: {
                HStack(spacing: 12) {
                    Avatar(label: contact.label, color: color, size: 30)
                    Text(contact.label)
                        .font(.system(size: 14.5, weight: .medium))
                        .lineLimit(1)
                    Spacer()
                    if sent {
                        Text(tr("Улетело ♥"))
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(color.deepColor)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 42)
                .background(
                    RoundedRectangle(cornerRadius: 11)
                        .fill(color.tintColor.opacity(sent ? 1 : hover ? 0.6 : 0))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .animation(.easeOut(duration: 0.2), value: sent)
        }
    }
}

/// The close people: circles without names on top of the menu, after the
/// one for anyone in the world. The name shows under them on hover; a drag
/// puts a circle elsewhere.
struct CloseCircles: View {
    @EnvironmentObject var model: AppModel
    @State private var hovered: String?
    @State private var dragging: Contact?

    private let columns = Array(repeating: GridItem(.fixed(50), spacing: 13), count: 5)

    var body: some View {
        let close = model.closeContacts
        VStack(spacing: 4) {
            LazyVGrid(columns: columns, spacing: 10) {
                AnyoneCircle(hovered: $hovered)
                ForEach(close) { contact in
                    CloseCircle(contact: contact, hovered: $hovered)
                        .onDrag {
                            dragging = contact
                            return NSItemProvider(object: contact.id as NSString)
                        }
                        .onDrop(of: [.text], delegate: CircleDrop(target: contact, dragging: $dragging, model: model))
                }
                Button {
                    if model.contacts.isEmpty {
                        model.route = .add(invite: nil)
                    } else {
                        model.onOpenBook(nil)
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(.faint)
                        .frame(width: 50, height: 50)
                        .overlay(Circle().strokeBorder(Color.starOff, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(model.contacts.isEmpty ? tr("Добавить по ссылке") : tr("Добавить кружок"))
                .accessibilityLabel(model.contacts.isEmpty ? tr("Добавить по ссылке") : tr("Добавить кружок"))
            }
            .padding(.top, 4)

            TimelineView(.periodic(from: .now, by: 10)) { context in
                caption(close, at: context.date)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .frame(height: 18)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func caption(_ close: [Contact], at now: Date) -> some View {
        // "Улетело" only right after: later in the hour it would be stale.
        let justSent = model.anyoneSentAt.map { now.timeIntervalSince($0) < 120 } ?? false
        if hovered == AnyoneCircle.id || (hovered == nil && model.sent == nil && justSent) {
            Text(justSent ? tr("Улетело кому-то ♥") : model.anyoneWait(at: now).map { tr("Кому-нибудь — через {n} мин", ["n": $0]) } ?? tr("Кому-нибудь на свете"))
                .foregroundColor(.muted)
        } else if let focus = close.first(where: { $0.id == (model.sent ?? hovered) }) {
            Text(model.sent == focus.id ? tr("{name} — улетело ♥", ["name": focus.label]) : focus.label)
                .foregroundColor(model.color(for: focus).deepColor)
        } else if close.isEmpty && !model.contacts.isEmpty {
            Text(tr("Нажми «+», чтобы добавить кружки"))
                .foregroundColor(.faint)
        } else {
            Text(" ")
        }
    }
}

/// Reorders the circles live while a dragged one passes over the others.
private struct CircleDrop: DropDelegate {
    let target: Contact
    @Binding var dragging: Contact?
    let model: AppModel

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging.id != target.id else { return }
        let (model, target) = (model, target)
        Task { @MainActor in
            withAnimation(.easeOut(duration: 0.15)) { model.move(dragging, to: target) }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

struct CloseCircle: View {
    @EnvironmentObject var model: AppModel
    let contact: Contact
    @Binding var hovered: String?

    var body: some View {
        let color = model.color(for: contact)
        let sent = model.sent == contact.id
        Button {
            model.send(contact)
        } label: {
            Text(sent ? "♥" : contact.label.first.map { String($0).uppercased() } ?? "♥")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(sent ? .paper : color.deepColor)
                .frame(width: 50, height: 50)
                .background(Circle().fill(sent ? color.ringColor : color.tintColor))
                .overlay(Circle().strokeBorder(color.ringColor, lineWidth: 3))
                .scaleEffect(sent || hovered == contact.id ? 1.08 : 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(contact.label)
        .accessibilityLabel(contact.label)
        .onHover { inside in
            if inside {
                hovered = contact.id
            } else if hovered == contact.id {
                hovered = nil
            }
        }
        .animation(.easeOut(duration: 0.15), value: sent)
        .animation(.easeOut(duration: 0.15), value: hovered)
    }
}

/// "23 человека", "2 человека", "5 человек".
func peopleCount(_ n: Int) -> String {
    trn("{n} человек", n)
}

struct SearchField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.faint)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.faint)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tr("Очистить"))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.field))
    }
}

// ---- book ---------------------------------------------------------------------

/// The book window: everyone on the left, "Рядом" first in their menu order
/// (those are the circles), the rest by name; the chosen one on the right.
/// Dragging a row over the line moves someone in or out of the circles.
struct BookView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var selection: BookSelection
    @State private var query = ""
    @State private var adding = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 260)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 620, idealWidth: 700, minHeight: 440, idealHeight: 540)
        .background(Color.paper)
    }

    // ---- the list

    /// One flat list with the two headings in it, so the system's own drag
    /// (with its insertion line) can carry someone across.
    private enum Item: Identifiable {
        case heading(near: Bool)
        case person(Contact)

        var id: String {
            switch self {
            case .heading(let near): return near ? "§near" : "§others"
            case .person(let contact): return contact.id
            }
        }
    }

    private var items: [Item] {
        [.heading(near: true)] + model.closeContacts.map(Item.person)
            + [.heading(near: false)] + model.contactsByName.filter { !$0.isClose }.map(Item.person)
    }

    private var picked: Binding<String?> {
        Binding(get: { selection.id }, set: { id in
            selection.id = id
            if id != nil { adding = false }
        })
    }

    private var sidebar: some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        return VStack(alignment: .leading, spacing: 4) {
            SearchField(text: $query, prompt: tr("Найти — {people}", ["people": peopleCount(model.contacts.count)]))
                .padding(.horizontal, 12)

            List(selection: picked) {
                if q.isEmpty {
                    ForEach(items) { item in
                        switch item {
                        case .heading(let near):
                            heading(near: near).moveDisabled(true)
                        case .person(let contact):
                            row(contact).tag(contact.id)
                        }
                    }
                    .onMove(perform: move)
                } else {
                    let found = model.contactsByName.filter { $0.label.localizedCaseInsensitiveContains(q) }
                    ForEach(found) { row($0).tag($0.id) }
                    if found.isEmpty {
                        Text(tr("Никого с таким именем"))
                            .font(.system(size: 12.5))
                            .foregroundColor(.muted)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .tint(.heart)

            VStack(alignment: .leading, spacing: 4) {
                LinkRow(symbol: "plus.circle", title: tr("Добавить по ссылке")) {
                    selection.id = nil
                    adding = true
                }
                Note(tr("Перетаскивай людей между «Рядом» и «Остальные». Порядок в «Рядом» — порядок кружков в меню."))
                    .padding(.horizontal, 4)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .padding(.top, 10)
    }

    private func heading(near: Bool) -> some View {
        let empty = near ? model.closeContacts.isEmpty : !model.contacts.contains { !$0.isClose }
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if near {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 8.5))
                        .foregroundColor(.heart)
                }
                Text(near ? tr("Рядом") : tr("Остальные"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(near ? .heartDeep : .muted)
                if near {
                    Text(tr("кружки в меню"))
                        .font(.system(size: 11))
                        .foregroundColor(.faint)
                }
            }
            if empty && !model.contacts.isEmpty {
                Text(near ? tr("Перетащи сюда тех, кому хочешь нажимать в один клик") : tr("Перетащи сюда, чтобы убрать кружок из меню"))
                    .font(.system(size: 11.5))
                    .foregroundColor(.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, near ? 2 : 12)
        .padding(.bottom, 2)
    }

    private func row(_ contact: Contact) -> some View {
        HStack(spacing: 10) {
            Avatar(label: contact.label, color: model.color(for: contact), size: 24)
            Text(contact.label)
                .font(.system(size: 13.5))
                .lineLimit(1)
        }
        .padding(.vertical, 3)
    }

    /// Where the row ended up decides it: above "Остальные" it is a circle,
    /// at that place among them; below, it leaves the menu.
    private func move(from source: IndexSet, to destination: Int) {
        let before = items
        guard let from = source.first, case .person(let person) = before[from] else { return }
        var after = before
        after.move(fromOffsets: source, toOffset: destination)
        guard let line = after.firstIndex(where: { $0.id == "§others" }),
              let at = after.firstIndex(where: { $0.id == person.id }) else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            if at < line {
                let index = after[..<at].filter { if case .person = $0 { return true } else { return false } }.count
                model.place(person, closeAt: index)
            } else {
                model.place(person, closeAt: nil)
            }
        }
    }

    // ---- the chosen one

    @ViewBuilder
    private var detail: some View {
        if adding {
            ScrollView {
                ContactForm(mode: .add(invite: nil)) {
                    adding = false
                    // addContact appends the new one.
                    selection.id = model.contacts.last?.id
                }
                .frame(maxWidth: 400, alignment: .leading)
                .padding(28)
            }
        } else if let contact = model.contacts.first(where: { $0.id == selection.id }) {
            PersonPage(contact: contact)
                // Another person: a fresh page, not the last one's edits.
                .id(contact.id)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "book")
                    .font(.system(size: 28))
                    .foregroundColor(.faint)
                Text(model.contacts.isEmpty ? tr("Пока никого нет") : tr("Выбери человека слева"))
                    .font(.system(size: 14, weight: .semibold))
                Text(model.contacts.isEmpty
                     ? tr("Добавь людей по их ссылке или поделись своим Love ID.")
                     : tr("Здесь меняются имя и цвет."))
                    .foregroundColor(.muted)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// One person in the book: the name to type over, the color, and removing.
/// Changes save by themselves, so there is no Save button.
struct PersonPage: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var selection: BookSelection
    let contact: Contact
    @State private var name = ""
    @State private var color = 0
    @State private var status = Status.idle
    @State private var confirmDelete = false
    @State private var error: String?
    @State private var typing: Task<Void, Never>?
    @FocusState private var nameFocused: Bool

    enum Status { case idle, saving, saved }

    var body: some View {
        let palette = Palette.at(color)
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 14) {
                Avatar(label: label.isEmpty ? contact.label : label, color: palette, size: 52)
                VStack(alignment: .leading, spacing: 4) {
                    TextField(tr("Имя"), text: $name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 22, weight: .bold))
                        .focused($nameFocused)
                        .onSubmit(save)
                    Capsule()
                        .fill(nameFocused ? palette.ringColor : Color.hairline)
                        .frame(height: nameFocused ? 2 : 1)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Caption(tr("Цвет"))
                    Spacer()
                    Text(palette.name)
                        .font(.system(size: 12))
                        .foregroundColor(palette.deepColor)
                }
                SwatchPicker(selection: $color, size: 26)
            }

            Note(tr("{name} не увидит ни имя, ни цвет: их видишь только ты.", ["name": label.isEmpty ? contact.label : label]))

            Spacer(minLength: 0)

            if let error {
                Text(error).font(.system(size: 12)).foregroundColor(.danger)
            }

            HStack(spacing: 8) {
                if confirmDelete {
                    Text(tr("Удалить из книги?"))
                        .font(.system(size: 12.5))
                        .foregroundColor(.muted)
                    Button(tr("Отмена")) { confirmDelete = false }
                        .buttonStyle(PillButton())
                    Button(tr("Удалить"), action: remove)
                        .buttonStyle(PillButton(danger: true))
                } else {
                    Button { confirmDelete = true } label: {
                        Label(tr("Удалить из книги"), systemImage: "trash")
                            .font(.system(size: 12.5))
                            .foregroundColor(.danger.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Group {
                    switch status {
                    case .idle: EmptyView()
                    case .saving: Text(tr("Сохраняем…"))
                    case .saved: Label(tr("Сохранено"), systemImage: "checkmark")
                    }
                }
                .font(.system(size: 12))
                .foregroundColor(.faint)
            }
            .animation(.easeOut(duration: 0.15), value: confirmDelete)
        }
        .padding(28)
        .frame(maxWidth: 460, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            name = contact.label
            color = colorIndex(contact)
        }
        .onChange(of: name) { _ in
            typing?.cancel()
            typing = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 700_000_000)
                if !Task.isCancelled { save() }
            }
        }
        .onChange(of: color) { _ in save() }
        .onDisappear {
            typing?.cancel()
            save()
        }
    }

    private var label: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    private func colorIndex(_ contact: Contact) -> Int {
        Palette.all.indices.first { Palette.at($0).color == model.color(for: contact).color } ?? 0
    }

    private func save() {
        guard (1...64).contains(label.count),
              let current = model.contacts.first(where: { $0.id == contact.id }),
              label != current.label || color != colorIndex(current) else { return }
        let (label, color) = (label, color)
        status = .saving
        error = nil
        Task { @MainActor in
            do {
                try await model.updateContact(current, label: label, color: color, close: current.isClose)
                status = .saved
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if status == .saved { status = .idle }
            } catch {
                self.error = tr("Не получилось сохранить")
                status = .idle
            }
        }
    }

    private func remove() {
        guard let current = model.contacts.first(where: { $0.id == contact.id }) else { return }
        typing?.cancel()
        Task { @MainActor in
            do {
                try await model.remove(current)
                selection.id = nil
            } catch {
                self.error = tr("Не получилось удалить")
            }
        }
    }
}

/// A small rounded button for the book's quieter actions.
struct PillButton: ButtonStyle {
    var danger = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundColor(danger ? .paper : .ink)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(Capsule().fill(danger ? Color.danger : Color.field))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Capsule())
    }
}

struct Avatar: View {
    let label: String
    let color: PaletteColor
    let size: CGFloat

    var body: some View {
        Text(label.first.map { String($0).uppercased() } ?? "♥")
            .font(.system(size: size * 0.41, weight: .bold))
            .foregroundColor(color.deepColor)
            .frame(width: size, height: size)
            .background(Circle().fill(Color.paper))
            .overlay(Circle().strokeBorder(color.ringColor, lineWidth: 2.5))
    }
}

// ---- sign in ------------------------------------------------------------------

struct SignInView: View {
    @EnvironmentObject var model: AppModel
    @State private var withEmail = false
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    /// What went wrong: in red, right under the button.
    @State private var message: String?
    /// Good news, e.g. the reset email went out.
    @State private var notice: String?

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 10) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.heart)
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(Color.heartSoft))
                Text(tr("Привет!"))
                    .font(.system(size: 17, weight: .bold))
                Text(tr("Думаешь о ком-то? Нажми, и он почувствует, что его любят и он нужен. А от кого, не узнает."))
                    .multilineTextAlignment(.center)
                    .foregroundColor(.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 8)

            if withEmail {
                VStack(alignment: .leading, spacing: 10) {
                    Field(title: tr("Почта")) {
                        TextField("you@example.com", text: $email)
                            .textContentType(.username)
                    }
                    Field(title: tr("Пароль")) {
                        SecureField(tr("Не меньше 8 символов"), text: $password)
                            .textContentType(.password)
                            .onSubmit(submit)
                    }
                    Button(busy ? tr("Входим…") : tr("Войти или создать аккаунт"), action: submit)
                        .buttonStyle(PrimaryButton())
                        .disabled(busy)
                    errorLine
                    HStack {
                        Button(tr("← Назад")) { withEmail = false; message = nil; notice = nil }
                            .buttonStyle(.plain)
                            .foregroundColor(.muted)
                        Spacer()
                        Button(tr("Забыли пароль?"), action: reset)
                            .buttonStyle(.plain)
                            .foregroundColor(.link)
                    }
                    .font(.system(size: 12.5))
                }
            } else {
                VStack(spacing: 8) {
                    Button {
                        message = nil
                        notice = nil
                        model.signInWithGoogle()
                    } label: {
                        Label(model.waitingForBrowser ? tr("Продолжи в браузере…") : tr("Войти через Google"), systemImage: "globe")
                    }
                    .buttonStyle(PrimaryButton())
                    Button(tr("Войти по почте")) { withEmail = true; message = nil; notice = nil }
                        .buttonStyle(SecondaryButton())
                    errorLine
                }
            }

            if let notice {
                Text(notice)
                    .font(.system(size: 12))
                    .foregroundColor(.ok)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            HStack {
                Text(tr("Вход через Apple появится позже"))
                Spacer()
                Button(tr("Закрыть")) { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
            }
            .font(.system(size: 12.5))
            .foregroundColor(.muted)
        }
    }

    @ViewBuilder private var errorLine: some View {
        if let text = message ?? model.problem {
            Label(text, systemImage: "exclamationmark.circle.fill")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundColor(.danger)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func submit() {
        let email = email.trimmingCharacters(in: .whitespaces)
        guard !email.isEmpty else { message = tr("Введи почту"); return }
        guard email.contains("@") else { message = tr("Проверь адрес почты"); return }
        guard password.count >= 8 else { message = tr("Пароль нужен не короче 8 символов"); return }
        busy = true
        message = nil
        notice = nil
        Task {
            do {
                try await model.signIn(email: email, password: password)
                password = ""
            } catch {
                message = error.localizedDescription
            }
            busy = false
        }
    }

    private func reset() {
        let email = email.trimmingCharacters(in: .whitespaces)
        guard !email.isEmpty else { message = tr("Сначала введи почту"); return }
        message = nil
        notice = nil
        Task {
            do {
                try await model.sendPasswordReset(email: email)
                notice = tr("Письмо для нового пароля отправлено")
            } catch {
                message = error.localizedDescription
            }
        }
    }
}

// ---- add / edit a contact -----------------------------------------------------

struct ContactForm: View {
    enum Mode {
        case add(invite: String?)
        case edit(Contact)
    }

    /// The server never says whether a code belongs to anyone (so codes
    /// can't be probed): only its shape is checked here.
    enum Lookup: Equatable {
        case idle, invalid
        /// The code to add by.
        case ready(String)
    }

    @EnvironmentObject var model: AppModel
    let mode: Mode
    /// Back, after adding, after removing: the popover returns to the menu.
    /// Without it (editing in the book window) the form has no back button
    /// and stays after saving.
    var onDone: (() -> Void)?
    @State private var link = ""
    @State private var name = ""
    @State private var color = 0
    @State private var close = true
    @State private var lookup = Lookup.idle
    @State private var busy = false
    @State private var error: String?
    @State private var confirmDelete = false
    @State private var saved = false

    private var editing: Contact? {
        if case .edit(let contact) = mode { return contact }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let onDone {
                HStack(spacing: 6) {
                    IconButton(symbol: "chevron.left", help: tr("Назад"), action: onDone)
                    Text(editing == nil ? tr("Новый человек") : tr("Изменить"))
                        .font(.system(size: 15, weight: .semibold))
                }
            }

            if editing == nil {
                Field(title: tr("Ссылка-приглашение")) {
                    TextField("lovearound.me/i/…", text: $link)
                }
                lookupNote
                    .font(.system(size: 12.5))
                    .padding(.top, -6)
            }

            Field(title: tr("Как назовёшь?")) {
                TextField(tr("Например, Мама"), text: $name)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Caption(tr("Цвет"))
                    Spacer()
                    Text(Palette.at(color).name)
                        .font(.system(size: 12))
                        .foregroundColor(Palette.at(color).deepColor)
                }
                SwatchPicker(selection: $color, size: 30)
            }

            if let contact = editing {
                if confirmDelete {
                    Text(tr("Удалить «{name}» из книги?", ["name": contact.label]))
                        .font(.system(size: 12.5))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button(tr("Отмена")) { confirmDelete = false }
                            .buttonStyle(SecondaryButton())
                        Button { remove(contact) } label: { Text(tr("Удалить")).foregroundColor(.danger) }
                            .buttonStyle(SecondaryButton())
                    }
                } else {
                    // The same size side by side; deleting is the quieter one and asks first.
                    HStack(spacing: 10) {
                        Button { confirmDelete = true } label: { Text(tr("Удалить")).foregroundColor(.danger) }
                            .buttonStyle(SecondaryButton())
                        saveButton
                    }
                }
            } else {
                saveButton
            }

            if let error {
                Text(error).font(.system(size: 12)).foregroundColor(.danger)
            }

            if editing == nil {
                Text(tr("{name} не увидит ни имя, ни цвет. Кружки можно переставлять перетаскиванием.", ["name": label.isEmpty ? tr("Человек") : label]))
                    .font(.system(size: 11.5))
                    .foregroundColor(.faint)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, -4)
            }
        }
        .onAppear {
            switch mode {
            case .add(let invite):
                // Copied from a message a moment ago: no need to paste it.
                if let invite = invite ?? model.pastedInvite { link = "\(Config.site)/i/\(invite)" }
                color = model.nextColor
                close = model.newContactIsClose
            case .edit(let contact):
                name = contact.label
                close = contact.isClose
                color = Palette.all.indices.first { Palette.at($0).color == model.color(for: contact).color } ?? 0
            }
        }
        .onChange(of: link) { link in
            guard editing == nil else { return }
            if link.trimmingCharacters(in: .whitespaces).isEmpty {
                lookup = .idle
            } else if let code = AppModel.inviteID(from: link) {
                lookup = .ready(code)
            } else {
                lookup = .invalid
            }
        }
    }

    private var label: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    private var saveButton: some View {
        Button(busy ? tr("Сохраняем…") : saved ? tr("Сохранено ✓") : (editing == nil ? tr("Добавить") : tr("Сохранить")), action: save)
            .buttonStyle(PrimaryButton())
            .disabled(!canSave || busy)
    }

    /// A circle on top of the menu: for someone in the book, as they are there now.
    private var inCircles: Bool {
        guard let contact = editing else { return close }
        return model.contacts.first { $0.id == contact.id }?.isClose ?? contact.isClose
    }

    private var canSave: Bool {
        guard (1...64).contains(label.count) else { return false }
        if editing != nil { return true }
        if case .ready = lookup { return true }
        return false
    }

    @ViewBuilder
    private var lookupNote: some View {
        switch lookup {
        case .idle:
            Text(tr("Вставь ссылку, которую тебе прислали")).foregroundColor(.faint)
        case .invalid:
            Text(tr("Не похоже на ссылку-приглашение")).foregroundColor(.muted)
        case .ready:
            Label(tr("Ссылка в порядке. Осталось подписать."), systemImage: "checkmark").foregroundColor(.ok)
        }
    }

    private func save() {
        busy = true
        error = nil
        Task {
            do {
                if let contact = editing {
                    // Where they are is the book's drag, not this form's.
                    try await model.updateContact(contact, label: label, color: color, close: inCircles)
                } else if case .ready(let code) = lookup {
                    try await model.addContact(code: code, label: label, color: color, close: close)
                }
                if let onDone {
                    onDone()
                } else {
                    busy = false
                    saved = true
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    saved = false
                }
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }

    private func remove(_ contact: Contact) {
        Task {
            do {
                try await model.remove(contact)
                onDone?()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// ---- settings -----------------------------------------------------------------

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmDelete = false
    @State private var error: String?
    @State private var tab = Strings.reopenSettings ? SettingsTab.account : SettingsTab.signal

    /// The window takes the height of the tab shown.
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Tabs(selection: $tab)

            switch tab {
            case .signal: signalTab
            case .when: whenTab
            case .devices: DevicesView()
            case .account: account
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 20)
        .frame(width: 420, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.paper)
        // Back for a device token that is shown only once.
        .onAppear { if model.createdDevice != nil { tab = .devices } }
    }

    /// What an incoming signal looks like.
    @ViewBuilder private var signalTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Caption(tr("Мой цвет сигнала"))
            SwatchPicker(selection: $model.myColor, size: 30)
            Note(tr("Этим цветом светятся края экрана, когда кто-то о тебе думает."))
        }

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Caption(tr("Смайликов за раз"))
                Spacer()
                Text(model.emojiCount == 0 ? tr("только свет") : "\(model.emojiCount)")
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
            }
            Slider(value: emojiStep, in: 0...Double(AppModel.maxEmoji), step: 2)
                .controlSize(.small)
                .tint(.heart)
                .disabled(model.calm)
            if model.calm {
                Note(tr("С «Без мигания и полёта» смайлики не летают."))
            }
        }

        VStack(spacing: 0) {
            SwitchRow(title: tr("Тихий звук"), isOn: $model.sound)
            SwitchRow(title: tr("Без мигания и полёта"), isOn: $model.calm)
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.field))

        Button {
            model.playEffect()
        } label: {
            Label(tr("Показать, как это выглядит"), systemImage: "play.fill")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundColor(.heartDeep)
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.heartSoft))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// When signals are shown at all.
    @ViewBuilder private var whenTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Caption(model.isPaused ? model.pauseText : tr("Пауза"))
            HStack(spacing: 6) {
                if model.isPaused {
                    Button(tr("Снять паузу")) { model.resume() }.buttonStyle(SmallButton())
                } else {
                    Button(tr("На час")) { model.pause(.hour) }.buttonStyle(SmallButton())
                    Button(tr("До утра")) { model.pause(.untilMorning) }.buttonStyle(SmallButton())
                    Button(tr("Пока не сниму")) { model.pause(.untilResumed) }.buttonStyle(SmallButton())
                }
            }
        }

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Caption(tr("Свечение не чаще раза в"))
                Spacer()
                Text(AppModel.gapTitle(model.minGap))
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
            }
            Slider(value: gapStep, in: 0...Double(AppModel.gaps.count - 1), step: 1)
                .controlSize(.small)
                .tint(.heart)
            Note(tr("Если о тебе думают часто, сигналы между вспышками не покажутся."))
        }

        VStack(spacing: 0) {
            SwitchRow(title: tr("Тихо, когда что-то на весь экран"), isOn: $model.quietWhenPresenting)
            SwitchRow(title: tr("Запускать при входе в Mac"),
                      isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.field))

        VStack(alignment: .leading, spacing: 6) {
            SwitchRow(title: tr("Сердечки от кого-нибудь на свете"), isOn: $model.acceptAnyone)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.anyone[2]))
            Note(tr("Кто-то где-то нажал «Кому-нибудь на свете», и сердечко может прилететь тебе. Бывает редко, тем и приятнее."))
        }
    }

    /// Who is signed in, the Love ID, and removing the account at the bottom.
    @ViewBuilder private var account: some View {
        HStack(spacing: 12) {
            Avatar(label: model.email ?? "", color: Palette.at(model.myColor), size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.email ?? "")
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(tr("Книга хранится в аккаунте"))
                    .font(.system(size: 11.5))
                    .foregroundColor(.faint)
            }
            Spacer(minLength: 8)
            Button(tr("Выйти")) { model.signOut() }
                .buttonStyle(SmallButton())
                .frame(width: 76)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.field))

        VStack(alignment: .leading, spacing: 6) {
            InviteRow()
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.field))
            Note(tr("Отправь его тем, кто хочет нажимать, когда думает о тебе."))
        }

        Divider()

        VStack(alignment: .leading, spacing: 8) {
            if confirmDelete {
                Text(tr("Удалить аккаунт и весь список? Это навсегда."))
                    .font(.system(size: 12.5, weight: .semibold))
                HStack(spacing: 8) {
                    Button(tr("Не удалять")) { confirmDelete = false }.buttonStyle(SmallButton())
                    Button(action: deleteAccount) {
                        Text(tr("Удалить навсегда")).foregroundColor(.danger)
                    }
                    .buttonStyle(SmallButton())
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tr("Удалить аккаунт")).font(.system(size: 13.5))
                        Note(tr("Вместе с книгой, устройствами и Love ID."))
                    }
                    Spacer()
                    Button(tr("Удалить…")) { confirmDelete = true }
                        .buttonStyle(.plain)
                        .foregroundColor(.danger)
                }
            }
            if let error {
                Text(error).font(.system(size: 12)).foregroundColor(.danger)
            }
        }

        HStack {
            Text(tr("Язык")).font(.system(size: 13.5))
            Spacer()
            Picker("", selection: Binding(
                get: { UserDefaults.standard.string(forKey: Strings.defaultsKey) ?? "" },
                set: { Strings.choose($0) }
            )) {
                Text(tr("Как в системе")).tag("")
                ForEach(Strings.languages, id: \.code) { language in
                    Text(language.name).tag(language.code)
                }
            }
            .labelsHidden()
            .fixedSize()
        }

        Text("Love Around \(model.version)")
            .font(.system(size: 11.5))
            .foregroundColor(.faint)
            .frame(maxWidth: .infinity)
            .textSelection(.enabled)
    }

    private var emojiStep: Binding<Double> {
        Binding(
            get: { Double(model.emojiCount) },
            set: { model.emojiCount = Int($0.rounded()) }
        )
    }

    /// The slider moves by steps of `AppModel.gaps`, not by seconds.
    private var gapStep: Binding<Double> {
        Binding(
            get: { Double(AppModel.gapIndex(model.minGap)) },
            set: { model.minGap = AppModel.gaps[Int($0.rounded())] }
        )
    }

    private func deleteAccount() {
        Task {
            do {
                try await model.deleteAccount()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// ---- pieces -------------------------------------------------------------------

enum SettingsTab: CaseIterable {
    case signal, when, devices, account

    var title: String {
        switch self {
        case .signal: return tr("Сигнал")
        case .when: return tr("Когда")
        case .devices: return tr("Устройства")
        case .account: return tr("Аккаунт")
        }
    }
}

/// Settings sections as a segmented row in the menu's own colors.
struct Tabs: View {
    @Binding var selection: SettingsTab

    var body: some View {
        HStack(spacing: 4) {
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                let on = selection == tab
                Button { selection = tab } label: {
                    Text(tab.title)
                        .font(.system(size: 13, weight: on ? .semibold : .regular))
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(on ? Color.raised : Color.clear)
                                .shadow(color: on ? Color.ink.opacity(0.2) : .clear, radius: 1.5, y: 1)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.well))
    }
}

/// The small grey explanation under a setting.
struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundColor(.faint)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct SwatchPicker: View {
    @Binding var selection: Int
    let size: CGFloat

    var body: some View {
        // Twelve colors: two rows of six fit the popover's 302 pt.
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(size + 6), spacing: 10), count: 6), alignment: .leading, spacing: 6) {
            ForEach(Palette.all.indices, id: \.self) { index in
                let p = Palette.all[index]
                Button { selection = index } label: {
                    Circle()
                        .fill(p.ringColor)
                        .frame(width: size, height: size)
                        .padding(3)
                        .overlay(Circle().strokeBorder(p.ringColor, lineWidth: selection == index ? 2 : 0))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(p.name)
                .accessibilityLabel(p.name)
                .accessibilityAddTraits(selection == index ? .isSelected : [])
            }
        }
        .padding(.leading, -3)
    }
}

struct Field<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Caption(title)
            content
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.input))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.hairline))
        }
    }
}

struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundColor(.muted)
    }
}

struct SwitchRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        // Title on the left, switch on the right edge, whatever the title's length.
        HStack(spacing: 8) {
            Text(title).font(.system(size: 13.5))
            Spacer(minLength: 0)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(.switchOn)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .frame(height: 40)
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

struct LinkRow: View {
    let symbol: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 18)
                Text(title)
                Spacer()
            }
            .font(.system(size: 13.5))
            .foregroundColor(.link)
            .frame(height: 28)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct PrimaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.paper)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.ink.opacity(configuration.isPressed ? 0.85 : 1)))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
    }
}

struct SecondaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 10).fill(configuration.isPressed ? Color.field : Color.paper))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.hairline))
            .contentShape(Rectangle())
    }
}

struct SmallButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5))
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8).fill(configuration.isPressed ? Color.field : Color.paper))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.hairline))
            .contentShape(Rectangle())
    }
}
