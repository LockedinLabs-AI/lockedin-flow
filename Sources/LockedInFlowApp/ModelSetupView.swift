import SwiftUI

/// Local instructions only. This view neither downloads nor executes a command.
struct ModelSetupView: View {
    enum Installation: String, CaseIterable, Identifiable {
        case sourceBuild = "I built from source"
        case managedMac = "My Mac is managed by IT"
        var id: Self { self }
    }

    @EnvironmentObject var state: AppState
    @State private var installation: Installation

    init(installation: Installation = .sourceBuild) {
        _installation = State(initialValue: installation)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Set up speech models")
                            .font(.title2.bold())
                            .accessibilityAddTraits(.isHeader)
                        Text(
                            "One-time setup before your first dictation. No recording is started here."
                        )
                        .foregroundStyle(.primary)
                    }

                    Label(
                        state.modelReady ? "Speech model ready" : "Speech model needs attention",
                        systemImage: state.modelReady
                            ? "checkmark.shield" : "externaldrive.badge.exclamationmark"
                    )
                    .font(.headline)

                    if !state.modelReady, !state.modelSwitchInProgress,
                        let error = state.errorMessage
                    {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Picker("Installation method", selection: $installation) {
                        ForEach(Installation.allCases) { route in
                            Text(route.rawValue).tag(route)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityHint(
                        "Shows instructions for your installation; does not change app settings")

                    if installation == .managedMac {
                        managedInstructions
                    } else {
                        sourceInstructions
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        Text("After setup")
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)
                        Text(
                            "Choose Recheck models below. When the model is ready, allow Microphone access and dictate in LockedIn Flow. Copy the transcript when you want to use it elsewhere. Automatic typing into other apps is a separate, optional feature in Settings."
                        )
                        Text(
                            "Dictation runs locally after provisioning. The destination app may still send or sync inserted text under its own policy."
                        )
                        .font(.callout)
                        .foregroundStyle(.primary)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if state.modelSwitchInProgress {
                    ProgressView("Checking models on this Mac…")
                        .controlSize(.small)
                } else if state.modelReady {
                    Text("Model verified. Close this guide to continue setup or dictation.")
                        .font(.callout)
                } else {
                    Text(
                        "Rechecking reads installed models only. It will not download or repair them."
                    )
                    .font(.callout)
                    .foregroundStyle(.primary)
                }
                HStack {
                    Button("Close") { WindowOpener.shared.closeModelSetup() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Recheck models") { Task { await state.prepareModel() } }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(!canRecheck)
                        .accessibilityHint(
                            "Verifies locally provisioned models without using the network or microphone"
                        )
                }
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var canRecheck: Bool {
        !state.modelReady && !state.modelSwitchInProgress
            && [.idle, .ready, .failed].contains(state.pipelineState)
            && !state.canRetryFailedDictation
    }

    private var sourceInstructions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("In Terminal, open your cloned LockedIn Flow repository and run:")
            command("npm run provision:models")
            Text(
                "This command explicitly downloads about 484 MB of pinned models and verifies every file. It does not record audio or send dictations. Model licenses are separate from the app’s MIT license."
            )
            .font(.callout)
            .foregroundStyle(.primary)
            Text("If verification reports damaged or incomplete models:")
                .font(.headline)
            command("npm run provision:models -- --repair")
            Text(
                "Repair downloads and verifies a replacement before replacing the invalid model. Run it only when you choose to repair; this guide does not run commands for you."
            )
            .font(.callout)
            .foregroundStyle(.primary)
            Link(
                "Model licenses and provisioning details (opens GitHub)",
                destination: URL(
                    string:
                        "https://github.com/LockedinLabs-AI/LockedIn-Flow/blob/main/docs/model-licenses.md"
                )!
            )
        }
    }

    private var managedInstructions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(
                "Ask your IT administrator to provision the reviewed speech models through your organization’s approved deployment channel."
            )
            Text(
                "Do not run download or repair commands on a managed Mac unless your organization permits them. LockedIn Flow does not need an external transcription service."
            )
            .font(.callout)
            .foregroundStyle(.primary)
            Text(
                "Administrators: use the pinned model manifest, preserve model attribution, and validate the deployed files and permissions before enabling dictation."
            )
            .font(.callout)
            Link(
                "Managed deployment guide (opens GitHub)",
                destination: URL(
                    string:
                        "https://github.com/LockedinLabs-AI/LockedIn-Flow/blob/main/docs/managed-deployment.md"
                )!
            )
        }
    }

    private func command(_ value: String) -> some View {
        Text(value)
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel("Terminal command: \(value)")
            .accessibilityHint("Selectable text; selecting it does not execute the command")
    }
}
