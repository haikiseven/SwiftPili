import SwiftUI

struct PasswordLoginView: View {
    @State private var viewModel = PasswordLoginViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                TextField("Phone / Email", text: $viewModel.username)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                SecureField("Password", text: $viewModel.password)
                    .textContentType(.password)
            }

            Section {
                Button(action: { Task { await viewModel.requestCaptcha() } }) {
                    if viewModel.isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Login")
                            .frame(maxWidth: .infinity)
                    }
                }
                .disabled(viewModel.username.isEmpty || viewModel.password.isEmpty || viewModel.isLoading)
            }

            if let error = viewModel.errorMessage {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
        }
        .listRowBackground(AppFill.card)
        .scrollContentBackground(.hidden)
        .navigationTitle("Password Login")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $viewModel.needsCaptcha) {
            NavigationStack {
                GeetestView(
                    gt: viewModel.captchaGT,
                    challenge: viewModel.captchaChallenge,
                    token: viewModel.captchaToken,
                    onSuccess: { captcha in
                        viewModel.needsCaptcha = false
                        Task { await viewModel.login(captcha: captcha) }
                    },
                    onFailure: {
                        viewModel.needsCaptcha = false
                        viewModel.errorMessage = String(localized: "Captcha verification failed")
                    }
                )
                .navigationTitle("Verify")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { viewModel.needsCaptcha = false }
                    }
                }
            }
            .presentationDetents([.large])
        }
        .onChange(of: viewModel.loginSuccess) {
            if viewModel.loginSuccess { dismiss() }
        }
    }
}
