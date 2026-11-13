import SwiftUI

/// The device key, generated keys, and imported OpenSSH private keys, each
/// with an optional user certificate.
struct KeysScreen: View {
    let app: AppModel
    @State private var adding: Adding?
    @State private var failure: String?

    enum Adding: String, Identifiable {
        case generate, generateRSA, importKey
        var id: String { rawValue }
    }

    var body: some View {
        List {
            ForEach(app.keychain.identities.sorted { ($0.isDevice ? 0 : 1, $0.created) < ($1.isDevice ? 0 : 1, $1.created) }) { identity in
                NavigationLink {
                    IdentityScreen(app: app, identity: identity)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(identity.name)
                            if identity.certificate != nil { Image(systemName: "checkmark.seal").foregroundStyle(.tint) }
                        }
                        Text("\(identity.algorithm) · \(identity.fingerprint)").font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            if let failure { Text(failure).foregroundStyle(.red) }
        }
        .navigationTitle("Keys & certificates")
        .toolbar {
            Menu("Add key", systemImage: "plus") {
                Button("Generate Ed25519 key", systemImage: "wand.and.stars") { adding = .generate }
                Button("Generate RSA key", systemImage: "key.horizontal") { adding = .generateRSA }
                Button("Import private key", systemImage: "square.and.arrow.down") { adding = .importKey }
            }
        }
        .sheet(item: $adding) { kind in
            AddKeySheet(app: app, kind: kind)
        }
        .task {
            do { _ = try app.keychain.deviceIdentity(name: String(localized: "This device")) } catch { failure = error.localizedDescription }
        }
    }
}

private struct AddKeySheet: View {
    let app: AppModel
    let kind: KeysScreen.Adding
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var text = ""
    @State private var passphrase = ""
    @State private var bits = 3072
    @State private var picking = false
    @State private var working = false
    @State private var failure: String?
    @State private var created: Identity?

    var body: some View {
        NavigationStack {
            if let created {
                CreatedKeyView(identity: created) { dismiss() }
            } else {
                form
            }
        }
    }

