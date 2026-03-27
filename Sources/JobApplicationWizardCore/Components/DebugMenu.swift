#if DEBUG
import SwiftUI
import ComposableArchitecture

/// Debug panel opened via Cmd+Shift+D in debug builds.
public struct DebugPanel: View {
    @Bindable public var store: StoreOf<AppFeature>

    public init(store: StoreOf<AppFeature>) {
        self.store = store
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.lg) {
            Label("Debug Menu", systemImage: "ladybug")
                .font(DS.Typography.heading3)

            GroupBox("Cuttle AI") {
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    LabeledContent("Context") {
                        Text(store.cuttle.currentContext.displayLabel(jobs: Array(store.jobs)))
                    }
                    LabeledContent("Messages") {
                        Text("\(store.cuttle.chatMessages.count)")
                            .monospacedDigit()
                    }
                    LabeledContent("Provider") {
                        Text(store.acpConnection.aiProvider == .acpAgent ? "ACP Agent" : "Claude API")
                    }
                    LabeledContent("Tokens used") {
                        Text("\(store.cuttle.tokenUsage.totalTokens)")
                            .monospacedDigit()
                    }
                    LabeledContent("Drop zones") {
                        Text("\(store.cuttle.dropZones.count)")
                            .monospacedDigit()
                    }
                }
                .padding(.vertical, DS.Spacing.xxs)
            }

            GroupBox("Cuttlefish Circle") {
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    JitterCircle()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DS.Spacing.sm)
                }
                .padding(.vertical, DS.Spacing.xxs)
            }

            GroupBox("App State") {
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    LabeledContent("Jobs loaded") {
                        Text("\(store.jobs.count)")
                            .monospacedDigit()
                    }
                    LabeledContent("View mode") {
                        Text(store.viewMode.rawValue)
                    }
                    LabeledContent("ACP connected") {
                        Image(systemName: store.acpConnection.isConnected ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundColor(store.acpConnection.isConnected ? DS.Color.success : DS.Color.textSecondary)
                    }
                }
                .padding(.vertical, DS.Spacing.xxs)
            }

            Spacer()
        }
        .padding(DS.Spacing.xl)
        .frame(minWidth: 320, minHeight: 300)
    }
}

/// Menu commands added in debug builds; provides Cmd+Shift+D shortcut.
public struct DebugMenuCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    public init() {}

    public var body: some Commands {
        CommandMenu("Debug") {
            Button("Debug Panel") {
                openWindow(id: "debug")
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
        }
    }
}
#endif
