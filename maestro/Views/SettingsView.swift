import SwiftUI

struct SettingsView: View {
  @ObservedObject private var pi = PiSettings.shared
  @AppStorage("pi_model") private var model = "cliauthproxy/gpt-6.1-sol"
  private enum Page: String {
    case providers = "Providers"
    case mcp = "MCP servers"
  }
  @State private var page: Page?
  @State private var input = ""

  var body: some View {
    VStack {
      if let page {
        HStack {
          Button("Settings") {
            pi.cancel()
            self.page = nil
          }
          Text(page.rawValue).font(.headline)
          Spacer()
        }.padding()
      } else {
        List {
          Button("Providers") { page = .providers }
          Button("MCP servers") { page = .mcp }
        }
      }
      if let page {
        Form {
          if let request = pi.inputRequest {
            Section(request.title) {
              switch request.kind {
              case .select(let options):
                Picker("Choose", selection: $input) {
                  Text("Choose an option").tag("")
                  ForEach(options, id: \.self) { Text($0).tag($0) }
                }
              case .secret:
                SecureField("API key", text: $input)
              case .text:
                TextField(request.title, text: $input)
              }
              HStack {
                Button("Continue") {
                  pi.submitInput(input)
                  input = ""
                }.disabled(input.isEmpty)
                Button("Cancel") {
                  pi.cancel()
                  input = ""
                }
              }
            }
          }
          if page == .providers {
            Section("Supported providers") {
              ForEach(pi.providers) { provider in
                HStack {
                  Text(provider.name)
                  Spacer()
                  if provider.connected { Text("Configured").foregroundStyle(.secondary) }
                  if provider.apiKey {
                    Button("API key") { pi.connect(provider: provider.id, method: .apiKey) }
                  }
                  if provider.oauth {
                    Button("Sign in") { pi.connect(provider: provider.id, method: .oauth) }
                  }
                  if !provider.apiKey && !provider.oauth && !provider.connected {
                    Text("Requires provider configuration").foregroundStyle(.secondary)
                  }
                }
              }
            }.disabled(pi.busy)
            Section("Model") {
              Picker("Default model", selection: $model) {
                Text("Choose a model").tag("")
                if !pi.models.contains(where: { $0.id == model }) { Text(model).tag(model) }
                ForEach(pi.models) { Text($0.name).tag($0.id) }
              }.onChange(of: model) { _, _ in PiSessions.shared.stopAll() }
              Button("Refresh providers") { pi.refreshProviders() }.disabled(pi.busy)
            }
          } else {
            Section("Supported MCP servers") {
              ForEach(PiSettings.supportedMCPServers) { server in
                HStack {
                  Text(server.name)
                  Spacer()
                  Button("Connect") { pi.connectMCP(server) }
                }
              }
            }.disabled(pi.busy)
          }
          Text(pi.status).font(.caption).textSelection(.enabled)
          if pi.busy {
            Button("Cancel") {
              pi.cancel()
              input = ""
            }
          }
        }.formStyle(.grouped)
      }
    }
    .onDisappear { input = "" }
    .onChange(of: page) { _, page in
      pi.status = ""
      if page == .providers { pi.refreshProviders() }
    }
    .onChange(of: pi.inputRequest?.id) { _, _ in input = "" }
  }
}
