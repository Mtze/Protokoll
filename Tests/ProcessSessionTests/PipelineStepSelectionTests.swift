import Foundation
import Testing
import SharedKit
@testable import ProcessSession

/// CLI `--step` parsing, including the ADR-13 action selections.
struct PipelineStepSelectionTests {
    @Test func parsesAllSelections() {
        #expect(PipelineStepSelection(argument: "all") == .all)
        #expect(PipelineStepSelection(argument: "transcribe") == .only(.transcribe))
        #expect(PipelineStepSelection(argument: "summarize") == .only(.summarize))
        #expect(PipelineStepSelection(argument: "actions") == .only(.actions))
        #expect(PipelineStepSelection(argument: "action:abc") == .only(.action("abc")))
        #expect(PipelineStepSelection(argument: "action:") == nil)
        #expect(PipelineStepSelection(argument: "bogus") == nil)
    }

    @Test func argumentRoundTrips() {
        for selection: PipelineStepSelection in [.all, .only(.transcribe), .only(.actions), .only(.action("x"))] {
            #expect(PipelineStepSelection(argument: selection.argument) == selection)
        }
    }

    @Test func coreStageGates() {
        #expect(PipelineStepSelection.all.runsTranscribe)
        #expect(PipelineStepSelection.all.runsSummarize)
        #expect(PipelineStepSelection.only(.transcribe).runsTranscribe)
        #expect(!PipelineStepSelection.only(.transcribe).runsSummarize)
        #expect(!PipelineStepSelection.only(.actions).runsTranscribe)
        #expect(!PipelineStepSelection.only(.actions).runsSummarize)
        #expect(!PipelineStepSelection.only(.action("x")).runsSummarize)
    }
}
