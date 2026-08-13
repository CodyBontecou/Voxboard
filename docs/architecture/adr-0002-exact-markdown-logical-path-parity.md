# ADR-0002: Exact Markdown and logical-path parity

- Status: **Accepted**
- Product decision ID: `PD-M1-MARKDOWN-PARITY-001`
- Required by: M2 for new-note text/link path-and-byte parity; M5 for the remaining v1 operations unless the implementation plan assigns an operation earlier

## Context

Outcome parity is not satisfied when two platforms produce merely similar notes.
User-owned Markdown and paths are the durable product surface. The shipped Swift
planner, renderer, template renderer, and document editor are the current oracle.

## Decision

Equivalent normalized contract inputs must produce byte-identical UTF-8 note bytes
and identical ordered logical relative path segments on Apple and Android. Native
storage resolves those segments to bookmarks, URLs, tree URIs, or document IDs; such
handles never participate in parity.

The v1 design and synthetic fixtures freeze the current Swift oracle's exact observable
details, including:

- explicit calendar/timezone/date token results and lowercase UUID substitutions;
- `.md` extension behavior, safe relative-path validation, collision suffixing, and
  path segment ordering;
- payload ordering, blank-line placement, boundary-newline trimming, CRLF/CR
  normalization where the existing-note editor performs it, and final trailing-newline
  behavior;
- Markdown/Obsidian link and alias escaping, attachment placement, frontmatter
  recognition/merge ordering, heading selection/creation, and fenced-code exclusion;
- destination entry-template substitutions while literal payload text remains
  uninterpolated; and
- existing request-marker syntax and placement as separately fixed by ADR-0004.

The contract supplies every ambient fact needed for determinism. Locale, current time,
current timezone, filesystem case behavior, provider enumeration order, and unordered
map iteration cannot affect output. Exact parity applies within an explicitly pinned
contract/renderer profile. A reviewed new profile may intentionally change output but
must not rewrite already-prepared jobs.

## Compatibility and consequences

Legacy Apple output is not normalized retroactively. Existing user notes remain
user-owned. The native executor verifies prepared byte length and SHA-256 after commit.
A provider-specific identity may differ while logical path segments and committed bytes
remain exact.

## Rejected alternatives

- **Semantic-equivalence-only Markdown:** rejected because whitespace, frontmatter
  ordering, escaping, and paths are user-visible compatibility.
- **Platform-native path strings in contracts:** rejected because provider syntax is
  neither portable nor deterministic.
- **Clean up the Swift oracle during M2:** rejected because migration and behavior
  changes must be separate reviewed profiles.

## Milestone sequencing and executable gates

M1 freezes the complete v1 parity design and synthetic fixtures, including rolling and
existing-note placement, markers, headings, frontmatter, templates, attachments, and
their newline/link behavior. That freeze is normative design input, not a claim that a
Rust production consumer exists or has passed parity.

M2 implements and executes only the new-note text/link subset. Its golden fixtures run
through the production Swift oracle and Rust consumer and compare exact ordered logical
path-segment arrays and UTF-8 bytes/hashes. The M2 corpus covers only facts that affect
that subset, including Unicode, explicit date/calendar inputs, collision planning, link
escaping, line endings, trailing newlines, and malformed paths. Property tests reject
traversal and nondeterministic ordering. Shadow diagnostics report only pinned
versions, size buckets, and hash equality; they never record content or paths.

Each remaining v1 operation acquires its Swift/Rust (and, when applicable, Kotlin)
exact-parity executable gate only when that operation enters implementation scope.
Under the accepted implementation plan, rolling/existing-note mutation, request-marker
placement and replay, heading/frontmatter/template mutation, and attachment planning
enter that gate in M5 unless the plan explicitly assigns an operation to an earlier
milestone. The corresponding M5 fixtures must compare exact paths and bytes/hashes and
must cover the complete M1-frozen behavior. Deferring execution does not weaken or
convert eventual exact parity to semantic equivalence.

No fixture result is claimed by this ADR.
