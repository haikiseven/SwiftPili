import SwiftUI

struct AccountSwitcherView: View {
    private var accountManager: AccountManager { AccountManager.shared }
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if !accountManager.accounts.isEmpty {
                Section {
                    ForEach(accountManager.accounts) { account in
                        Button {
                            guard account.mid != accountManager.activeMid else { return }
                            accountManager.switchTo(account.mid)
                            dismiss()
                        } label: {
                            row(for: account)
                        }
                        .foregroundStyle(.primary)
                    }
                    .onDelete { offsets in
                        let mids = offsets.map { accountManager.accounts[$0].mid }
                        for mid in mids {
                            accountManager.remove(mid)
                        }
                    }
                }
                .listRowBackground(AppFill.card)
            }

            Section {
                NavigationLink {
                    LoginView()
                } label: {
                    Label {
                        Text("Add Account")
                    } icon: {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(.biliAccent)
                    }
                }
            }
            .listRowBackground(AppFill.card)
        }
        .readableFormWidth()
        .navigationTitle("Accounts")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(for account: StoredAccount) -> some View {
        HStack(spacing: 12) {
            AvatarImage(urlString: account.avatarURL, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: account.name.isEmpty ? "UID \(account.mid)" : account.name)
                    .font(.body)
                if account.sessionExpired == true {
                    Text("Session expired — log in again")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if !account.name.isEmpty {
                    Text(verbatim: "UID \(account.mid)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if account.mid == accountManager.activeMid {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.biliAccent)
            }
        }
    }
}
