import SwiftUI

struct RootSettingsView: View {
    @StateObject private var model = SettingsViewModel()
    @State private var selection: SettingsSection? = .overview

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .navigationTitle("Fewer")
        } detail: {
            Group {
                switch selection ?? .overview {
                case .overview:
                    OverviewView(model: model)
                case .contextMenu:
                    ContextMenuSettingsView(model: model)
                case .templates:
                    TemplateSettingsView(model: model)
                case .shortcuts:
                    ShortcutSettingsView(model: model)
                case .screenshot:
                    ScreenshotSettingsView()
                case .general:
                    GeneralSettingsView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .alert("Fewer", isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )) {
                Button("好") { model.errorMessage = nil }
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
    }
}
