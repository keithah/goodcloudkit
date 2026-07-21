import SwiftUI

struct LoginView: View {
    @ObservedObject var model: AppModel

    @State private var email = ""
    @State private var password = ""
    @FocusState private var focusedField: Field?

    private enum Field { case email, password }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header
                form
            }
            .padding(24)
            .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .background(Theme.pageBackground)
        // Focus the email field once the window is key (a plain onAppear can fire before the
        // window is ready on macOS/SPM, so nudge it a beat later).
        .task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if email.isEmpty { focusedField = .email }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "bolt.horizontal.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(Theme.accent)
                .padding(.top, 32)
            Text("GoodCloud Tester")
                .font(.largeTitle)
                .fontWeight(.bold)
            Text("Sign in with your GoodCloud account")
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Email")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                TextField("you@example.com", text: $email)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    #endif
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .email)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .password }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Password")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .password)
                    .submitLabel(.go)
                    .onSubmit(submit)
            }

            if let error = model.loginError {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(error)
                }
                .font(.footnote)
                .foregroundStyle(Theme.danger)
            }

            Button(action: submit) {
                HStack(spacing: 8) {
                    if model.isLoggingIn {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Image(systemName: "lock.shield")
                    }
                    Text(model.isLoggingIn ? "Signing In…" : "Log In")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(model.isLoggingIn || email.isEmpty || password.isEmpty)
        }
        .cardStyle()
    }

    private func submit() {
        guard !model.isLoggingIn, !email.isEmpty, !password.isEmpty else { return }
        focusedField = nil
        Task { await model.logIn(email: email, password: password) }
    }
}
