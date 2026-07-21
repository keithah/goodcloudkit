import Foundation

/// Minimal stdout diagnostic logger for the example app. Prints a single line prefixed
/// with `[gck]` and flushes immediately so a process console following along (e.g. via
/// `swift run` or a log viewer) sees output as it happens.
///
/// Callers must never pass secrets here: no passwords, tokens (FE_TOKEN, gl-rtty-token),
/// or Set-Cookie values. Only log identifiers (email, device id/name), protocol/port,
/// HTTP status, byte counts, booleans, and `GoodCloudError.redactedDescription`.
func gcklog(_ s: String) {
    print("[gck] " + s)
    fflush(stdout)
}
