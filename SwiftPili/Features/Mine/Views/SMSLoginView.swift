import SwiftUI

struct SMSLoginView: View {
    @State private var viewModel = SMSLoginViewModel()
    @State private var showCountryPicker = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                Button(action: { showCountryPicker = true }) {
                    HStack {
                        Text("Region")
                            .foregroundStyle(.primary)
                        Spacer()
                        Text("\(viewModel.countryName) +\(viewModel.countryCode)")
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Text("+\(viewModel.countryCode)")
                        .foregroundStyle(.secondary)
                        .frame(width: 50)
                    Divider()
                    TextField("Phone number", text: $viewModel.phoneNumber)
                        .keyboardType(.phonePad)
                }
            }

            if viewModel.codeSent {
                Section {
                    TextField("Verification code", text: $viewModel.smsCode)
                        .keyboardType(.numberPad)
                }

                Section {
                    Button(action: { Task { await viewModel.login() } }) {
                        if viewModel.isLoading {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Login")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(viewModel.smsCode.isEmpty || viewModel.isLoading)
                }
            } else {
                Section {
                    Button(action: { Task { await viewModel.requestCaptcha() } }) {
                        if viewModel.isLoading {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else if viewModel.cooldown > 0 {
                            Text("Resend (\(viewModel.cooldown)s)")
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Send Code")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(viewModel.phoneNumber.isEmpty || viewModel.isLoading || viewModel.cooldown > 0)
                }
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
        .navigationTitle("SMS Login")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.loadCountryCodes() }
        .sheet(isPresented: $showCountryPicker) {
            CountryCodePickerView(
                countryCodes: viewModel.countryCodes,
                selectedCode: viewModel.countryCode
            ) { country in
                viewModel.countryCode = Int(country.countryId) ?? 86
                viewModel.countryName = country.cname
                showCountryPicker = false
            }
        }
        .sheet(isPresented: $viewModel.needsCaptcha) {
            NavigationStack {
                GeetestView(
                    gt: viewModel.captchaGT,
                    challenge: viewModel.captchaChallenge,
                    token: viewModel.captchaToken,
                    onSuccess: { captcha in
                        viewModel.needsCaptcha = false
                        Task { await viewModel.sendCode(captcha: captcha) }
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

private struct CountryCodePickerView: View {
    let countryCodes: [CountryCodeResult.CountryCode]
    let selectedCode: Int
    let onSelect: (CountryCodeResult.CountryCode) -> Void
    @State private var searchText = ""
    @Environment(\.dismiss) private var dismiss

    private var filtered: [CountryCodeResult.CountryCode] {
        if searchText.isEmpty { return countryCodes }
        return countryCodes.filter {
            $0.cname.localizedCaseInsensitiveContains(searchText)
            || $0.countryId.contains(searchText)
        }
    }

    var body: some View {
        accentedBody.accentContentBoundary()
    }

    @ViewBuilder private var accentedBody: some View {
        NavigationStack {
            List(filtered) { country in
                Button(action: { onSelect(country) }) {
                    HStack {
                        Text(country.cname)
                        Spacer()
                        Text("+\(country.countryId)")
                            .foregroundStyle(.secondary)
                        if Int(country.countryId) == selectedCode {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .searchable(text: $searchText, prompt: "Search country")
            .navigationTitle("Select Region")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
