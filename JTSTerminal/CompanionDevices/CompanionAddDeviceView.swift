#if ENABLE_RDP_2
import SwiftUI
import JTSCompanionDevices

struct CompanionAddDeviceView: View {
    let model: CompanionDevicesModel
    let language: AppLanguage
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var relay = ""
    @State private var publicKey = ""
    @State private var compatibility = false
    @State private var enrollmentBundle = ""
    private func t(_ en: String, _ zh: String) -> String { language.localized(en, zh) }
    private var key: Data? {
        let text = publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= 1024 else { return nil }
        return Data(base64Encoded: text)
    }
    private var fingerprint: String? { key.flatMap { try? CompanionDeviceRegistry.peerDeviceID(forSPKI: $0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(t("Verify a Windows identity", "核对 Windows 身份")).font(.title2)
            Form {
                VStack(alignment: .leading, spacing: 6) {
                    Text(t("Windows public enrollment bundle", "Windows 公开配对包"))
                    TextEditor(text: $enrollmentBundle).font(.body.monospaced()).frame(height: 72)
                    Text(t("Paste the public JSON exported by the Windows installer to fill these fields. AI-enabled targets can import and bind it directly with jts_device_status.",
                           "粘贴 Windows 安装器导出的公开 JSON，自动填写下方信息。已允许 AI 控制的目标可由 jts_device_status 直接导入并绑定。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                TextField(t("Device name", "设备名称"), text: $name)
                TextField(t("Relay HTTPS address", "中继 HTTPS 地址"), text: $relay, prompt: Text("https://relay.example.com"))
                VStack(alignment: .leading, spacing: 6) {
                    Text(t("Windows public key (SPKI Base64)", "Windows 公钥（SPKI Base64）"))
                    TextEditor(text: $publicKey).font(.body.monospaced()).frame(minHeight: 64, maxHeight: 96)
                        .accessibilityLabel(t("Windows public key", "Windows 公钥"))
                    Text(t("Copy it directly from the Windows Companion. Do not obtain trusted identity from relay discovery.",
                           "请直接从 Windows Companion 复制，不要把中继发现的信息作为可信身份。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let fingerprint {
                    LabeledContent(t("Fingerprint to compare", "待核对的指纹")) {
                        Text(fingerprint).font(.caption.monospaced()).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if !publicKey.isEmpty {
                    Text(t("Enter a canonical P-256 SPKI public key in Base64.", "请输入 Base64 编码的标准 P-256 SPKI 公钥。"))
                        .foregroundStyle(.red).font(.caption)
                }
                Toggle(t("Windows 10 ESU: explicitly allow TLS 1.2", "Windows 10 ESU：明确允许 TLS 1.2"), isOn: $compatibility)
            }.formStyle(.grouped)
            Text(t("This saves the Windows public identity. Existing AI desktop control includes delegated pairing. Relay HTTPS/WSS stays encrypted and skips server certificate validation by default. End-to-end TLS still pins the Windows identity.",
                   "此处保存 Windows 公开身份。已有的 AI 桌面控制授权包含配对委托。中继 HTTPS/WSS 保持加密，默认不校验服务端证书；端到端 TLS 仍校验固定的 Windows 身份。"))
                .font(.caption).foregroundStyle(.secondary)
            if let code = model.errorCode { Text(code).font(.caption.monospaced()).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(t("Cancel", "取消")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.busy)
                Button(t("Save local trust", "保存本机信任")) {
                    guard let key, let fingerprint else { return }
                    Task {
                        if await model.add(name: name, relayURL: relay, peerSPKI: key, compatibility: compatibility, verifiedID: fingerprint) {
                            dismiss()
                        }
                    }
                }.keyboardShortcut(.defaultAction)
                    .disabled(model.busy || fingerprint == nil || name.trimmingCharacters(in: .whitespaces).isEmpty || relay.isEmpty)
            }
        }.padding(22).frame(width: 620)
            .interactiveDismissDisabled(model.busy)
            .onChange(of: enrollmentBundle) { _, value in
                guard value.utf8.count <= 16384, let bytes = value.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                      let bundle = try? CompanionPublicEnrollment(json) else { return }
                name = bundle.name; relay = bundle.relayURL
                publicKey = bundle.peerSPKI.base64EncodedString(); compatibility = bundle.compatibility
            }
    }
}
#endif
