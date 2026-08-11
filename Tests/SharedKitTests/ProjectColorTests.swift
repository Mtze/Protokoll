import Foundation
import Testing
@testable import SharedKit

struct ProjectColorTests {
    @Test func parsesHashPrefixedHex() {
        let rgb = ProjectColor.rgb(fromHex: "#3B82F6")
        #expect(rgb != nil)
        #expect(abs((rgb?.red ?? -1) - Double(0x3B) / 255) < 0.001)
        #expect(abs((rgb?.green ?? -1) - Double(0x82) / 255) < 0.001)
        #expect(abs((rgb?.blue ?? -1) - Double(0xF6) / 255) < 0.001)
    }

    @Test func parsesBareHex() {
        #expect(ProjectColor.rgb(fromHex: "22C55E") != nil)
    }

    @Test func handlesEndpoints() {
        let black = ProjectColor.rgb(fromHex: "#000000")
        #expect(black?.red == 0 && black?.green == 0 && black?.blue == 0)
        let white = ProjectColor.rgb(fromHex: "#FFFFFF")
        #expect(white?.red == 1 && white?.green == 1 && white?.blue == 1)
    }

    @Test func rejectsInvalid() {
        #expect(ProjectColor.rgb(fromHex: "") == nil)
        #expect(ProjectColor.rgb(fromHex: "#FFF") == nil)       // too short
        #expect(ProjectColor.rgb(fromHex: "#GGGGGG") == nil)    // non-hex
        #expect(ProjectColor.rgb(fromHex: "#12345678") == nil)  // too long
    }

    @Test func paletteIsAllValid() {
        for hex in ProjectColor.palette {
            #expect(ProjectColor.rgb(fromHex: hex) != nil)
        }
    }
}
