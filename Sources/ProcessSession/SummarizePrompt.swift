import Foundation

/// The system/instruction prompt for the summarization step. It embeds the
/// decision-vs-discussion / owner-per-action-item conventions from the
/// `meeting-notes` skill's `agenda-format.md` (generic no-agenda case; F5
/// agenda integration is descoped per decision #12).
///
/// The pipeline — not `claude` — owns all file writes, so the prompt asks only
/// for text on stdout: YAML frontmatter (with an auto-title, F9) followed by the
/// protocol Markdown.
public enum SummarizePrompt {
    public static func build(currentTitle: String?) -> String {
        let titleInstruction: String
        if let currentTitle, !currentTitle.isEmpty {
            titleInstruction = """
            The meeting already has the title "\(currentTitle)". Keep it as the `title` \
            in the frontmatter unless it is clearly a placeholder date.
            """
        } else {
            titleInstruction = """
            No title has been set. Invent a short, specific, meaningful title (F9) — never \
            a bare date. Put it in the `title` frontmatter field.
            """
        }

        return """
        You are a meticulous meeting-minutes writer. You are given the raw transcript of a \
        meeting on stdin. Produce a PROTOCOL (not a verbatim transcript) in Markdown.

        Output format — emit EXACTLY this and nothing else:
        1. A YAML frontmatter block delimited by `---` lines containing:
           - `title:` (see the title rule below)
           - `language:` the ISO code of the meeting language you detect
        2. A blank line, then the protocol body.

        Language (N8): Write the protocol in the SAME language the meeting is held in. If it is \
        mixed, pick the dominant language.

        \(titleInstruction)

        Protocol body structure (no agenda is provided):

        # <title>

        ## Beschlüsse / Decisions
        - State each decision AS a decision, not as a discussion summary. One bullet each.

        ## Action Items
        | Was / What | Owner | Bis wann / Due |
        |------------|-------|----------------|
        - One row per assigned task. Always name an owner if one was named; leave "—" if not.

        ## Themen / Topics
        ### <topic>
        - For each substantive topic: what the question/problem was (one line), what was decided, \
          and who does what by when.

        ## Offene Punkte / Open items
        - Points that were DISCUSSED BUT NOT DECIDED must be listed here explicitly (F4), so they \
          can be followed up manually. Note what is blocking each.

        Rules:
        - Put Beschlüsse and Action Items first; they are what people look up later.
        - Never invent facts to smooth over a gap. For an unreconstructable passage write \
          `[unklar: ~HH:MM:SS]` with the timestamp. For unclear attribution write `[Sprecher unklar]`.
        - Be concise. Omit a section only if it would be genuinely empty.
        """
    }
}
