import SwiftUI
import RecipeCore

/// Settings → AI: Apple Intelligence (free, default) or the user's own API key.
struct AISettingsView: View {
    @Environment(AppServices.self) private var services
    @State private var keyInput = ""
    @State private var testing = false
    @State private var testResult: (ok: Bool, message: String)?

    var body: some View {
        @Bindable var settings = services.ai
        Form {
            Section {
                Picker("AI", selection: $settings.engine) {
                    ForEach(AIEngine.allCases) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Recipe extraction")
            } footer: {
                Text(settings.engine == .onDevice
                     ? "Runs on this iPhone. Free and private; nothing leaves the device. Status: \(services.aiAvailability.shortLabel)."
                     : "Uses your own API account, which may cost money per recipe. Transcription, on-screen text and macro math still run on the iPhone; only the recipe text (caption, transcript, on-screen text) is sent to the provider — never the video.")
            }

            if settings.engine == .cloud {
                Section("Provider") {
                    Picker("Provider", selection: $settings.provider) {
                        ForEach(CloudProvider.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    if settings.provider == .anthropic {
                        Picker("Model", selection: $settings.anthropicModel) {
                            ForEach(ClaudeModelPreset.allCases) { preset in
                                Text(preset.displayName).tag(preset.rawValue)
                            }
                            if !ClaudeModelPreset.allCases.map(\.rawValue).contains(settings.anthropicModel) {
                                Text(settings.anthropicModel).tag(settings.anthropicModel)
                            }
                        }
                        TextField("Model ID", text: $settings.anthropicModel)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.footnote.monospaced())
                    } else {
                        Menu {
                            ForEach(EndpointPreset.all) { preset in
                                Button(preset.name) { settings.openAIBaseURL = preset.baseURL }
                            }
                        } label: {
                            LabeledContent("Address", value: presetName(for: settings.openAIBaseURL))
                        }
                        TextField("https://…/v1", text: $settings.openAIBaseURL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.footnote.monospaced())
                        TextField("Model name (from your provider)", text: $settings.openAIModel)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }

                Section {
                    if settings.hasKey[settings.provider] == true {
                        Label("Key saved on this iPhone", systemImage: "key.fill")
                            .foregroundStyle(.green)
                        Button("Remove key", role: .destructive) {
                            settings.deleteKey(for: settings.provider)
                            testResult = nil
                        }
                    }
                    SecureField(settings.hasKey[settings.provider] == true ? "Paste a new key to replace it" : "Paste your API key", text: $keyInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Save key") {
                        settings.saveKey(keyInput, for: settings.provider)
                        keyInput = ""
                        testResult = nil
                    }
                    .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } header: {
                    Text("API key")
                } footer: {
                    Text("Stored only in this iPhone's Keychain. It's never included in logs, exports or backups to other devices.")
                }

                Section {
                    Button {
                        Task { await test() }
                    } label: {
                        if testing {
                            HStack { ProgressView(); Text("Testing…") }
                        } else {
                            Label("Test connection", systemImage: "bolt.horizontal")
                        }
                    }
                    .disabled(testing || settings.hasKey[settings.provider] != true)
                    if let testResult {
                        Label(testResult.message, systemImage: testResult.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(testResult.ok ? .green : .red)
                            .font(.footnote)
                    }
                }
            }
        }
        .navigationTitle("AI")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: settings.provider) { testResult = nil }
    }

    private func presetName(for url: String) -> String {
        EndpointPreset.all.first { $0.baseURL == url }?.name ?? "Custom"
    }

    private func test() async {
        testing = true
        defer { testing = false }
        do {
            let extractor = try services.ai.makeCloudExtractor()
            try await extractor.testConnection()
            testResult = (true, "Connected to \(services.ai.cloudLabel).")
            AppLog.shared.log("ai", "Connection test OK: \(services.ai.cloudLabel)")
        } catch {
            testResult = (false, error.localizedDescription)
            AppLog.shared.log("ai", "Connection test failed: \(services.ai.cloudLabel): \(error.localizedDescription)")
        }
    }
}
