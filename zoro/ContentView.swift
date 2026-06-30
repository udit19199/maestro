//
//  ContentView.swift
//  zoro
//
//  Created by Udit Agarwal on 19/06/26.
//

import SwiftUI
import FoundationModels
import ClaudeForFoundationModels

// ChatMessage moved to WorkspaceManager.swift

struct MessageBubble: View {
    let message: ChatMessage
    
    var body: some View {
        HStack {
            if message.role == .user {
                Spacer()
                Text(message.content)
                    .font(.system(.body))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        LinearGradient(
                            colors: [Color.blue, Color(red: 0.3, green: 0.2, blue: 0.8)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .foregroundColor(.white)
                    .cornerRadius(16)
                    .frame(maxWidth: 600, alignment: .trailing)
            } else {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "cpu.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.purple)
                        .padding(8)
                        .background(Color.purple.opacity(0.1))
                        .clipShape(Circle())
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Zoro")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .bold()
                        
                        Text(message.content)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color(NSColor.controlBackgroundColor))
                            .foregroundColor(.primary)
                            .cornerRadius(12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                            )
                    }
                }
                .frame(maxWidth: 700, alignment: .leading)
                Spacer()
            }
        }
    }
}

struct ContentView: View {
    @StateObject private var workspace = WorkspaceManager.shared
    
    // ModelType moved to WorkspaceManager.swift
    
    @State private var anthropicApiKey: String = ""
    @State private var geminiApiKey: String = ""
    @State private var tavilyApiKey: String = ""
    @State private var gmailClientId: String = ""
    @State private var gmailClientSecret: String = ""
    @ObservedObject private var gmailAuth = GmailAuthManager.shared
    @ObservedObject private var gmailManager = GmailManager.shared
    @State private var gmailStatusMessage: String = "Not connected"
    @State private var showSettings: Bool = false
    @State private var modelAvailabilityMessage: String = "Checking availability..."
    @State private var isModelReady: Bool = false
    
    @State private var prompt: String = ""
    @State private var isRunning: Bool = false
    
    // iMessage Integration Settings
    @State private var imessageListenerEnabled: Bool = false
    @State private var imessageSenderWhitelist: String = ""
    @State private var imessagePasscode: String = ""
    @State private var hasFullDiskAccess: Bool = true
    @State private var imessageSecurityWarning: String? = nil
    
