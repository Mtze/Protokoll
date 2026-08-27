import Foundation

/// The user-editable summary **body spec**: what the protocol should contain.
///
/// Lives in SharedKit because both sides need it - `process-session` composes the
/// prompt from it, and the Mac Settings editor prefills with it and compares
/// against it to decide whether the user has customized anything. The app does not
/// link `ProcessSession` (it ships as a bundled helper), so this is the shared
/// home.
///
/// What is *not* here: the frontmatter contract, the title/language rules, and the
/// grounding rules. Those are enforced by the pipeline in
/// `SummarizePrompt.systemPrompt` and a user cannot edit them, so a bad template
/// can change the shape of a summary but never break the file contract.
public enum SummaryTemplate {
    /// The built-in default: a chronological account of the meeting.
    ///
    /// Deliberately English and unlocalized. Prompt language and output language
    /// are independent - the enforced contract dictates the output language - and a
    /// localized default would make "Reset to default" resolve differently
    /// depending on the app's UI language, so a golden test would have to cover
    /// every locale. Precedent: ``PipelineConfig/vocabulary`` is also unlocalized
    /// free text.
    public static let `default` = """
    Write a chronological account of the meeting: what was discussed, in the order \
    it was discussed.

    - Open with `# <title>`, then 2 to 4 sentences on what the meeting was about \
    and where it ended up.
    - Then one section per stretch of conversation, in the order they occurred, \
    headed `## [HH:MM:SS] <what that stretch was about>`, using the timestamp at \
    which that stretch begins.
    - Give each section 2 to 6 bullets, in the order things were said: what was \
    raised, the substance of the discussion including the reasoning and any \
    disagreement, and how the stretch ended (decided, postponed, dropped, or left \
    open).
    - Aim for one section per 3 to 10 minutes of meeting, so roughly 6 to 12 \
    sections for an hour. Merge neighbouring stretches on the same subject instead \
    of making a section per turn.
    - This is a summary, not a transcript. Never write one bullet per spoken \
    sentence. Quote verbatim only where the exact wording matters: a decision, a \
    commitment, a number, a name. Put timestamps only in section headings, never \
    in bullets.
    - Match the length of the protocol to the meeting: cover the substance, do not \
    pad with filler sections, restatements, or boilerplate.
    - If, and only if, the meeting produced explicit decisions or explicitly \
    assigned tasks, close with `## Decisions` and/or `## Action items` as plain \
    bullets. Where no owner or no deadline was stated, write "not specified" rather \
    than guessing. Omit either section entirely when there is nothing to put in it.
    """

    /// Whether `text` is the built-in default (ignoring surrounding whitespace).
    /// Saving an unchanged template deletes the file instead, so users who never
    /// customize keep receiving improvements to the default.
    public static func isDefault(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            == `default`.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
