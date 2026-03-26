import SwiftUI
import ClaudeRelayClient

/// Modal form for adding or editing a server configuration.
/// This screen is configuration only — no connection happens here.
struct AddEditServerView: View {
    @StateObject private var viewModel: AddEditServerViewModel
    @Environment(\.dismiss) private var dismiss

    let onSave: ((ConnectionConfig) -> Void)?

    init(mode: AddEditServerViewModel.Mode, onSave: ((ConnectionConfig) -> Void)? = nil) {
        _viewModel = StateObject(wrappedValue: AddEditServerViewModel(mode: mode))
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Server Name", text: $viewModel.name)
                        .textContentType(.name)
                        .autocorrectionDisabled()

                    TextField("Host", text: $viewModel.host)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    TextField("Port", text: $viewModel.port)
                        .keyboardType(.numberPad)

                    SecureField("Auth Token", text: $viewModel.token)

                    Toggle("Use TLS", isOn: $viewModel.useTLS)
                }

                Section {
                    Button {
                        if let config = viewModel.save() {
                            onSave?(config)
                            dismiss()
                        }
                    } label: {
                        HStack {
                            Spacer()
                            Text(viewModel.saveButtonTitle)
                                .fontWeight(.semibold)
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowBackground(viewModel.isValid ? Color.red : Color(.systemGray5))
                    .foregroundStyle(viewModel.isValid ? .white : .black)
                    .disabled(!viewModel.isValid)
                }
            }
            .navigationTitle(viewModel.navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

#Preview("Add") {
    AddEditServerView(mode: .add)
}