    var body: some View {
        VStack(spacing: 0) {
            // Header / Workspace selector
            HStack(spacing: 12) {
                Image(systemName: "folder.fill")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(workspace.workspaceURL?.lastPathComponent ?? "No Workspace Selected")
                        .font(.headline)
                    Text(workspace.workspaceURL?.path ?? "Please open a folder to start using Zoro")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                
                Spacer()

                if gmailAuth.isConnected {
                    HStack(spacing: 10) {
                        Image(systemName: "envelope.fill")
                            .font(.title3)
                            .foregroundColor(.red)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(gmailAuth.connectedEmail ?? "Gmail")
                                .font(.subheadline)
                                .bold()
                                .lineLimit(1)
                            HStack(spacing: 6) {
                                if let unread = gmailManager.unreadCount {
                                    Text("\(unread) unread")
                                        .font(.caption)
                                        .foregroundColor(unread > 0 ? .orange : .secondary)
                                }
                                if gmailManager.isSyncing {
                                    ProgressView()
                                        .controlSize(.mini)
                                } else if let synced = gmailManager.lastSyncedAt {
                                    Text("synced \(synced, style: .time)")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }

                        Button(action: {
                            Task { await gmailManager.refreshSnapshot() }
                        }) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.plain)
                        .help("Refresh Gmail inbox")
                        .disabled(gmailManager.isSyncing)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                    )
                }

                Button(action: selectWorkspaceFolder) {
                    Label("Open Workspace", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
                
                Button(action: {
                    withAnimation {
                        showSettings.toggle()
                    }
                }) {
                    Image(systemName: "gearshape.fill")
                        .font(.title3)
                        .foregroundColor(showSettings ? .accentColor : .secondary)
                        .padding(8)
                        .background(
                            Circle()
                                .fill(showSettings ? Color.accentColor.opacity(0.1) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .help("Model Settings")
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            if showSettings {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Model Configuration")
                        .font(.system(.headline, design: .rounded))
                        .foregroundColor(.primary)
                    
                    Picker("Active Backend:", selection: $workspace.selectedModelType) {
                        ForEach(ModelType.allCases) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: workspace.selectedModelType) { oldValue, newValue in
                        UserDefaults.standard.set(newValue.rawValue, forKey: "selected_model_type")
                        updateModelAvailability()
                        workspace.resetSession()
                    }
                    
                    if workspace.selectedModelType == .claude {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Anthropic API Key:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            SecureField("Enter api-key (sk-ant-...)", text: $anthropicApiKey)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                                .onChange(of: anthropicApiKey) { oldValue, newValue in
                                    KeychainHelper.save(key: "anthropic_api_key", value: newValue)
                                    updateModelAvailability()
                                    workspace.resetSession()
                                }
                        }
                    }
                    
                    if workspace.selectedModelType == .gemini {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Gemini API Key:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            SecureField("Enter Gemini api-key", text: $geminiApiKey)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                                .onChange(of: geminiApiKey) { oldValue, newValue in
                                    KeychainHelper.save(key: "gemini_api_key", value: newValue)
                                    updateModelAvailability()
                                    workspace.resetSession()
                                }
                        }
                    }
                    
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Tavily API Key (for web search & deep research):")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        SecureField("Enter Tavily api-key (tvly-...)", text: $tavilyApiKey)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .onChange(of: tavilyApiKey) { oldValue, newValue in
                                KeychainHelper.save(key: "tavily_api_key", value: newValue)
                            }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Gmail Integration")
                            .font(.system(.subheadline, design: .rounded))
                            .bold()
                            .foregroundColor(.primary)

                        Text("Create OAuth 2.0 Desktop credentials in Google Cloud Console, enable the Gmail API, and set the redirect URI to http://127.0.0.1:8765/")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Google OAuth Client ID:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextField("Enter OAuth Client ID", text: $gmailClientId)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                                .onChange(of: gmailClientId) { oldValue, newValue in
                                    KeychainHelper.save(key: "gmail_client_id", value: newValue)
                                }
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Google OAuth Client Secret:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            SecureField("Enter OAuth Client Secret", text: $gmailClientSecret)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                                .onChange(of: gmailClientSecret) { oldValue, newValue in
                                    KeychainHelper.save(key: "gmail_client_secret", value: newValue)
                                }
                        }

                        HStack(spacing: 12) {
                            if gmailAuth.isConnected {
                                Button("Disconnect Gmail") {
                                    gmailAuth.disconnect()
                                    gmailStatusMessage = "Disconnected"
                                }
                                .buttonStyle(.bordered)
                            } else {
                                Button(gmailAuth.isAuthorizing ? "Connecting..." : "Connect Gmail") {
                                    Task {
                                        do {
                                            try await gmailAuth.connect()
                                            await gmailManager.refreshSnapshot()
                                            if let email = gmailAuth.connectedEmail {
                                                gmailStatusMessage = "Connected as \(email)"
                                            } else {
                                                gmailStatusMessage = "Connected"
                                            }
                                        } catch {
                                            gmailStatusMessage = error.localizedDescription
                                        }
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(
                                    gmailAuth.isAuthorizing ||
                                    gmailClientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                    gmailClientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                )
                            }
                        }

                        HStack(spacing: 8) {
                            Image(systemName: gmailAuth.isConnected ? "checkmark.circle.fill" : "envelope")
                                .foregroundColor(gmailAuth.isConnected ? .green : .secondary)
                            Text(gmailStatusMessage)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Divider()
                    
                    VStack(alignment: .leading, spacing: 10) {
                        Text("iMessage Integration")
                            .font(.system(.subheadline, design: .rounded))
                            .bold()
                            .foregroundColor(.primary)
                        
                        Toggle("Enable iMessage Command Listener", isOn: $imessageListenerEnabled)
                            .onChange(of: imessageListenerEnabled) { oldValue, newValue in
                                if newValue {
                                    let passcode = KeychainHelper.retrieve(key: "imessage_passcode") ?? ""
                                    if passcode.isEmpty {
                                        imessageListenerEnabled = false
                                        imessageSecurityWarning = "A passcode is required before enabling the iMessage listener."
                                        return
                                    }
                                    if imessageSenderWhitelist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        imessageListenerEnabled = false
                                        imessageSecurityWarning = "Add at least one whitelisted sender before enabling the iMessage listener."
                                        return
                                    }
                                    imessageSecurityWarning = nil
                                } else {
                                    imessageSecurityWarning = nil
                                }
                                UserDefaults.standard.set(imessageListenerEnabled, forKey: "imessage_listener_enabled")
                                toggleIMessageListener()
                            }
                        
                        if imessageListenerEnabled {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Whitelisted Senders (comma-separated, phone numbers or emails):")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                TextField("e.g. +14155551212, user@icloud.com", text: $imessageSenderWhitelist)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(.body, design: .monospaced))
                                    .onChange(of: imessageSenderWhitelist) { oldValue, newValue in
                                        UserDefaults.standard.set(newValue, forKey: "imessage_sender_whitelist")
                                    }
                            }
                            
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Command Passcode (Required for remote commands):")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                SecureField("Enter passcode to unlock commands", text: $imessagePasscode)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(.body, design: .monospaced))
                                    .onChange(of: imessagePasscode) { oldValue, newValue in
                                        if newValue.isEmpty {
                                            KeychainHelper.delete(key: "imessage_passcode")
                                            if imessageListenerEnabled {
                                                imessageListenerEnabled = false
                                                UserDefaults.standard.set(false, forKey: "imessage_listener_enabled")
                                                toggleIMessageListener()
                                            }
                                            imessageSecurityWarning = "Passcode removed. iMessage listener disabled."
                                        } else {
                                            KeychainHelper.save(key: "imessage_passcode", value: newValue)
                                            imessageSecurityWarning = nil
                                        }
                                    }
                            }

                            Text("Remote iMessage sessions are restricted to read-only workspace access and can only reply to the sender. Shell commands and file writes are blocked remotely.")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            if let warning = imessageSecurityWarning {
                                HStack(spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(.orange)
                                    Text(warning)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.top, 4)
                            }
                            
                            if !hasFullDiskAccess {
                                HStack(spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(.orange)
                                    Text("Warning: Zoro lacks Full Disk Access. Grant it in Settings to enable commands.")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.top, 4)
                            } else {
                                HStack(spacing: 8) {
                                    Image(systemName: "checkmark.shield.fill")
                                        .foregroundColor(.green)
                                    Text("Full Disk Access granted. Zoro is listening to iMessages.")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.top, 4)
                            }
                        }
                    }
                    
                    HStack(spacing: 8) {
                        Image(systemName: isModelReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundColor(isModelReady ? .green : .orange)
                        Text(modelAvailabilityMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.top, 4)
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )
                .padding([.horizontal, .bottom])
                .transition(.move(edge: .top).combined(with: .opacity))
                
                Divider()
            }
            
            // Gmail inbox preview (when connected)
            if gmailAuth.isConnected && !gmailManager.inboxPreview.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Gmail Inbox")
                            .font(.caption)
                            .bold()
                            .foregroundColor(.secondary)
                        Spacer()
                        if let unread = gmailManager.unreadCount, unread > 0 {
                            Text("\(unread) unread")
                                .font(.caption2)
                                .foregroundColor(.orange)
                        }
                    }

                    ForEach(gmailManager.inboxPreview.prefix(5)) { item in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(item.isUnread ? Color.orange : Color.clear)
                                .frame(width: 6, height: 6)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.subject)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .fontWeight(item.isUnread ? .semibold : .regular)
                                Text("\(item.from) · \(item.date)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
                .padding([.horizontal, .top])
            }

            // Gmail fetch activity
            if !gmailManager.activityLog.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Gmail Activity")
                        .font(.caption)
                        .bold()
                        .foregroundColor(.secondary)

                    ForEach(gmailManager.activityLog.suffix(6)) { entry in
                        HStack(spacing: 8) {
                            Image(systemName: gmailActivityIcon(for: entry.status))
                                .font(.system(size: 11))
                                .foregroundColor(gmailActivityColor(for: entry.status))
                            Text(entry.message)
                                .font(.caption)
                                .lineLimit(1)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
                .padding([.horizontal, .top])
            }

            // If there are active todos, show a compact planning checklist in the header
            if !workspace.activeTodos.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Execution Plan")
                        .font(.caption)
                        .bold()
                        .foregroundColor(.secondary)
                    
                    ForEach(workspace.activeTodos) { todo in
                        HStack(spacing: 8) {
                            Image(systemName: todoIcon(for: todo.status))
                                .font(.system(size: 11))
                                .foregroundColor(todoColor(for: todo.status))
                            Text(todo.content)
                                .font(.caption)
                                .strikethrough(todo.status == "completed")
                                .foregroundColor(todo.status == "completed" ? .secondary : .primary)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
                .padding([.horizontal, .top])
            }
            
            // If there are active research steps, show the dynamic research outline
            if !workspace.researchSteps.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Research Progress")
                        .font(.caption)
                        .bold()
                        .foregroundColor(.secondary)
                    
                    ForEach(workspace.researchSteps) { step in
                        HStack(spacing: 8) {
                            Image(systemName: researchStepIcon(for: step.status))
                                .font(.system(size: 11))
                                .foregroundColor(researchStepColor(for: step.status))
                            Text(step.title)
                                .font(.caption)
                                .strikethrough(step.status == "completed")
                                .foregroundColor(step.status == "completed" ? .secondary : .primary)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
                .padding([.horizontal, .top])
            }
            
            // Conversation Scroll View
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(workspace.messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }
                    }
                    .padding()
                }
                .background(Color(NSColor.textBackgroundColor))
                .onChange(of: workspace.messages) { oldValue, newValue in
                    if let lastMessage = newValue.last {
                        withAnimation {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: workspace.workspaceURL) { oldValue, newValue in
                    workspace.resetSession()
                }
            }
            
            // Text Input Panel
            HStack(spacing: 12) {
                let placeholderText = workspace.activeClarificationQuestion.map { "Zoro needs reply: \($0)" } ?? "Ask Zoro to write code, inspect files, run tests..."
                TextField(placeholderText, text: $prompt)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body))
                    .disabled(isRunning && workspace.clarifyContinuation == nil)
                    .onSubmit {
                        triggerAgent()
                    }
                
                Button(action: triggerAgent) {
                    if isRunning && workspace.clarifyContinuation == nil {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "paperplane.fill")
                            .foregroundColor(.white)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.blue)
                .keyboardShortcut(.defaultAction)
                .disabled((isRunning && workspace.clarifyContinuation == nil) || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(minWidth: 800, minHeight: 500)
        .onAppear {
            self.anthropicApiKey = KeychainHelper.retrieve(key: "anthropic_api_key") ?? ""
            self.geminiApiKey = KeychainHelper.retrieve(key: "gemini_api_key") ?? ""
            self.tavilyApiKey = KeychainHelper.retrieve(key: "tavily_api_key") ?? ""
            self.gmailClientId = KeychainHelper.retrieve(key: "gmail_client_id") ?? ""
            self.gmailClientSecret = KeychainHelper.retrieve(key: "gmail_client_secret") ?? ""

            Task {
                await gmailAuth.refreshConnectionStatus()
                await gmailManager.refreshSnapshot()
                await MainActor.run {
                    if gmailAuth.isConnected, let email = gmailAuth.connectedEmail {
                        gmailStatusMessage = "Connected as \(email)"
                    } else if gmailAuth.isConnected {
                        gmailStatusMessage = "Connected"
                    } else {
                        gmailStatusMessage = "Not connected"
                    }
                }
            }

            self.imessageListenerEnabled = UserDefaults.standard.bool(forKey: "imessage_listener_enabled")
            self.imessageSenderWhitelist = UserDefaults.standard.string(forKey: "imessage_sender_whitelist") ?? ""
            self.imessagePasscode = KeychainHelper.retrieve(key: "imessage_passcode") ?? ""
            self.hasFullDiskAccess = checkFullDiskAccess()

            let savedWhitelist = UserDefaults.standard.string(forKey: "imessage_sender_whitelist") ?? ""
            if imessageListenerEnabled {
                if imessagePasscode.isEmpty || savedWhitelist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    imessageListenerEnabled = false
                    UserDefaults.standard.set(false, forKey: "imessage_listener_enabled")
                    imessageSecurityWarning = "iMessage listener disabled: passcode and whitelist are required."
                }
            }
            
            if let savedModelType = UserDefaults.standard.string(forKey: "selected_model_type"),
               let model = ModelType(rawValue: savedModelType) {
                workspace.selectedModelType = model
            }
            
            updateModelAvailability()
            
            if imessageListenerEnabled && hasFullDiskAccess {
                let passcode = KeychainHelper.retrieve(key: "imessage_passcode") ?? ""
                let whitelist = UserDefaults.standard.string(forKey: "imessage_sender_whitelist") ?? ""
                if !passcode.isEmpty && !whitelist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    IMessageListener.shared.start()
                }
            }
        }
    }
    
    // Present the macOS Open Folder Panel.
    private func selectWorkspaceFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        
        if panel.runModal() == .OK {
            workspace.workspaceURL = panel.url
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
            let passcode = KeychainHelper.retrieve(key: "imessage_passcode") ?? ""
            let whitelist = UserDefaults.standard.string(forKey: "imessage_sender_whitelist") ?? ""
            if passcode.isEmpty || whitelist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                imessageListenerEnabled = false
                UserDefaults.standard.set(false, forKey: "imessage_listener_enabled")
                IMessageListener.shared.stop()
                imessageSecurityWarning = "iMessage listener requires both a passcode and at least one whitelisted sender."
                return
            }
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
            }
        }
    }
    
