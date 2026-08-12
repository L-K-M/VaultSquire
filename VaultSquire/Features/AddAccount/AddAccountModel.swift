import Foundation
import SwiftUI

/// Failures that originate in the add-account flow itself rather than the
/// network layer.
enum AddAccountError: Error {
    /// The server authenticated the account but returned no refresh token, so
    /// there is nothing durable to persist.
    case missingRefreshToken
}

/// A cross-origin service advertisement awaiting the user's decision. The
/// origins are display values for the approval panel only; the panel is the
/// one sanctioned place they appear — they are never folded into an error
/// message. Non-HTTPS advertisements never reach this point: the
/// authenticator discards them and stays on the entered origin.
struct OriginApprovalRequest: Equatable {
    let entered: VaultwardenOrigin
    let effectiveIdentity: VaultwardenOrigin
    let effectiveAPI: VaultwardenOrigin
}

/// Surfaces a differing effective origin to the add-account UI and suspends
/// the login transaction until the user decides. The handler is main-actor
/// isolated; the authenticator awaits into it from its own context, and
/// credentials never leave for an unconfirmed origin. First-login same-origin
/// servers never invoke this.
struct PromptingOriginApprovalPolicy: VaultwardenOriginApprovalPolicy {
    let handler: @MainActor (OriginApprovalRequest) async -> Bool

    func approve(
        entered: VaultwardenOrigin,
        effectiveIdentity: VaultwardenOrigin,
        effectiveAPI: VaultwardenOrigin
    ) async -> Bool {
        await handler(OriginApprovalRequest(
            entered: entered,
            effectiveIdentity: effectiveIdentity,
            effectiveAPI: effectiveAPI
        ))
    }
}

/// A KDF algorithm/parameter change awaiting the user's decision. The values
/// are non-secret derivation settings; they are shown so the user can judge
/// whether the server's new work factors are the ones they set. No ranking of
/// cross-algorithm or mixed changes is attempted — every difference is
/// confirmed, per the security plan.
struct KDFChangeRequest: Equatable {
    let last: VaultwardenKDFConfiguration
    let next: VaultwardenKDFConfiguration

    /// One line per configuration, e.g. "PBKDF2-SHA256, 600,000 iterations".
    static func describe(_ configuration: VaultwardenKDFConfiguration) -> String {
        switch configuration {
        case .pbkdf2SHA256(let iterations):
            return "PBKDF2-SHA256, \(iterations) iterations"
        case .argon2id(let iterations, let memoryMiB, let parallelism):
            return "Argon2id, \(iterations) iterations, \(memoryMiB) MiB memory, \(parallelism) lanes"
        }
    }
}

/// Surfaces a KDF change to the add-account UI and suspends derivation until
/// the user decides. The handler is main-actor isolated; the authenticator
/// awaits into it before any key is derived, so a rejected change never runs
/// the KDF at all.
struct PromptingKDFChangePolicy: VaultwardenKDFChangePolicy {
    let handler: @MainActor (KDFChangeRequest) async -> Bool

    func confirmChange(
        from last: VaultwardenKDFConfiguration?,
        to next: VaultwardenKDFConfiguration
    ) async -> VaultwardenKDFChangeDecision {
        guard let last else { return .reject }
        let approved = await handler(KDFChangeRequest(last: last, next: next))
        return approved ? .approve : .reject
    }
}

/// Drives the add-account and 2FA flow for the UI. It validates the entered
/// server URL locally, runs the M03 login transaction, stores the resulting
/// tokens in the credential store, and exposes only non-secret display state.
/// The master password is held for the shortest time needed to derive the
/// login proof and is cleared immediately afterward.
@MainActor
final class AddAccountModel: ObservableObject, Identifiable {
    nonisolated let id = UUID()

    enum Phase: Equatable {
        case editing
        case connecting
        case challenged
        case succeeded
        case failed(String)
    }

    @Published var serverURL: String = ""
    @Published var email: String = ""
    @Published var masterPassword: String = ""
    @Published private(set) var phase: Phase = .editing

    /// The user-completable providers offered by the server, populated when a
    /// challenge is presented.
    @Published private(set) var offeredProviders: [VaultwardenTwoFactorProvider] = []
    @Published private(set) var hasUnsupportedOnlyChallenge = false
    @Published var twoFactorCode: String = ""
    @Published var selectedProvider: VaultwardenTwoFactorProvider?
    @Published var rememberDevice = false
    /// A non-blocking failure message shown on the challenge screen without
    /// leaving it.
    @Published private(set) var failureMessage: String?
    /// True while an emailed-code request is in flight, so the challenge screen
    /// can disable its send control and avoid duplicate sends from double taps.
    @Published private(set) var isSendingEmailChallenge = false
    /// The pending cross-origin approval, published for the sheet to present.
    @Published private(set) var originApproval: OriginApprovalRequest?
    private var originDecision: CheckedContinuation<Bool, Never>?
    /// The pending KDF-change confirmation, published for the sheet to present.
    @Published private(set) var kdfConfirmation: KDFChangeRequest?
    private var kdfDecision: CheckedContinuation<Bool, Never>?

