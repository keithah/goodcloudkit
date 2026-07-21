import Foundation

public struct SecretRedactor: Sendable {
    private let secrets: Set<String>

    public init(secrets: Set<String> = []) {
        self.secrets = secrets.filter { !$0.isEmpty }
    }

    public func adding(_ secret: String) -> SecretRedactor {
        guard !secret.isEmpty else { return self }
        return SecretRedactor(secrets: secrets.union([secret]))
    }

    public func redact(_ text: String) -> String {
        var out = redactRegisteredSecrets(in: text)
        out = Self.bearerRegex.stringByReplacingMatches(
            in: out,
            range: NSRange(out.startIndex..., in: out),
            withTemplate: "Authorization: Bearer •••"
        )
        return out
    }

    /// Finds every match of every registered secret in the original string, merges
    /// overlapping/adjacent match ranges into maximal intervals, and replaces each
    /// merged interval with a single "•••". Operating on ranges found in the original
    /// (unmutated) string — rather than doing sequential substring replacement — is
    /// what prevents two distinct, non-nested-but-overlapping secrets from leaving a
    /// residual fragment of plaintext exposed (e.g. registering "abcd" and "cdef" must
    /// fully redact "abcdef", not leave behind "ef" or "ab").
    private func redactRegisteredSecrets(in text: String) -> String {
        guard !secrets.isEmpty else { return text }

        var ranges: [Range<String.Index>] = []
        for secret in secrets {
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let found = text.range(of: secret, range: searchStart..<text.endIndex) {
                ranges.append(found)
                searchStart = found.upperBound
            }
        }
        guard !ranges.isEmpty else { return text }

        ranges.sort { $0.lowerBound < $1.lowerBound }

        var merged: [Range<String.Index>] = []
        for range in ranges {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                // Overlapping or adjacent: extend the previous interval.
                let extended = last.lowerBound..<Swift.max(last.upperBound, range.upperBound)
                merged[merged.count - 1] = extended
            } else {
                merged.append(range)
            }
        }

        var out = text
        // Replace right-to-left so earlier indices/ranges remain valid as we mutate.
        for range in merged.reversed() {
            out.replaceSubrange(range, with: "•••")
        }
        return out
    }

    private static let bearerRegex = try! NSRegularExpression(
        pattern: #"Authorization:\s*Bearer\s+\S+"#,
        options: [.caseInsensitive]
    )
}
