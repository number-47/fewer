import FewerCore
import SwiftUI
import UniformTypeIdentifiers

struct TemplateSettingsView: View {
    @ObservedObject var model: SettingsViewModel
    @State private var importing = false

    var body: some View {
        ScrollView {
            FewerSettingsCard {
                FewerSettingsRow {
                    Text("内置模板").fontWeight(.semibold)
                    Spacer()
                    Button("+ 导入模板") { importing = true }.buttonStyle(.plain).foregroundStyle(.blue)
                }
                ForEach(model.templates) { descriptor in
                    Divider()
                    TemplateRow(
                        descriptor: descriptor,
                        onChange: model.updateTemplate,
                        onReveal: { model.revealTemplate(descriptor) },
                        onDelete: { model.deleteTemplate(descriptor) }
                    )
                }
            }
            .padding(.bottom, 24)
        }
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result, let url = urls.first {
                model.importTemplate(from: url)
            }
        }
    }
}

private struct TemplateRow: View {
    @State private var descriptor: TemplateDescriptor
    let onChange: (TemplateDescriptor) -> Void
    let onReveal: () -> Void
    let onDelete: () -> Void

    init(
        descriptor: TemplateDescriptor,
        onChange: @escaping (TemplateDescriptor) -> Void,
        onReveal: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        _descriptor = State(initialValue: descriptor)
        self.onChange = onChange
        self.onReveal = onReveal
        self.onDelete = onDelete
    }

    var body: some View {
        HStack {
            Toggle("", isOn: $descriptor.isEnabled)
                .labelsHidden()
                .onChange(of: descriptor.isEnabled) { _, _ in onChange(descriptor) }
            VStack(alignment: .leading) {
                TextField("模板名称", text: $descriptor.displayName)
                    .textFieldStyle(.plain)
                    .onSubmit { onChange(descriptor) }
                Text(".\(descriptor.fileExtension) · \(descriptor.source == .builtIn ? "内置" : "自定义")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("显示") { onReveal() }
            if descriptor.source == .user {
                Button("删除", role: .destructive) { onDelete() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minHeight: 40)
    }
}