    private var form: some View {
        Form {
            TextField("Name", text: $name)
            if kind == .generateRSA {
                Section {
                    Picker("Key size", selection: $bits) {
                        Text("2048 bits").tag(2048)
                        Text("3072 bits").tag(3072)
                        Text("4096 bits").tag(4096)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("RSA key size")
                } footer: {
                    Text("3072 bits is the default. The keypair is generated on this device.")
                }
            }
            if kind == .importKey {
                Section {
                    TextEditor(text: $text)
                        .font(.caption.monospaced()).frame(minHeight: 160)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                    Button("Choose file…", systemImage: "folder") { picking = true }
                } header: {
                    Text("OpenSSH private key")
                } footer: {
                    Text("RSA, ECDSA, or Ed25519. The passphrase is used once to decrypt; the key is kept in this device's keychain.")
                }
                SecureField("Passphrase (if any)", text: $passphrase)
            }
            if working {
                ProgressView("Generating RSA key…")
            }
            if let failure { Text(failure).foregroundStyle(.red) }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel", role: .cancel) { dismiss() }.disabled(working) }
            ToolbarItem(placement: .confirmationAction) {
                Button(confirm, action: add)
                    .disabled(working || name.trimmingCharacters(in: .whitespaces).isEmpty || (kind == .importKey && text.isEmpty))
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.data, .plainText]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let contents = try? String(contentsOf: url, encoding: .utf8) {
                text = contents
                if name.isEmpty { name = url.deletingPathExtension().lastPathComponent }
            }
        }
    }

    private var title: String {
        switch kind {
        case .generate: "Generate key"
        case .generateRSA: "Generate RSA key"
        case .importKey: "Import key"
        }
    }

    private var confirm: String {
        switch kind {
        case .generate, .generateRSA: "Generate"
        case .importKey: "Import"
        }
    }

    private func add() {
        let name = name.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .generate:
            do {
                _ = try app.keychain.generate(name: name)
                dismiss()
            } catch {
                failure = error.localizedDescription
            }
        case .generateRSA:
            working = true
            failure = nil
            Task { @MainActor in
                do {
                    created = try await app.keychain.generateRSA(name: name, bits: bits)
                } catch {
                    failure = error.localizedDescription
                }
                working = false
            }
        case .importKey:
            do {
                _ = try app.keychain.importKey(name: name, text: text, passphrase: passphrase.isEmpty ? nil : passphrase)
                dismiss()
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

/// Shown right after an RSA key is made: its authorized_keys line is ready
/// to copy or export, while the private half stays in the Keychain.
private struct CreatedKeyView: View {
    let identity: Identity
    let done: () -> Void

    var body: some View {
        Form {
            Section {
                Label("Key created", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                Text(identity.name)
            }
            PublicKeyActions(identity: identity)
        }
        .navigationTitle("RSA key")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done", action: done) }
        }
    }
}

private struct PublicKeyActions: View {
    let identity: Identity

    var body: some View {
        Section {
            Text(identity.publicKey).font(.caption.monospaced()).textSelection(.enabled)
            Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = identity.publicKey }
            ShareLink(item: exportURL) {
                Label("Export .pub file", systemImage: "square.and.arrow.up")
            }
        } header: {
            Text("Public key")
        } footer: {
            Text("Add this line to ~/.ssh/authorized_keys on each host.")
        }
    }

    /// A file URL for the share sheet; the private key is not part of it.
    private var exportURL: URL {
        let base = identity.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = base.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
        let stem = cleaned.isEmpty ? "key" : cleaned
        let filename = stem.lowercased().hasSuffix(".pub") ? stem : "\(stem).pub"
        let url = FileManager.default.temporaryDirectory.appending(path: filename)
        try? Data((identity.publicKey + "\n").utf8).write(to: url, options: .atomic)
        return url
    }
}

/// One key: its public half to install on hosts, and its certificate.
private struct IdentityScreen: View {
    let app: AppModel
    let identity: Identity
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var certificate: String
    @State private var info: CertificateInfo?
    @State private var failure: String?
    @State private var deleting = false

    init(app: AppModel, identity: Identity) {
        self.app = app
        self.identity = identity
        _name = State(initialValue: identity.name)
        _certificate = State(initialValue: identity.certificate ?? "")
    }

    var body: some View {
        Form {
            if !identity.isDevice {
                TextField("Name", text: $name).onSubmit { app.keychain.rename(id: identity.id, to: name) }
            }
            PublicKeyActions(identity: identity)
            Section {
                TextEditor(text: $certificate)
                    .font(.caption.monospaced()).frame(minHeight: 100)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                Button("Check and attach") { attach() }.disabled(certificate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if identity.certificate != nil {
                    Button("Remove certificate", role: .destructive) {
                        app.keychain.setCertificate(id: identity.id, nil)
                        certificate = ""
                        info = nil
                    }
                }
                if let info {
                    LabeledContent("Key ID", value: info.keyId)
                    LabeledContent("Principals", value: info.principals.joined(separator: ", "))
                    LabeledContent("Valid until", value: Date(timeIntervalSince1970: TimeInterval(info.validBefore)).formatted())
                    if !info.current { Text("This certificate is not valid now.").foregroundStyle(.orange) }
                }
                if let failure { Text(failure).foregroundStyle(.red) }
            } header: {
                Text("Certificate")
            } footer: {
                Text("Paste an OpenSSH user certificate (*-cert.pub) for hosts that trust a CA.")
            }
            if !identity.isDevice {
                Button("Delete key", role: .destructive) { deleting = true }
            }
        }
        .navigationTitle(identity.name)
        .confirmationDialog("Delete \(identity.name)?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                app.keychain.delete(id: identity.id)
                dismiss()
            }
        } message: {
            Text("This key cannot be recovered. Nodes that sign in with it will use this device's key instead.")
        }
    }

    private func attach() {
        do {
            let checked = try app.keychain.certificateInfo(id: identity.id, certificate: certificate)
            guard checked.matches else {
                failure = String(localized: "This certificate is for a different key.")
                return
            }
            info = checked
            failure = nil
            app.keychain.setCertificate(id: identity.id, certificate)
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// Trusted host keys by `host:port`; forgetting one re-prompts next time.
struct KnownHostsScreen: View {
    let nodes: NodeStore

    var body: some View {
        List {
            ForEach(nodes.knownHosts.keys.sorted(), id: \.self) { host in
                VStack(alignment: .leading, spacing: 2) {
                    Text(host)
                    Text(nodes.knownHosts[host] ?? "").font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                .swipeActions { Button("Forget", role: .destructive) { nodes.forget(host) } }
            }
        }
        .overlay {
            if nodes.knownHosts.isEmpty {
                ContentUnavailableView("No known hosts", systemImage: "checkmark.shield", description: Text("Hosts you trust appear here."))
            }
        }
        .navigationTitle("Known hosts")
    }
}