    private let makeTransport: @Sendable (VaultwardenEnvironment) -> VaultwardenTransport
    private let credentialStore: any VaultwardenCredentialStore
    private let deviceIdentity: VaultwardenDeviceIdentity
    private let onAccountConfigured: @MainActor (URL) -> Void
    private let accountService: VaultwardenAccountService

    private var pending: VaultwardenPendingTwoFactor?
    private var authenticator: VaultwardenAuthenticator?
    private var environment: VaultwardenEnvironment?
    private var activeTask: Task<Void, Never>?

    init(
        credentialStore: any VaultwardenCredentialStore,
        deviceIdentity: VaultwardenDeviceIdentity,
        makeTransport: @escaping @Sendable (VaultwardenEnvironment) -> VaultwardenTransport = { VaultwardenTransport(environment: $0) },
        onAccountConfigured: @escaping @MainActor (URL) -> Void = { _ in },
        accountService: VaultwardenAccountService = VaultwardenAccountService()
    ) {
        self.credentialStore = credentialStore
        self.deviceIdentity = deviceIdentity
        self.makeTransport = makeTransport
        self.onAccountConfigured = onAccountConfigured
        self.accountService = accountService
    }

    var canSubmit: Bool {
        !serverURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !email.trimmingCharacters(in: .whitespaces).isEmpty
            && !masterPassword.isEmpty
            && phase != .connecting
    }

    /// Starts the sign-in transaction in a tracked task the view can cancel on
    /// dismissal, so a dismissed flow never persists credentials. Any prior
    /// task is cancelled first so it cannot mutate state behind the new one.
    func beginSignIn() {
        cancelActiveWork()
        activeTask = Task { await signIn() }
    }

    /// Starts the second-factor submission in the same tracked task.
    func beginSubmitTwoFactor() {
        cancelActiveWork()
        activeTask = Task { await submitTwoFactor() }
    }

    /// Starts the emailed-code request in the same tracked task so dismissal
    /// cancels it too. Guards on the challenge phase before cancelling anything,
    /// so it can never interrupt an in-flight verification.
    func beginSendEmailChallenge() {
        guard phase == .challenged else { return }
        activeTask?.cancel()
        activeTask = Task { await sendEmailChallengeIfNeeded() }
    }

    /// Cancels any in-flight sign-in, two-factor, or email-send task. Called
    /// when the sheet is dismissed.
    func cancel() {
        cancelActiveWork()
        activeTask = nil
    }

    /// Declines any pending origin approval or KDF confirmation and cancels
    /// the tracked task. Resolving both first guarantees a suspended sign-in
    /// resumes (as declined) and observes its cancellation, so a continuation
    /// can never leak past a dismissal or a restarted flow.
    private func cancelActiveWork() {
        resolveOriginApproval(approved: false)
        resolveKDFConfirmation(approved: false)
        activeTask?.cancel()
    }

    /// Publishes the approval request and suspends the login transaction until
    /// the user decides. A restarted flow or a dismissed sheet resolves the
    /// pending request as declined before anything else happens. A task whose
    /// cancellation landed while it was still in flight declines immediately
    /// instead of installing a continuation nothing would ever resume — the
    /// check and the installation share the main actor with `cancel()`, so no
    /// cancellation can slip between them.
    func requestOriginApproval(_ request: OriginApprovalRequest) async -> Bool {
        resolveOriginApproval(approved: false)
        guard !Task.isCancelled else { return false }
        return await withCheckedContinuation { continuation in
            originDecision = continuation
            originApproval = request
        }
    }

    /// Resolves the pending approval; a no-op when none is pending, so the
    /// approval buttons, dismissal, and flow restarts can all call it without
    /// coordinating. Each request resumes exactly once.
    func resolveOriginApproval(approved: Bool) {
        originApproval = nil
        originDecision?.resume(returning: approved)
        originDecision = nil
    }

