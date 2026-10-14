import SwiftUI

struct SessionView: View {
    @Environment(DeviceStore.self) private var store
    @State private var session: KVMSession
    @State private var username = ""
    @State private var password = ""
    @State private var rememberPassword = true
    @State private var capturesShortcuts = true
    @State private var showsSoftwareKeyboard = false
    @State private var showsReleaseHint = false
    #if os(macOS)
    @State private var accessibilityTrusted = SystemKeyInterceptor.isTrusted
    #endif

    /// Collapsed while connected so the remote screen gets the whole window.
    @Binding var columnVisibility: NavigationSplitViewVisibility

    init(device: KVMDevice, columnVisibility: Binding<NavigationSplitViewVisibility>) {
        _session = State(initialValue: KVMSession(device: device))
        _columnVisibility = columnVisibility
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch session.state {
            case .connected:
                RemoteScreenView(session: session,
                                 capturesSystemShortcuts: capturesShortcuts,
                                 showsSoftwareKeyboard: $showsSoftwareKeyboard)
                    #if os(iOS)
                    .ignoresSafeArea(.container)
                    #endif
                #if os(macOS)
                if showsReleaseHint {
                    Text(accessibilityTrusted && capturesShortcuts
                         ? "Clavier capturé, y compris ⌘Tab et ⌘Espace · ⌃⌥⌘ pour libérer"
                         : "⌃⌥⌘ pour libérer le clavier · clic sur l'écran pour le reprendre")
                        .font(.callout)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .frame(maxHeight: .infinity, alignment: .top)
                        .padding(.top, 12)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
                #endif
                if let error = session.videoError {
                    statusCard(icon: "rectangle.slash", title: "Pas de signal HDMI", message: error)
                        .allowsHitTesting(false)
                }
            case .idle, .connecting:
                VStack(spacing: 12) {
                    ProgressView()
                    if case .connecting(let step) = session.state {
                        Text(step).foregroundStyle(.secondary)
                    }
                }
            case .needsCredentials(let error):
                credentialsPrompt(error: error)
            case .failed(let message):
                VStack(spacing: 16) {
                    statusCard(icon: "exclamationmark.triangle", title: "Connexion impossible", message: message)
                    Button("Réessayer") { connect() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .navigationTitle(session.device.name)
        #if os(macOS)
        .navigationSubtitle(session.activeRoute.map { "via \($0.kind.title) · \($0.host)" } ?? "")
        #endif
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { toolbar }
        .task {
            session.onDeviceUpdate = { [store] device in store.update(device) }
            username = session.device.username ?? session.kind?.defaultUsername ?? ""
            connect()
        }
        .onDisappear { session.disconnect() }
        .onChange(of: session.state) { _, state in
            guard state == .connected else { return }
            withAnimation { columnVisibility = .detailOnly }
            showsReleaseHint = true
            Task {
                try? await Task.sleep(for: .seconds(5))
                withAnimation { showsReleaseHint = false }
            }
        }
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityTrusted = SystemKeyInterceptor.isTrusted
        }
        #endif
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            #if os(iOS)
            if let route = session.activeRoute, session.state == .connected {
                Label("via \(route.kind.title)", systemImage: route.kind.systemImage)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Connecté via \(route.kind.title)")
            }
            Button {
                showsSoftwareKeyboard.toggle()
            } label: {
                Label("Clavier", systemImage: showsSoftwareKeyboard ? "keyboard.chevron.compact.down" : "keyboard")
            }
            .disabled(session.state != .connected)
            #endif

            Menu {
                Section("Raccourcis") {
                    ForEach(KeyCombo.all) { combo in
                        Button(combo.title) { session.send(combo) }
                    }
                }
                Button("Coller le presse-papiers comme frappe", systemImage: "doc.on.clipboard") {
                    if let text = Self.clipboardText { session.type(text) }
                }
                Picker("Disposition du clavier distant", selection: layoutBinding) {
                    ForEach(KeyboardLayout.choices, id: \.code) { choice in
                        Text(choice.name).tag(choice.code)
                    }
                }
            } label: {
                Label("Clavier distant", systemImage: "command.square")
            }
            .disabled(session.state != .connected)

            #if os(macOS)
            Toggle(isOn: $capturesShortcuts) {
                Label("Capturer ⌘", systemImage: "command")
            }
            .help("Envoie ⌘Tab, ⌘Espace, ⌘Q… à la machine distante au lieu de macOS")

            if capturesShortcuts && !accessibilityTrusted {
                Button("Autoriser ⌘Tab", systemImage: "lock.shield") {
                    SystemKeyInterceptor.requestTrust()
                }
                .help("macOS doit autoriser l'app dans Réglages › Confidentialité et sécurité › Accessibilité")
            }
            #endif

            Button {
                if session.state == .connected { session.disconnect() } else { connect() }
            } label: {
                if session.state == .connected {
                    Label("Déconnecter", systemImage: "bolt.horizontal.circle.fill")
                } else {
                    Label("Connecter", systemImage: "bolt.horizontal.circle")
                }
            }
        }
    }

    private var layoutBinding: Binding<String> {
        Binding(
            get: { (session.keyboardLayout ?? "en-US").replacingOccurrences(of: "_", with: "-") },
            set: { session.setKeyboardLayout($0) }
        )
    }

    private static var clipboardText: String? {
        #if os(macOS)
        NSPasteboard.general.string(forType: .string)
        #else
        UIPasteboard.general.string
        #endif
    }

    private func connect(with password: String? = nil) {
        let credentials = Credentials(username: username.isEmpty ? nil : username,
                                      password: password ?? Keychain.password(for: session.device.id))
        Task { await session.connect(credentials: credentials) }
    }

    private func credentialsPrompt(error: String?) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "lock").font(.largeTitle)
            Text(session.kind.map { "Connexion à \($0.shortTitle)" } ?? "Connexion au KVM").font(.headline)
            if session.kind?.usesUsername == true {
                TextField("Utilisateur", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
            }
            SecureField("Mot de passe", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
                .onSubmit(submitPassword)
            Toggle("Mémoriser dans le trousseau", isOn: $rememberPassword)
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            Button("Se connecter", action: submitPassword)
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty)
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func submitPassword() {
        guard !password.isEmpty else { return }
        if rememberPassword { Keychain.setPassword(password, for: session.device.id) }
        connect(with: password)
        password = ""
    }

    private func statusCard(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.largeTitle)
            Text(title).font(.headline)
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
