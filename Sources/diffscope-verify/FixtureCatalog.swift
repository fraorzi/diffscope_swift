import Foundation

/// `15-test-corpus-plan.md` §4 transcribed, so that the corpus and the plan can disagree **out
/// loud**.
///
/// This is DEC-057's treatment applied to the fixture list. The keyboard map was a Markdown table
/// and a hand-written menu that could not contradict each other in public, and when they did — a
/// specified function with no implementation — nothing noticed for three milestones. §4 is the same
/// shape: sixty named cases in a document, thirty-four directories on disk, and no link between
/// them. `18-version-one-scope.md`'s definition of done opens with *"every P0 fixture group passes
/// T-0 … T-11"*, which is a claim about a list nothing had ever read.
///
/// **Priority is the plan's, not this file's.** P0 must exist for v1 and its absence fails the
/// suite. P1 and P2 are reported by name and counted; they are deferred scope, and a check that
/// failed on them would be asserting a schedule rather than a property.
enum FixturePriority: String {
    case p0 = "P0"
    case p1 = "P1"
    case p2 = "P2"
}

/// Where a named case is proven. A case that is not a file pair still has to be *somewhere*, and
/// naming that place is the difference between coverage and an excuse.
enum FixtureEvidence {
    /// A directory under `fixtures/`, named identically to the case.
    case corpus
    /// A directory under `fixtures/` whose name differs from the plan's. Recorded rather than
    /// renamed: the fixture's name is in `MANIFEST.json` and in prose across the experiment log.
    case corpusUnder(String)
    /// Proven by a check that constructs the condition instead, with the reason it cannot be a
    /// file pair on disk.
    case elsewhere(where: String, why: String)
}

struct FixtureCase {
    let name: String
    let group: String
    let priority: FixturePriority
    let evidence: FixtureEvidence
}