    /// Publishes the KDF-change request and suspends the login transaction
    /// until the user decides, with the same continuation discipline as the
    /// origin approval: a restart or dismissal resolves it as declined first.
    func requestKDFConfirmation(_ request: KDFChangeRequest) async -> Bool {
        resolveKDFConfirmation(approved: false)
        guard !Task.isCancelled else { return false }
        return await withCheckedContinuation { continuation in
            kdfDecision = continuation
            kdfConfirmation = request
        }
    }

    /// Resolves the pending KDF confirmation; a no-op when none is pending.
    func resolveKDFConfirmation(approved: Bool) {
        kdfConfirmation = nil
        kdfDecision?.resume(returning: approved)
        kdfDecision = nil
    }

    /// Validates the URL and runs the login transaction. On a 2FA challenge the
    /// phase moves to `.challenged`; on success the credentials are stored.
    func signIn() async {
        phase = .connecting

        let environment: VaultwardenEnvironment
        do {
            environment = try VaultwardenEnvironment(configuredURL: serverURL)
        } catch {
            fail(with: Self.message(forURLError: error))
            return
        }

        let authenticator = VaultwardenAuthenticator(
            transport: makeTransport(environment),
            kdfChangePolicy: PromptingKDFChangePolicy { [weak self] request in
                // A deallocated model can approve nothing.
                await self?.requestKDFConfirmation(request) ?? false
            },
            originApprovalPolicy: PromptingOriginApprovalPolicy { [weak self] request in
                // A deallocated model can approve nothing.
                await self?.requestOriginApproval(request) ?? false
            }
        )
        self.authenticator = authenticator
        self.environment = environment

        // Copy the password bytes and clear the stored String promptly, then
        // best-effort zero the byte copy once the login transaction is done.
        var passwordBytes = Data(masterPassword.utf8)
        masterPassword = ""
        defer { VaultwardenCryptoZeroize.zero(&passwordBytes) }

        // The KDF-change baseline is the last accepted configuration persisted
        // for this account, per the security plan: an unchanged response
        // proceeds, and any algorithm or parameter difference suspends the
        // login on the confirmation panel before anything is derived. A first
        // login has no stored snapshot and no baseline, which is the
        // documented residual: there is nothing to compare a hostile server's
        // cheap parameters against.
        let storedSnapshot = try? accountService.loadSnapshot()
        let lastAcceptedKDF = storedSnapshot.flatMap { try? $0.kdf.configuration() }

        do {
            let outcome = try await authenticator.login(
                email: email,
                masterPasswordBytes: passwordBytes,
                device: deviceIdentity,
                lastAcceptedKDF: lastAcceptedKDF
            )
            // If the sheet was dismissed mid-request, do not persist or advance.
            guard !Task.isCancelled else { return }
            switch outcome {
            case .authenticated(let session):
                try store(session)
                phase = .succeeded
                onAccountConfigured(environment.base)
            case .twoFactorRequired(let challenge, let pending):
                self.pending = pending
                presentChallenge(challenge)
            }
        } catch AddAccountError.missingRefreshToken {
            fail(with: "The server did not return the tokens needed to stay signed in.")
        } catch VaultwardenAccountError.accountListUnreadable {
            // Authentication succeeded and was then rolled back, because the
            // stored account list could not be read and writing over it would
            // have discarded the other accounts it holds.
            fail(with: Self.accountListUnreadableMessage)
        } catch is VaultwardenCredentialStoreError {
            // Authentication succeeded; only the local save failed. Say so
            // rather than implying the password was wrong.
            fail(with: "Authentication succeeded, but the credentials could not be saved. Please try again.")
        } catch let error as VaultwardenAPIError {
            fail(with: error.safeDisplayMessage)
        } catch {
            fail(with: "Sign in could not be completed.")
        }
    }

    /// Requests the email second-factor challenge for the selected provider.
    func sendEmailChallengeIfNeeded() async {
        guard let authenticator, let pending,
              selectedProvider?.requiresChallengeDispatch == true,
              !isSendingEmailChallenge else {
            return
        }

        isSendingEmailChallenge = true
        defer { isSendingEmailChallenge = false }
        do {
            try await authenticator.sendEmailChallenge(pending: pending)
        } catch let error as VaultwardenAPIError {
            // Surface the error on the challenge screen; a send failure must not
            // discard the 2FA context and drop the user back to the form.
            failureMessage = error.safeDisplayMessage
        } catch {
            failureMessage = "The verification email could not be sent."
        }
    }

