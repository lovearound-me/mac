import AppKit
import SwiftUI

/// Settings → Устройства: tokens for a toy, a lamp or any board that
/// receives signals or sends them. How to wire one up: Config.site/docs.
struct DevicesView: View {
    @EnvironmentObject var model: AppModel
    @State private var devices: [Device] = []
    @State private var name = ""
    @State private var receive = true
    @State private var send = true
    @State private var busy = false
    @State private var error: String?
    @State private var confirmRemove: String?
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // The token of the device just created: shown once, never again.
            if let created = model.createdDevice {
                tokenCard(created)
            } else {
                Text(tr("Игрушка, лампа или своя плата, которая светится, когда о тебе думают, или отправляет сердечко по кнопке."))
                    .font(.system(size: 12.5))
                    .foregroundColor(.muted)
                    .fixedSize(horizontal: false, vertical: true)
                addForm
            }

            if !devices.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Caption(tr("Подключены"))
                    ForEach(devices) { device in
                        row(device)
                    }
                }
            }

            if let error {
                Text(error).font(.system(size: 12)).foregroundColor(.danger)
            }

            LinkRow(symbol: "book", title: tr("Как подключить свою плату")) {
                NSWorkspace.shared.open(URL(string: "\(Config.site)/docs")!)
            }
        }
        .task { await load() }
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Field(title: tr("Название")) {
                TextField(tr("Например, Котик на полке"), text: $name)
            }
            VStack(spacing: 0) {
                SwitchRow(title: tr("Принимает сердечки"), isOn: $receive)
                SwitchRow(title: tr("Отправляет сердечки"), isOn: $send)
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.field))
            Button(busy ? tr("Подключаем…") : tr("Подключить устройство"), action: add)
                .buttonStyle(PrimaryButton())
                .disabled(busy || !(1...64).contains(trimmedName.count) || !(receive || send))
        }
    }

    private func tokenCard(_ created: (name: String, token: String)) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(tr("«{name}» подключено", ["name": created.name]), systemImage: "checkmark").foregroundColor(.ok)
            Text(created.token)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.input))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.hairline))
            Text(tr("Это токен устройства. Мы покажем его только сейчас: скопируй и вставь в прошивку. С ним можно отправлять сердечки от твоего имени, так что никому не показывай."))
                .font(.system(size: 11.5))
                .foregroundColor(.faint)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(copied == created.token ? tr("Скопировано") : tr("Скопировать токен")) { copy(created.token) }
                    .buttonStyle(PrimaryButton())
                Button(tr("Готово")) { model.createdDevice = nil }
                    .buttonStyle(SecondaryButton())
            }
        }
    }

    private func row(_ device: Device) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).font(.system(size: 13.5, weight: .medium)).lineLimit(1)
                Text(details(device)).font(.system(size: 11.5)).foregroundColor(.faint).lineLimit(1)
            }
            Spacer()
            if confirmRemove == device.id {
                Button(tr("Нет")) { confirmRemove = nil }.buttonStyle(.plain).foregroundColor(.muted)
                Button(tr("Отключить")) { remove(device) }.buttonStyle(.plain).foregroundColor(.danger)
            } else {
                IconButton(symbol: "trash", help: tr("Отключить")) { confirmRemove = device.id }
                    .foregroundColor(.muted)
            }
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 10)
        .frame(height: 46)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.field))
    }

    private func details(_ device: Device) -> String {
        let (receives, sends) = (device.capabilities.contains("receive"), device.capabilities.contains("send"))
        var text = receives && sends ? tr("Принимает и отправляет") : receives ? tr("Принимает") : sends ? tr("Отправляет") : ""
        if let seen = device.last_seen_at.flatMap(Self.parse) {
            let ago = RelativeDateTimeFormatter()
            ago.locale = Strings.locale
            ago.dateTimeStyle = .named
            text += tr(" · был онлайн {ago}", ["ago": ago.localizedString(for: seen, relativeTo: Date())])
        } else {
            text += tr(" · ещё не подключался")
        }
        return text
    }

    private static func parse(_ text: String) -> Date? {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return format.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    private func load() async {
        do {
            devices = try await model.api.devices()
            error = nil
        } catch {
            self.error = tr("Не получилось загрузить устройства")
        }
    }

    private func add() {
        busy = true
        error = nil
        let capabilities = [receive ? "receive" : nil, send ? "send" : nil].compactMap { $0 }
        Task {
            do {
                let (device, token) = try await model.api.addDevice(name: trimmedName, capabilities: capabilities)
                devices.append(device)
                model.createdDevice = (device.name, token)
                name = ""
            } catch APIError.status(409, _) {
                error = tr("Устройств уже много, отключи лишние")
            } catch {
                self.error = tr("Не получилось, попробуй ещё раз")
            }
            busy = false
        }
    }

    private func remove(_ device: Device) {
        Task {
            do {
                try await model.api.deleteDevice(device.id)
                devices.removeAll { $0.id == device.id }
                confirmRemove = nil
            } catch {
                self.error = tr("Не получилось отключить, попробуй ещё раз")
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = text
    }
}

private extension String {
    var capitalizedFirst: String {
        prefix(1).uppercased() + dropFirst()
    }
}
