import SwiftUI
import CoreImage.CIFilterBuiltins

struct LoginView: View {
    @State private var selectedMethod = 0
    @State private var qrVM = QRCodeLoginViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedMethod) {
                Text("QR Code").tag(0)
                Text("SMS").tag(1)
                Text("Password").tag(2)
            }
            .pickerStyle(.segmented)
            .padding()

            switch selectedMethod {
            case 0:
                QRLoginContent(loginVM: qrVM, dismiss: dismiss)
            case 1:
                SMSLoginView()
            case 2:
                PasswordLoginView()
            default:
                EmptyView()
            }
        }
        // One cap for the whole screen, not one per method: the SMS and
        // password forms are only ever drawn inside this switch, so capping
        // them again would paint a second background over an identical one.
        .readableFormWidth()
        .navigationTitle("Login")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { qrVM.cancel() }
        .onChange(of: selectedMethod) {
            if selectedMethod != 0 { qrVM.cancel() }
        }
    }
}

// MARK: - QR Code Login

private struct QRLoginContent: View {
    @Bindable var loginVM: QRCodeLoginViewModel
    @State private var showCookieImport = false
    let dismiss: DismissAction

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            switch loginVM.state {
            case .idle, .loading:
                ProgressView("Generating QR Code...")

            case .ready(let url, _):
                Text("Scan with BiliBili app")
                    .font(.headline)
                if let image = generateQRCode(from: url) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 200, height: 200)
                }

            case .scanning:
                Image(systemName: "checkmark.circle")
                    .font(.largeTitle)
                    .foregroundStyle(.green)
                Text("Scanned! Confirm on your phone.")

            case .confirmed:
                Image(systemName: "checkmark.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.green)
                Text("Login successful!")
                    .onAppear {
                        Task {
                            try? await Task.sleep(for: .seconds(1))
                            dismiss()
                        }
                    }

            case .expired:
                Text("QR Code expired")
                Button("Regenerate") {
                    Task { await loginVM.generateQRCode() }
                }
                .buttonStyle(.bordered)

            case .failed(let message):
                Text("Login failed: \(message)")
                    .foregroundStyle(.red)
                Button("Retry") {
                    Task { await loginVM.generateQRCode() }
                }
                .buttonStyle(.bordered)
            }

            Spacer()

            Divider()
                .padding(.horizontal, 40)

            Button("Import Cookies") {
                showCookieImport = true
            }
            .buttonStyle(.bordered)
            .padding(.bottom)
        }
        .task { await loginVM.generateQRCode() }
        .onDisappear { loginVM.cancel() }
        .sheet(isPresented: $showCookieImport) {
            CookieImportView(dismiss: dismiss)
        }
    }

    private func generateQRCode(from string: String) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"

        guard let ciImage = filter.outputImage else { return nil }
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

// MARK: - Cookie Import

private struct CookieImportView: View {
    @State private var cookieString = ""
    let dismiss: DismissAction

    // Presented as a sheet, which is its own presentation context: the tab
    // root's `accentContentBoundary()` lives inside a NavigationStack and
    // cannot reach here, so without this the screen renders the PLATFORM
    // accent while everything behind it renders the chosen one. Declared on
    // the view rather than at the call site so every presentation of it —
    // including future ones — is covered.
    var body: some View {
        accentedBody.accentContentBoundary()
    }

    @ViewBuilder private var accentedBody: some View {
        NavigationStack {
            Form {
                Section("Paste your cookie string") {
                    TextEditor(text: $cookieString)
                        .frame(minHeight: 100)
                }

                Section {
                    Button("Import") {
                        importCookies(cookieString)
                    }
                    .disabled(cookieString.isEmpty)
                }
            }
            .listRowBackground(AppFill.card)
            .readableFormWidth(.ambientBrowse)
            .navigationTitle("Cookie Import")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func importCookies(_ raw: String) {
        let pairs = raw.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        var cookies: [String: String] = [:]
        for pair in pairs {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            cookies[String(kv[0])] = String(kv[1])
        }

        if let sessData = cookies["SESSDATA"],
           let biliJct = cookies["bili_jct"],
           let dedeUserID = cookies["DedeUserID"] {
            AuthManager.shared.loginWithCookies(
                sessData: sessData,
                biliJct: biliJct,
                dedeUserID: dedeUserID,
                ckMd5: cookies["DedeUserID__ckMd5"]
            )
            dismiss()
        }
    }
}
