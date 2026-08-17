import Foundation
import Testing

@testable import StickiesFormat

@Suite("PlistValue")
struct PlistValueTests {
    @Test("Booleans stay booleans instead of collapsing into numbers")
    func distinguishesBoolFromNumber() throws {
        // CFBoolean bridges to NSNumber, so a conversion that checks Int first
        // turns `Floating: true` into `Floating: 1` and changes what Stickies
        // reads back.
        let plist: [String: Any] = ["Floating": true, "ZOrder": 1]
        let value = try PlistValue(propertyList: plist).dictionaryValue

        #expect(value?["Floating"] == .bool(true))
        #expect(value?["ZOrder"] == .integer(1))
    }

    @Test("Reals and integers keep their own representations")
    func distinguishesRealFromInteger() throws {
        // Annotated: without it Swift unifies the literal to [String: Double]
        // and the test measures its own inference rather than the conversion.
        let plist: [String: Any] = ["Red": 0.6784, "SpellCheckingTypes": 9191]
        let value = try PlistValue(propertyList: plist).dictionaryValue

        #expect(value?["Red"] == .double(0.6784))
        #expect(value?["SpellCheckingTypes"] == .integer(9191))
    }

    @Test("Survives a property-list serialization round trip unchanged")
    func roundTripsThroughSerialization() throws {
        let original = PlistValue.dictionary([
            "Text": .string("hello"),
            "Flag": .bool(false),
            "Count": .integer(-3),
            "Ratio": .double(0.5),
            "Blob": .data(Data([0x00, 0xFF])),
            "List": .array([.integer(1), .string("two")]),
            "Nested": .dictionary(["Inner": .bool(true)]),
        ])

        let data = try PropertyListSerialization.data(
            fromPropertyList: original.propertyList,
            format: .xml,
            options: 0
        )
        let decoded = try PlistValue(
            propertyList: try PropertyListSerialization.propertyList(from: data, format: nil)
        )

        #expect(decoded == original)
    }

    @Test("Whole doubles are written as integers, matching Stickies' own output")
    func numberFactoryPrefersIntegers() {
        #expect(PlistValue.number(0) == .integer(0))
        #expect(PlistValue.number(-12) == .integer(-12))
        #expect(PlistValue.number(12.5) == .double(12.5))
    }

    @Test("An integer reads as a double and a whole double reads as an integer")
    func numericAccessorsAreForgiving() {
        // An XML plist round trip can present the same whole number either way.
        #expect(PlistValue.integer(9191).doubleValue == 9191)
        #expect(PlistValue.double(9191).intValue == 9191)
        #expect(PlistValue.string("9191").intValue == nil)
    }

    @Test("A type property lists cannot carry is refused, not silently dropped")
    func refusesUnsupportedTypes() {
        #expect(throws: PlistValue.ConversionError.self) {
            try PlistValue(propertyList: URL(filePath: "/tmp"))
        }
    }
}