enum FixtureCatalog {
    static let cases: [FixtureCase] = [
        // §4.1 — the founding cases
        FixtureCase(name: "jsx-wrapper-removal", group: "4.1 founding", priority: .p0, evidence: .corpus),
        FixtureCase(name: "jsx-wrapper-added", group: "4.1 founding", priority: .p0, evidence: .corpus),
        FixtureCase(name: "jsx-wrapper-type-change", group: "4.1 founding", priority: .p0, evidence: .corpus),
        FixtureCase(name: "jsx-text-punctuation", group: "4.1 founding", priority: .p0, evidence: .corpus),
        FixtureCase(name: "string-single-character", group: "4.1 founding", priority: .p0, evidence: .corpus),
        FixtureCase(name: "identifier-typo", group: "4.1 founding", priority: .p0, evidence: .corpus),
        FixtureCase(name: "repeated-identifier-change", group: "4.1 founding", priority: .p0, evidence: .corpus),
        FixtureCase(name: "prop-value-change", group: "4.1 founding", priority: .p0, evidence: .corpus),
        FixtureCase(name: "prop-reordering", group: "4.1 founding", priority: .p0, evidence: .corpus),
        FixtureCase(name: "spread-prop-reordering", group: "4.1 founding", priority: .p0, evidence: .corpus),

        // §4.2 — token and string level
        FixtureCase(name: "tailwind-class-removal", group: "4.2 tokens", priority: .p0, evidence: .corpus),
        FixtureCase(name: "class-order-change", group: "4.2 tokens", priority: .p0, evidence: .corpus),
        FixtureCase(name: "template-literal-change", group: "4.2 tokens", priority: .p0, evidence: .corpus),
        FixtureCase(name: "template-literal-expression-change", group: "4.2 tokens", priority: .p0, evidence: .corpus),
        FixtureCase(name: "clsx-expression-change", group: "4.2 tokens", priority: .p0, evidence: .corpus),
        FixtureCase(name: "quote-style-change", group: "4.2 tokens", priority: .p0, evidence: .corpus),

        // §4.3 — formatting and reordering
        FixtureCase(name: "prettier-formatting", group: "4.3 formatting", priority: .p0, evidence: .corpus),
        FixtureCase(name: "eslint-autofix", group: "4.3 formatting", priority: .p0, evidence: .corpus),
        FixtureCase(name: "whitespace-only", group: "4.3 formatting", priority: .p0, evidence: .corpus),
        FixtureCase(name: "indentation-change", group: "4.3 formatting", priority: .p0, evidence: .corpus),
        FixtureCase(name: "semicolon-change", group: "4.3 formatting", priority: .p0, evidence: .corpus),
        FixtureCase(name: "import-reordering", group: "4.3 formatting", priority: .p0, evidence: .corpus),
        FixtureCase(name: "import-item-removal", group: "4.3 formatting", priority: .p0, evidence: .corpus),
        FixtureCase(name: "object-property-reordering", group: "4.3 formatting", priority: .p0, evidence: .corpus),
        FixtureCase(name: "comment-only-change", group: "4.3 formatting", priority: .p0, evidence: .corpus),

        // §4.4 — Unicode and encoding
        FixtureCase(name: "nfc-vs-nfd", group: "4.4 unicode", priority: .p0, evidence: .corpus),
        FixtureCase(name: "unicode-graphemes", group: "4.4 unicode", priority: .p0, evidence: .corpus),
        FixtureCase(name: "zero-width-characters", group: "4.4 unicode", priority: .p0, evidence: .corpus),
        FixtureCase(name: "bidi-controls", group: "4.4 unicode", priority: .p0, evidence: .corpus),
        FixtureCase(name: "nbsp-vs-space", group: "4.4 unicode", priority: .p0, evidence: .corpus),
        FixtureCase(name: "line-ending-change", group: "4.4 unicode", priority: .p0, evidence: .corpus),
        FixtureCase(name: "mixed-line-endings", group: "4.4 unicode", priority: .p0, evidence: .corpus),
        FixtureCase(name: "invalid-utf8", group: "4.4 unicode", priority: .p0, evidence: .corpus),
        FixtureCase(
            name: "eol-filter-active", group: "4.4 unicode", priority: .p0,
            evidence: .elsewhere(
                where: "DegradationChecks — F8, built against a scratch repository with .gitattributes",
                why: "a filter is a property of a repository, not of a file pair: it needs "
                    + ".gitattributes and an index, which a fixture directory has neither of")),

        // §4.5 — structure and movement
        FixtureCase(name: "moved-function", group: "4.5 movement", priority: .p1, evidence: .corpus),
        FixtureCase(name: "moved-function-modified", group: "4.5 movement", priority: .p1, evidence: .corpus),
        FixtureCase(name: "moved-jsx-subtree", group: "4.5 movement", priority: .p1, evidence: .corpus),
        FixtureCase(name: "duplicated-nodes", group: "4.5 movement", priority: .p1, evidence: .corpus),
        FixtureCase(name: "multiple-similar-siblings", group: "4.5 movement", priority: .p1, evidence: .corpus),

        // §4.6 — degenerate and hostile input
        FixtureCase(name: "invalid-tsx", group: "4.6 degenerate", priority: .p0, evidence: .corpus),
        FixtureCase(name: "truncated-file", group: "4.6 degenerate", priority: .p0, evidence: .corpus),
        FixtureCase(name: "merge-conflict-markers", group: "4.6 degenerate", priority: .p0, evidence: .corpus),
        FixtureCase(name: "minified-file", group: "4.6 degenerate", priority: .p0, evidence: .corpus),
        FixtureCase(name: "binary-file", group: "4.6 degenerate", priority: .p0, evidence: .corpus),
        FixtureCase(name: "image-file", group: "4.6 degenerate", priority: .p0, evidence: .corpus),
        FixtureCase(name: "no-trailing-newline", group: "4.6 degenerate", priority: .p0, evidence: .corpus),
        FixtureCase(name: "empty-file", group: "4.6 degenerate", priority: .p0,
                    evidence: .corpusUnder("empty-to-content")),
        FixtureCase(
            name: "huge-file", group: "4.6 degenerate", priority: .p0,
            evidence: .elsewhere(
                where: "BudgetChecks — a 3.4 MB buffer built in memory, refused above the DEC-050 limit",
                why: "committing a file large enough to exceed the validation threshold would put "
                    + "megabytes in every clone of this repository for one assertion")),
        FixtureCase(
            name: "generated-file", group: "4.6 degenerate", priority: .p0,
            evidence: .elsewhere(
                where: "not proven — OQ-029 is open",
                why: "the behaviour is undefined, and a fixture would freeze an answer nobody has "
                    + "chosen. Listed so the gap is counted rather than forgotten")),

        // §4.7 — file-level operations
        FixtureCase(
            name: "deleted-file", group: "4.7 file-level", priority: .p1,
            evidence: .elsewhere(where: "GitChecks — the four scopes over a scratch repository",
                                 why: "a file-level operation is a property of a repository")),
        FixtureCase(
            name: "added-file", group: "4.7 file-level", priority: .p1,
            evidence: .elsewhere(where: "GitChecks — the four scopes over a scratch repository",
                                 why: "a file-level operation is a property of a repository")),
        FixtureCase(
            name: "renamed-file", group: "4.7 file-level", priority: .p1,
            evidence: .elsewhere(where: "GitChecks", why: "needs an index and rename detection")),
        FixtureCase(
            name: "renamed-and-modified-file", group: "4.7 file-level", priority: .p1,
            evidence: .elsewhere(where: "not proven", why: "rename detection swallowing an edit is "
                                 + "the risk, and nothing exercises it yet")),
        FixtureCase(
            name: "untracked-file", group: "4.7 file-level", priority: .p1,
            evidence: .elsewhere(where: "GitChecks — status and the file list",
                                 why: "an untracked file has no old side in Git at all")),
        FixtureCase(
            name: "symlink", group: "4.7 file-level", priority: .p1,
            evidence: .elsewhere(where: "not proven",
                                 why: "a symlink in the corpus would resolve differently on the "
                                    + "machine that checks it out")),
        FixtureCase(name: "unsupported-language", group: "4.7 file-level", priority: .p1,
                    evidence: .elsewhere(where: "TrustSurfaceChecks and DegradationChecks — F7 on a .css path",
                                         why: "covered by the degradation path rather than a pair")),

        // §4.8 — deferred scope, kept so behaviour is defined
        FixtureCase(name: "css-declaration-change", group: "4.8 deferred", priority: .p2, evidence: .corpus),
        FixtureCase(name: "css-selector-change", group: "4.8 deferred", priority: .p2, evidence: .corpus),
        FixtureCase(name: "inline-style-property-change", group: "4.8 deferred", priority: .p2, evidence: .corpus),
        FixtureCase(name: "json-change", group: "4.8 deferred", priority: .p2, evidence: .corpus),
        FixtureCase(name: "markdown-change", group: "4.8 deferred", priority: .p2, evidence: .corpus),
        FixtureCase(name: "html-change", group: "4.8 deferred", priority: .p2, evidence: .corpus),
    ]

    /// Cases whose entry in §4 states a requirement in words, kept here so the sentence and the
    /// assertion sit together. Only the ones the plan actually commits to — inventing an expected
    /// output per fixture is what `15-…` §3 refuses to do, and for good reason: an expectation file
    /// records what the code did on the day it was written.
    ///
    /// A reorder presented as *formatting-only* is the dangerous claim, because formatting-only is
    /// the one classification the interface is allowed to quieten (DEC-048). Saying it about a
    /// change that can alter behaviour is the failure the plan's *"must not normalize away"* names.
    static let neverFormattingOnly = ["prop-reordering", "spread-prop-reordering",
                                      "object-property-reordering", "import-reordering"]

    /// Fixtures on disk that the plan does not name. Not a failure — `identical` and the two move
    /// shapes added in M8-L are deliberate additions — but worth listing, because a fixture nobody
    /// wrote down is a fixture nobody will maintain.
    static let unlistedButDeliberate: Set<String> = [
        "identical", "moved-block", "moved-two-blocks", "empty-to-content",
    ]
}
