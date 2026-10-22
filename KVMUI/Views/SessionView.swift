import SwiftUI

struct SessionView: View {
    @Environment(DeviceStore.self) private var store
    @State private var session: KVMSession
    @State private var username = ""
    @State private var password = ""
    @State private var rememberPassword = true
    @State private var capturesShortcuts = true
    @State private var showsSoftwareKeyboard = Screenshots.showsKeyboard
    @State private var showsReleaseHint = false
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif

    /// iPhone in landscape: the remote screen fills the height and the title would sit on top of it.
    private var hidesTitle: Bool {
        #if os(iOS)
        verticalSizeClass == .compact && session.state == .connected
        #else
        false
        #endif
    }
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
                    Group {
                        if accessibilityTrusted && capturesShortcuts {
                            Text("Keyboard captured, including ⌘Tab and ⌘Space · ⌃⌥⌘ to release")
                        } else {
                            Text("⌃⌥⌘ releases the keyboard · click the screen to capture it again")
                        }
                    }
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
                    statusCard(icon: "rectangle.slash", title: "No HDMI Signal", message: Self.videoErrorMessage(error))
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
                    statusCard(icon: "exclamationmark.triangle", title: "Couldn't Connect", message: message)
                    Button("Try Again") { connect() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .navigationTitle(hidesTitle ? "" : session.device.name)
        #if os(macOS)
        .navigationSubtitle(session.activeRoute.map { String(localized: "via \($0.kind.title) · \($0.host)") } ?? "")
        #endif
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar) // over the black screen, not the list
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
            if !Screenshots.keepsSidebar { withAnimation { columnVisibility = .detailOnly } }
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
                    .accessibilityLabel("Connected via \(route.kind.title)")
            }
            Button {
                showsSoftwareKeyboard.toggle()
            } label: {
                Label("Keyboard", systemImage: showsSoftwareKeyboard ? "keyboard.chevron.compact.down" : "keyboard")
            }
            .disabled(session.state != .connected)
            #endif

            Menu {
                Section("Shortcuts") {
                    ForEach(KeyCombo.all) { combo in
                        Button(combo.title) { session.send(combo) }
                    }
                }
                Button("Type Clipboard Contents", systemImage: "doc.on.clipboard") {
                    if let text = Self.clipboardText { session.type(text) }
                }
                Picker("Remote Keyboard Layout", selection: layoutBinding) {
                    ForEach(KeyboardLayout.choices, id: \.code) { choice in
                        Text(choice.name).tag(choice.code)
                    }
                }
            } label: {
                Label("Remote Keyboard", systemImage: "command.square")
            }
            .disabled(session.state != .connected)

            #if os(macOS)
            Toggle(isOn: $capturesShortcuts) {
                Label("Capture ⌘", systemImage: "command")
            }
            .help("Sends ⌘Tab, ⌘Space, ⌘Q… to the remote computer instead of macOS")

            if capturesShortcuts && !accessibilityTrusted && !SystemKeyInterceptor.isSandboxed && !Screenshots.isActive {
                Button("Allow ⌘Tab", systemImage: "lock.shield") {
                    SystemKeyInterceptor.requestTrust()
                }
                .help("macOS must allow the app in System Settings › Privacy & Security › Accessibility")
            }
            #endif

            Button {
                if session.state == .connected { session.disconnect() } else { connect() }
            } label: {
                if session.state == .connected {
                    Label("Disconnect", systemImage: "bolt.horizontal.circle.fill")
                } else {
                    Label("Connect", systemImage: "bolt.horizontal.circle")
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
            Group {
                if let kind = session.kind {
                    Text("Connect to \(kind.shortTitle)")
                } else {
                    Text("Connect to KVM")
                }
            }
            .font(.headline)
            if session.kind?.usesUsername == true {
                TextField("User Name", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
            }
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
                .onSubmit(submitPassword)
            Toggle("Remember in Keychain", isOn: $rememberPassword)
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            Button("Sign In", action: submitPassword)
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

    /// The devices report HDMI problems as codes; the common ones get a sentence.
    private static func videoErrorMessage(_ code: String) -> String {
        switch code {
        case "no_signal": String(localized: "The computer isn't sending a picture.")
        case "no_lock": String(localized: "The signal isn't stable.")
        case "out_of_range": String(localized: "This resolution isn't supported by the KVM.")
        default: code
        }
    }

    private func statusCard(icon: String, title: LocalizedStringKey, message: String) -> some View {
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