    /// Submits the entered second-factor code for the selected provider.
    func submitTwoFactor() async {
        guard let authenticator, let pending, let provider = selectedProvider else {
            // Inconsistent state (no active challenge); surface feedback rather
            // than a dead button.
            failureMessage = "Something went wrong. Please go back and try again."
            return
        }
        phase = .connecting

        let proof = VaultwardenTwoFactorProof(
            provider: provider,
            token: twoFactorCode,
            rememberDevice: rememberDevice
        )
        do {
            let session = try await authenticator.completeTwoFactor(pending, proof: proof)
            // If the sheet was dismissed mid-request, do not persist or advance.
            guard !Task.isCancelled else { return }
            try store(session)
            // Clear the code only once storage has succeeded, so a save failure
            // does not also blank the field.
            twoFactorCode = ""
            phase = .succeeded
            if let environment {
                onAccountConfigured(environment.base)
            }
        } catch AddAccountError.missingRefreshToken {
            phase = .challenged
            self.failureMessage = "The server did not return the tokens needed to stay signed in."
        } catch VaultwardenAccountError.accountListUnreadable {
            phase = .challenged
            self.failureMessage = Self.accountListUnreadableMessage
        } catch is VaultwardenCredentialStoreError {
            // The code was accepted; only the local save failed. Do not claim
            // the code was rejected.
            phase = .challenged
            self.failureMessage = "Verification succeeded, but the credentials could not be saved. Please start over."
        } catch let error as VaultwardenAPIError {
            phase = .challenged
            self.failureMessage = error.safeDisplayMessage
        } catch {
            // A non-API failure (timeout, cancellation, decode) is not a
            // rejected code, so avoid implying the entered code was wrong.
            phase = .challenged
            self.failureMessage = "Verification could not be completed. Please try again."
        }
    }

    /// Returns from the challenge to the form, preserving the non-secret URL
    /// and email fields.
    func returnToForm() {
        pending = nil
        offeredProviders = []
        selectedProvider = nil
        twoFactorCode = ""
        rememberDevice = false
        failureMessage = nil
        phase = .editing
    }

    // MARK: - Private

    private func presentChallenge(_ challenge: VaultwardenTwoFactorChallenge) {
        offeredProviders = challenge.completableProviders
        hasUnsupportedOnlyChallenge = challenge.hasNoCompletableProvider
        selectedProvider = challenge.completableProviders.first
        phase = .challenged
    }

    private func store(_ session: VaultwardenAuthSession) throws {
        guard let refreshToken = session.refreshToken else {
            // A session with no refresh token has nothing durable to persist,
            // so reporting success would strand the account with nothing to
            // unlock with on the next launch. Surface it as a failure instead.
            throw AddAccountError.missingRefreshToken
        }

        let credentials = VaultwardenStoredCredentials(
            refreshToken: refreshToken,
            rememberedTwoFactorToken: session.rememberTwoFactorToken
        )
        try credentialStore.save(credentials, for: .primary)

        // Persist the non-secret descriptor (so the shell always shows an unlock
        // prompt) and seed the sealed vault. When the login token carried no
        // wrapped key, the seed holds none and the first unlock's sync fetches
        // it from the profile — the account is never stranded in a promptless
        // locked state.
        if let environment {
            do {
                try accountService.persistAfterLogin(
                    session: session,
                    serverBaseURL: environment.base,
                    email: email
                )
            } catch {
                // The credential above is durable and the descriptor is not,
                // which is the promptless locked state itself: the shell reads
                // the descriptor list to decide there is anything to unlock,
                // and reads the Keychain to decide an account exists. Take the
                // credential back out so the two agree and the next attempt
                // starts from nothing rather than from half an account.
                try? credentialStore.delete(for: .primary)
                throw error
            }
        }
    }

    /// Says which of the two is wrong — the stored list, not the sign-in — and
    /// does not suggest adding the account again, which is what the shell's own
    /// locked-state copy suggests and which would fail identically every time.
    static let accountListUnreadableMessage = """
        Signed in, but the saved account list on this Mac could not be read, so         the account was not added. It was left untouched rather than replaced,         because replacing it would remove any other accounts it holds.
        """

    private func fail(with message: String) {
        // A cancelled flow (dismissed sheet, restarted sign-in) must not
        // repaint the form with a stale failure from behind the new state.
        guard !Task.isCancelled else { return }
        phase = .failed(message)
    }

    private static func message(forURLError error: Error) -> String {
        guard let environmentError = error as? VaultwardenEnvironmentError else {
            return "Enter a valid server URL."
        }

        switch environmentError {
        case .schemeNotHTTPS:
            return "The server URL must use HTTPS."
        case .userInfoNotAllowed:
            return "Remove the username and password from the server URL."
        case .queryNotAllowed, .fragmentNotAllowed:
            return "Remove the query or fragment from the server URL."
        case .unsupportedScheme, .invalidURL:
            return "Enter a valid HTTPS server URL."
        }
    }
}
