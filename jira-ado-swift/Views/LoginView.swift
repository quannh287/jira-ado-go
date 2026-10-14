import SwiftUI

struct LoginView: View {
    @Environment(AppModel.self) private var model
    @State private var org = ""
    @State private var pat = ""
    @State private var remember = true
    @State private var checking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "arrow.triangle.2.circlepath").font(.largeTitle).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text("Sign in to Azure DevOps").font(.title2.bold())
                Text("Paste a Personal Access Token with Work Items (Read & Write) scope.").font(.callout).foregroundStyle(.secondary)
            }
            Form {
                TextField("Organization", text: $org, prompt: Text("my-org"))
                    .accessibilityIdentifier("login.org")
                SecureField("Personal Access Token", text: $pat, prompt: Text("ADO PAT"))
                    .accessibilityIdentifier("login.pat")
                    .onSubmit(signIn)
                Toggle("Remember in Keychain", isOn: $remember)
                    .help("Off: you sign in again every time the app starts")
            }
            .disabled(checking)
            if !model.loginError.isEmpty {
                Text(model.loginError).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                if checking {
                    ProgressView().controlSize(.small)
                    Text("Checking with ADO…").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Sign In", action: signIn)
                    .keyboardShortcut(.defaultAction)
                    .disabled(checking || org.trimmingCharacters(in: .whitespaces).isEmpty || pat.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(28)
        .frame(width: 420)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { org = model.setting(Setting.adoOrg) }
    }

    private func signIn() {
        guard !checking, !org.isEmpty, !pat.isEmpty else { return }
        checking = true
        Task {
            await model.signIn(org: org, pat: pat, remember: remember)
            checking = false
            if !model.pat.isEmpty { pat = "" }
        }
    }
}

#Preview("Login") {
    LoginView().previewModel(PreviewData.model(signedIn: false)).frame(width: 700, height: 560)
}

#Preview("Login · Error") {
    let model = PreviewData.model(signedIn: false)
    model.loginError = "ADO rejected the personal access token"
    return LoginView().environment(model).frame(width: 700, height: 560)
}
