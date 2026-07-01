//
//  SettingsView.swift
//  zoro
//

import SwiftUI
import FoundationModels
import ClaudeForFoundationModels
import ServiceManagement

struct SettingsView: View {
    @ObservedObject private var workspace = WorkspaceManager.shared
    @ObservedObject private var profileStore = ProfileStore.shared
    @ObservedObject private var briefingService = BriefingService.shared
    @ObservedObject private var codexAuth = CodexAuthManager.shared

    @State private var anthropicApiKey = ""
    @State private var geminiApiKey = ""
    @State private var openaiApiKey = ""
    @State private var tavilyApiKey = ""
    @State private var codexModelName = "gpt-5-codex"
    @State private var codexStatusMessage = "Not connected"
    @State private var modelAvailabilityMessage = "Checking availability..."
    @State private var isModelReady = false

    @State private var imessageListenerEnabled = false
    @State private var imessageSenderWhitelist = ""
    @State private var imessagePasscode = ""
    @State private var hasFullDiskAccess = true
    @State private var launchAtLogin = false
    @State private var loginItemError: String?
    @State private var editingFactID: UUID?
    @State private var editingFactText = ""
    @State private var newFactText = ""

    @AppStorage("hide_dock_icon") private var hideDockIcon = true

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            memoryTab
                .tabItem { Label("Memory", systemImage: "brain.head.profile") }
        }
        .frame(minWidth: 520, minHeight: 480)
        .onAppear(perform: loadSettings)
    }

    private var generalTab: some View {
        Form {
            Section("Model") {
                Picker("Active Backend (Default agent uses Apple Intelligence)", selection: $workspace.selectedModelType) {
                    ForEach(ModelType.allCases) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                .onChange(of: workspace.selectedModelType) { _, newValue in
                    UserDefaults.standard.set(newValue.rawValue, forKey: "selected_model_type")
                    updateModelAvailability()
                    workspace.resetSession()
                }

                Text("Research, Planner, and Teach prefer OpenAI when an OpenAI key is set; otherwise Apple Intelligence.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                SecureField("OpenAI API Key (sk-…)", text: $openaiApiKey)
                    .onChange(of: openaiApiKey) { _, newValue in
                        KeychainHelper.save(key: "openai_api_key", value: newValue)
                        updateModelAvailability()
                        workspace.resetSession()
                    }

                if workspace.selectedModelType == .claude {
                    SecureField("Anthropic API Key (sk-ant-…)", text: $anthropicApiKey)
                        .onChange(of: anthropicApiKey) { _, newValue in
                            KeychainHelper.save(key: "anthropic_api_key", value: newValue)
                            updateModelAvailability()
                            workspace.resetSession()
                        }
                }

                if workspace.selectedModelType == .gemini {
                    SecureField("Gemini API Key", text: $geminiApiKey)
                        .onChange(of: geminiApiKey) { _, newValue in
                            KeychainHelper.save(key: "gemini_api_key", value: newValue)
                            updateModelAvailability()
                            workspace.resetSession()
                        }
                }

                if workspace.selectedModelType == .codex {
                    Text("Uses your ChatGPT / Codex subscription (same backend as the Codex CLI, not api.openai.com).")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField("Codex model name", text: $codexModelName)
                        .onChange(of: codexModelName) { _, newValue in
                            UserDefaults.standard.set(newValue, forKey: "codex_model_name")
                            workspace.invalidateSessionsForConfigChange()
                            updateModelAvailability()
                        }

                    HStack(spacing: 12) {
                        if codexAuth.isConnected {
                            Button("Disconnect Codex") {
                                Task {
                                    await codexAuth.disconnect()
                                    codexStatusMessage = "Disconnected"
                                    updateModelAvailability()
                                }
                            }
                            .buttonStyle(.bordered)
                        } else {
                            Button(codexAuth.isAuthorizing ? "Signing in..." : "Sign in with ChatGPT") {
                                Task {
                                    do {
                                        try await codexAuth.connect()
                                        if let email = codexAuth.connectedEmail {
                                            codexStatusMessage = "Connected as \(email)"
                                        } else {
                                            codexStatusMessage = "Connected"
                                        }
                                        updateModelAvailability()
                                    } catch {
                                        codexStatusMessage = error.localizedDescription
                                    }
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(codexAuth.isAuthorizing)

                            Button("Import from Codex CLI") {
                                do {
                                    try codexAuth.importFromCLI()
                                    if let email = codexAuth.connectedEmail {
                                        codexStatusMessage = "Imported credentials for \(email)"
                                    } else {
                                        codexStatusMessage = "Imported Codex CLI credentials"
                                    }
                                    updateModelAvailability()
                                } catch {
                                    codexStatusMessage = error.localizedDescription
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(codexAuth.isAuthorizing)

                            Button("Device Code") {
                                Task {
                                    do {
                                        try await codexAuth.startDeviceCodeLogin()
                                        if let email = codexAuth.connectedEmail {
                                            codexStatusMessage = "Connected as \(email)"
                                        } else {
                                            codexStatusMessage = "Connected"
                                        }
                                        updateModelAvailability()
                                    } catch {
                                        codexStatusMessage = error.localizedDescription
                                    }
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(codexAuth.isAuthorizing)
                        }
                    }

                    if let prompt = codexAuth.deviceCodePrompt {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("1. Visit: \(prompt.verificationURL)")
                            Text("2. Enter code: \(prompt.userCode)")
                                .font(.system(.body, design: .monospaced))
                                .bold()
                            Text("Waiting for authorization...")
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }

                    HStack(spacing: 8) {
                        Image(systemName: codexAuth.isConnected ? "checkmark.circle.fill" : "terminal.fill")
                            .foregroundStyle(codexAuth.isConnected ? .green : .secondary)
                        Text(codexStatusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                SecureField("Tavily API Key (tvly-…)", text: $tavilyApiKey)
                    .onChange(of: tavilyApiKey) { _, newValue in
                        KeychainHelper.save(key: "tavily_api_key", value: newValue)
                    }

                HStack(spacing: 8) {
                    Image(systemName: isModelReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(isModelReady ? .green : .orange)
                    Text(modelAvailabilityMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Briefing") {
                Picker("Background refresh interval", selection: Binding(
                    get: { briefingService.refreshIntervalHours },
                    set: { briefingService.refreshIntervalHours = $0 }
                )) {
                    Text("2 hours").tag(2.0)
                    Text("3 hours").tag(3.0)
                    Text("4 hours").tag(4.0)
                }
            }

            Section("Appearance") {
                Toggle("Hide Dock icon (menu bar only)", isOn: $hideDockIcon)
                    .onChange(of: hideDockIcon) { _, newValue in
                        AppDelegate.applyDockVisibility(hide: newValue)
                    }
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        setLaunchAtLogin(enabled: newValue)
                    }
                if let loginItemError {
                    Text(loginItemError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Workspace") {
                HStack {
                    Text(workspace.workspaceURL?.path ?? "No folder attached")
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Attach Folder…") {
                        selectWorkspaceFolder()
                    }
                }
                Text("Optional. File and terminal tools scope to an attached folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("iMessage") {
                Toggle("Enable iMessage Command Listener", isOn: $imessageListenerEnabled)
                    .onChange(of: imessageListenerEnabled) { _, newValue in
                        UserDefaults.standard.set(newValue, forKey: "imessage_listener_enabled")
                        toggleIMessageListener()
                    }

                if imessageListenerEnabled {
                    TextField("Whitelisted senders (comma-separated)", text: $imessageSenderWhitelist)
                        .onChange(of: imessageSenderWhitelist) { _, newValue in
                            UserDefaults.standard.set(newValue, forKey: "imessage_sender_whitelist")
                        }

                    SecureField("Command passcode (optional)", text: $imessagePasscode)
                        .onChange(of: imessagePasscode) { _, newValue in
                            if newValue.isEmpty {
                                KeychainHelper.delete(key: "imessage_passcode")
                            } else {
                                KeychainHelper.save(key: "imessage_passcode", value: newValue)
                            }
                        }

                    if !hasFullDiskAccess {
                        Label("Grant Full Disk Access in System Settings for iMessage commands.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else {
                        Label("Full Disk Access granted.", systemImage: "checkmark.shield.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var memoryTab: some View {
        Form {
            Section("Profile notes") {
                TextEditor(text: Binding(
                    get: { profileStore.profile.freeformNotes },
                    set: { profileStore.updateFreeformNotes($0) }
                ))
                .frame(minHeight: 100)
            }

            Section("Saved facts") {
                ForEach(profileStore.profile.facts) { fact in
                    if editingFactID == fact.id {
                        TextField("Fact", text: $editingFactText)
                        HStack {
                            Button("Save") {
                                profileStore.updateFact(id: fact.id, text: editingFactText)
                                editingFactID = nil
                            }
                            Button("Cancel") { editingFactID = nil }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(fact.text)
                            Text(fact.source.rawValue)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .contextMenu {
                            Button("Edit") {
                                editingFactID = fact.id
                                editingFactText = fact.text
                            }
                            Button("Delete", role: .destructive) {
                                profileStore.deleteFact(id: fact.id)
                            }
                        }
                    }
                }
                .onDelete { offsets in
                    for index in offsets {
                        let fact = profileStore.profile.facts[index]
                        profileStore.deleteFact(id: fact.id)
                    }
                }

                HStack {
                    TextField("Add a fact…", text: $newFactText)
                    Button("Add") {
                        if profileStore.addFact(newFactText, source: .manual) != nil {
                            newFactText = ""
                        }
                    }
                    .disabled(newFactText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func loadSettings() {
        anthropicApiKey = KeychainHelper.retrieve(key: "anthropic_api_key") ?? ""
        geminiApiKey = KeychainHelper.retrieve(key: "gemini_api_key") ?? ""
        openaiApiKey = KeychainHelper.retrieve(key: "openai_api_key") ?? ""
        tavilyApiKey = KeychainHelper.retrieve(key: "tavily_api_key") ?? ""
        codexModelName = UserDefaults.standard.string(forKey: "codex_model_name") ?? "gpt-5-codex"

        Task {
            await codexAuth.refreshConnectionStatus()
            await MainActor.run {
                if codexAuth.isConnected, let email = codexAuth.connectedEmail {
                    codexStatusMessage = "Connected as \(email)"
                } else if codexAuth.isConnected {
                    codexStatusMessage = "Connected"
                } else {
                    codexStatusMessage = "Not connected"
                }
            }
        }

        imessageListenerEnabled = UserDefaults.standard.bool(forKey: "imessage_listener_enabled")
        imessageSenderWhitelist = UserDefaults.standard.string(forKey: "imessage_sender_whitelist") ?? ""
        imessagePasscode = KeychainHelper.retrieve(key: "imessage_passcode") ?? ""
        hasFullDiskAccess = checkFullDiskAccess()
        launchAtLogin = (SMAppService.mainApp.status == .enabled)

        if let savedModelType = UserDefaults.standard.string(forKey: "selected_model_type"),
           let model = ModelType(rawValue: savedModelType) {
            workspace.selectedModelType = model
        }

        updateModelAvailability()
        profileStore.load()

        if imessageListenerEnabled && hasFullDiskAccess {
            IMessageListener.shared.start()
        }
    }

    private func setLaunchAtLogin(enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemError = nil
        } catch {
            loginItemError = "Could not update login item: \(error.localizedDescription)"
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
        }
    }

    private func selectWorkspaceFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            workspace.workspaceURL = url
            workspace.resetSession()
        }
    }

    private func checkFullDiskAccess() -> Bool {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let dbPath = homeDir.appendingPathComponent("Library/Messages/chat.db").path
        let fd = open(dbPath, O_RDONLY)
        if fd >= 0 {
            close(fd)
            return true
        }
        return false
    }

    private func toggleIMessageListener() {
        hasFullDiskAccess = checkFullDiskAccess()
        if imessageListenerEnabled && hasFullDiskAccess {
            IMessageListener.shared.start()
        } else {
            IMessageListener.shared.stop()
        }
    }

    private func updateModelAvailability() {
        Task {
            switch workspace.selectedModelType {
            case .system:
                let model = SystemLanguageModel.default
                let status = model.availability
                await MainActor.run {
                    switch status {
                    case .available:
                        modelAvailabilityMessage = "Apple Intelligence model is ready."
                        isModelReady = true
                    case .unavailable(let reason):
                        modelAvailabilityMessage = "Apple Intelligence is unavailable: \(reasonDescription(for: reason))"
                        isModelReady = false
                    @unknown default:
                        modelAvailabilityMessage = "Status unknown."
                        isModelReady = false
                    }
                }
            case .pcc:
                let model = PrivateCloudComputeLanguageModel()
                let status = model.availability
                await MainActor.run {
                    switch status {
                    case .available:
                        modelAvailabilityMessage = "PCC is available (entitlements required at runtime)."
                        isModelReady = true
                    case .unavailable(let reason):
                        modelAvailabilityMessage = "PCC is unavailable: \(reason)"
                        isModelReady = false
                    @unknown default:
                        modelAvailabilityMessage = "Status unknown."
                        isModelReady = false
                    }
                }
            case .claude:
                await MainActor.run {
                    if anthropicApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        modelAvailabilityMessage = "Please enter your Anthropic API key."
                        isModelReady = false
                    } else {
                        modelAvailabilityMessage = "Claude via API key is ready."
                        isModelReady = true
                    }
                }
            case .gemini:
                await MainActor.run {
                    if geminiApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        modelAvailabilityMessage = "Please enter your Gemini API key."
                        isModelReady = false
                    } else {
                        modelAvailabilityMessage = "Gemini via API key is ready."
                        isModelReady = true
                    }
                }
            case .openai:
                await MainActor.run {
                    if openaiApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        modelAvailabilityMessage = "Please enter your OpenAI API key."
                        isModelReady = false
                    } else {
                        modelAvailabilityMessage = "OpenAI via API key is ready."
                        isModelReady = true
                    }
                }
            case .codex:
                await MainActor.run {
                    if codexAuth.isConnected {
                        modelAvailabilityMessage = "Codex via ChatGPT subscription is ready."
                        isModelReady = true
                    } else {
                        modelAvailabilityMessage = "Sign in with ChatGPT or import from Codex CLI."
                        isModelReady = false
                    }
                }
            }
        }
    }

    private func reasonDescription(for reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .modelNotReady:
            return "Model assets are downloading/preparing."
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is disabled."
        case .deviceNotEligible:
            return "This Mac does not support Apple Intelligence."
        @unknown default:
            return "Unknown reason: \(String(describing: reason))"
        }
    }
}

#Preview {
    SettingsView()
}
