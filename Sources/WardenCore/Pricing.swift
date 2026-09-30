import Foundation

/// Public API list prices in dollars per million tokens. Plans are billed differently, so a cost from these
/// prices shows what the same use would cost through the API, not what was charged.
public struct ModelPrice: Equatable {
    public var input: Double
    public var output: Double
    public var cacheWrite: Double
    public var cacheWriteHour: Double
    public var cacheRead: Double

    /// Claude's cache multipliers: 1.25x input for a five minute write, 2x for an hour, 0.1x to read.
    static func claude(_ input: Double, _ output: Double, cacheRead: Double? = nil) -> ModelPrice {
        ModelPrice(input: input, output: output, cacheWrite: input * 1.25, cacheWriteHour: input * 2,
                   cacheRead: cacheRead ?? input / 10)
    }

    public func cost(of usage: TokenUsage) -> Double {
        (Double(usage.input) * input + Double(usage.output) * output + Double(usage.cacheWrite) * cacheWrite
            + Double(usage.cacheWriteHour) * cacheWriteHour + Double(usage.cacheRead) * cacheRead) / 1_000_000
    }
}

public enum Pricing {
    public static let verifiedOn = "2026-09-26"
    public static let source = URL(string: "https://platform.claude.com/docs/en/about-claude/pricing")!
    /// Model id prefixes, most specific first. Ids may carry a date suffix, such as `claude-haiku-4-5-20251001`.
    private static let table: [(prefix: String, price: ModelPrice)] = [
        ("claude-fable-5-1", .claude(10, 50, cacheRead: 0.25)),
        ("claude-mythos-5-1", .claude(10, 50, cacheRead: 0.25)),
        ("claude-fable-5", .claude(10, 50)),
        ("claude-mythos-5", .claude(10, 50)),
        ("claude-opus-5-5", .claude(4, 20, cacheRead: 0.2)),
        ("claude-opus-5", .claude(5, 25)),
        ("claude-opus-4-8", .claude(5, 25)),
        ("claude-opus-4-7", .claude(5, 25)),
        ("claude-opus-4-6", .claude(5, 25)),
        ("claude-opus-4-5", .claude(5, 25)),
        ("claude-opus-4-1", .claude(15, 75)),
        ("claude-opus-4", .claude(15, 75)),
        ("claude-3-opus", .claude(15, 75)),
        ("claude-sonnet-5", .claude(2, 10)),
        ("claude-sonnet-4-6", .claude(3, 15)),
        ("claude-sonnet-4-5", .claude(3, 15)),
        ("claude-sonnet-4", .claude(3, 15)),
        ("claude-3-7-sonnet", .claude(3, 15)),
        ("claude-3-5-sonnet", .claude(3, 15)),
        ("claude-haiku-4-5", .claude(1, 5)),
        ("claude-3-5-haiku", .claude(0.8, 4)),
        ("claude-3-haiku", .claude(0.25, 1.25))
    ]

    /// Nil for a model without a known price, whose cost is then left out rather than guessed.
    public static func price(for model: String) -> ModelPrice? {
        // Claude Code names a model's long-context variant with a suffix, such as "claude-opus-5-5[1m]".
        var id = model.lowercased()
        if id.hasSuffix("]"), let bracket = id.lastIndex(of: "[") { id = String(id[..<bracket]) }
        return table.first { entry in
            if id == entry.prefix || id == entry.prefix + "-latest" { return true }
            guard id.hasPrefix(entry.prefix + "-") else { return false }
            let suffix = id.dropFirst(entry.prefix.count + 1)
            // Dated releases use the same published price. An unknown version must not inherit a family price.
            return suffix.count == 8 && suffix.allSatisfy(\.isNumber)
        }?.price
    }
}