    private func reasonDescription(for reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .modelNotReady:
            return "Model assets are downloading/preparing. Please stay connected to Wi-Fi and power."
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is disabled. Enable it under Settings > Apple Intelligence & Siri."
        case .deviceNotEligible:
            return "This Mac hardware does not support Apple Intelligence."
        @unknown default:
            return "Unknown unavailability reason: \(String(describing: reason))"
        }
    }
    
    // Trigger the LLM agent session.
    private func triggerAgent() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        
        prompt = ""
        workspace.clearResearchSteps()
        gmailManager.clearActivity()
        GmailReadAuditor.resetPromptState()
        
        // Handle reply to active clarification
        if let continuation = workspace.clarifyContinuation {
            let userMsg = ChatMessage(role: .user, content: text)
            workspace.messages.append(userMsg)
            
            let assistantMsgPlaceholder = ChatMessage(role: .assistant, content: "Thinking...")
            workspace.messages.append(assistantMsgPlaceholder)
            
            workspace.activeClarificationQuestion = nil
            workspace.clarifyContinuation = nil
            
            isRunning = true
            continuation.resume(returning: text)
            return
        }
        
        isRunning = true
        
        let userMsg = ChatMessage(role: .user, content: text)
        workspace.messages.append(userMsg)
        
        let assistantMsgPlaceholder = ChatMessage(role: .assistant, content: "Thinking...")
        workspace.messages.append(assistantMsgPlaceholder)
        

        
        Task {
            if workspace.selectedModelType == .system {
                let status = SystemLanguageModel.default.availability
                if case .unavailable(let reason) = status {
                    await MainActor.run {
                        if let lastIndex = workspace.messages.indices.last {
                            workspace.messages[lastIndex].content = "On-Device Apple Intelligence model is not ready yet.\n\nReason: \(reasonDescription(for: reason))\n\nTip: Click the gear icon in the header and configure 'Claude (Anthropic)' or 'Gemini (Google)' to test Zoro's tools immediately."
                        }
                        isRunning = false
                    }
                    return
                }
            } else if workspace.selectedModelType == .pcc {
                let status = PrivateCloudComputeLanguageModel().availability
                if case .unavailable(let reason) = status {
                    await MainActor.run {
                        if let lastIndex = workspace.messages.indices.last {
                            workspace.messages[lastIndex].content = "Private Cloud Compute is not available.\n\nReason: \(reason)\n\nTip: PCC requires the 'com.apple.developer.private-cloud-compute' entitlement. Click the gear icon and switch to 'Claude (Anthropic)' or 'Gemini (Google)' to use Zoro."
                        }
                        isRunning = false
                    }
                    return
                }
            }
            
            do {
                let activeSession = try workspace.getOrCreateSession()
                var promptText = text
                if let summary = workspace.conversationSummary {
                    promptText = "[System Note: The conversation context exceeded the model limit and was compressed. Here is a summary of the prior turns:\n\(summary)]\n\n\(text)"
                }
                let stream = activeSession.streamResponse(to: promptText)
                
                for try await partialContent in stream {
                    await MainActor.run {
                        if let lastIndex = workspace.messages.indices.last {
                            workspace.messages[lastIndex].content = partialContent.content
                        }
                    }
                }
                
                await MainActor.run {
                    workspace.conversationSummary = nil
                    if let lastIndex = workspace.messages.indices.last {
                        let audited = GmailReadAuditor.auditAssistantResponse(
                            workspace.messages[lastIndex].content,
                            userPrompt: text
                        )
                        workspace.messages[lastIndex].content = audited
                    }
                    isRunning = false
                }
            } catch {
                let errMsg = error.localizedDescription
                if errMsg.lowercased().contains("context size") || errMsg.lowercased().contains("transcript exceeded") || errMsg.lowercased().contains("context limit") {
                    let summary = await compressConversationHistory()
                    await MainActor.run {
                        workspace.session = nil
                        workspace.conversationSummary = summary
                        workspace.messages.append(ChatMessage(
                            role: .assistant,
                            content: "⚠️ The conversation history exceeded the model's context size. It has been compressed. Previous context summary:\n\n\"\(summary)\"\n\nPlease try your request again."
                        ))
                        isRunning = false
                    }
                } else {
                    await MainActor.run {
                        if let lastIndex = workspace.messages.indices.last {
                            workspace.messages[lastIndex].content = "Error: \(error.localizedDescription)\n\nTip: If you do not have active developer entitlements, you can click the gear icon and configure 'Claude (Anthropic)' or 'Gemini (Google)' to use Zoro's tools."
                        }
                        isRunning = false
                    }
                }
            }
        }
    }
    
    private func compressConversationHistory() async -> String {
        let chatText = workspace.messages.map { "\($0.role.rawValue): \($0.content)" }.joined(separator: "\n")
        
        do {
            let tempSession: LanguageModelSession
            switch workspace.selectedModelType {
            case .system:
                tempSession = LanguageModelSession(model: SystemLanguageModel.default)
            case .pcc:
                tempSession = LanguageModelSession(model: PrivateCloudComputeLanguageModel())
            case .claude:
                tempSession = LanguageModelSession(model: ClaudeLanguageModel(name: .sonnet4_6, auth: .apiKey(anthropicApiKey)))
            case .gemini:
                tempSession = LanguageModelSession(model: GeminiLanguageModel(modelName: "gemini-2.5-flash", apiKey: geminiApiKey))
            }
            
            let prompt = "Please write a highly concise summary (under 100 words) of the conversation so far, focusing on what was accomplished and what context is needed to continue:\n\n\(chatText)"
            let stream = tempSession.streamResponse(to: prompt)
            var summaryContent = ""
            for try await chunk in stream {
                summaryContent += chunk.content
            }
            if !summaryContent.isEmpty {
                return summaryContent
            }
        } catch {
            // Fallback
        }
        
        let lastMessages = workspace.messages.suffix(4)
        let summaryText = lastMessages.map { "\($0.role.rawValue): \($0.content)" }.joined(separator: "\n")
        return "Last turns of conversation:\n\(summaryText)"
    }
    
    private func todoIcon(for status: String) -> String {
        switch status {
        case "completed": return "checkmark.circle.fill"
        case "in_progress": return "arrow.triangle.2.circlepath.circle.fill"
        case "cancelled": return "xmark.circle.fill"
        default: return "circle"
        }
    }
    
    private func todoColor(for status: String) -> Color {
        switch status {
        case "completed": return .green
        case "in_progress": return .blue
        case "cancelled": return .gray
        default: return .secondary
        }
    }
    
    private func researchStepIcon(for status: String) -> String {
        switch status {
        case "completed": return "checkmark.circle.fill"
        case "in_progress": return "arrow.triangle.2.circlepath.circle.fill"
        case "failed": return "exclamationmark.circle.fill"
        default: return "circle"
        }
    }
    
    private func researchStepColor(for status: String) -> Color {
        switch status {
        case "completed": return .green
        case "in_progress": return .blue
        case "failed": return .red
        default: return .secondary
        }
    }

    private func gmailActivityIcon(for status: String) -> String {
        switch status {
        case "completed": return "checkmark.circle.fill"
        case "in_progress": return "arrow.triangle.2.circlepath.circle.fill"
        case "failed": return "exclamationmark.circle.fill"
        default: return "circle"
        }
    }

    private func gmailActivityColor(for status: String) -> Color {
        switch status {
        case "completed": return .green
        case "in_progress": return .blue
        case "failed": return .red
        default: return .secondary
        }
    }
}

#Preview {
    ContentView()
}
