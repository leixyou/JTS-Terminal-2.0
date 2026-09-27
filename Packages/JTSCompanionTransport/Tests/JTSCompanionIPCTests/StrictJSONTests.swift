import Foundation
import XCTest
import JTSCompanionIPC

final class StrictJSONTests: XCTestCase {
    func testRejectsDuplicateEscapedNestedAndArrayKeys() {
        for json in [#"{"x":1,"x":2}"#, #"{"x":1,"\u0078":2}"#,
                     #"{"items":[{"x":1,"x":2}]}"#, #"{"a":{"b":1,"b":2}}"#] {
            XCTAssertThrowsError(try StrictCompanionJSON.validate(Data(json.utf8)))
        }
    }
    func testRejectsInvalidGrammarUTF8AndNonObjectRoots() {
        for json in ["[]", "true", "null", "{} true", "{\"x\":}", "{\"x\":01}", "{\"x\":NaN}", "{\"x\":\"\\"] {
            XCTAssertThrowsError(try StrictCompanionJSON.validate(Data(json.utf8)))
        }
        XCTAssertThrowsError(try StrictCompanionJSON.validate(Data([123, 34, 255, 34, 58, 49, 125])))
    }
    func testDepthAndRootKeyBounds() throws {
        let shallow = "{\"x\":" + String(repeating: "[", count: 15) + "0" + String(repeating: "]", count: 15) + "}"
        try StrictCompanionJSON.validate(Data(shallow.utf8), requiredKeys: ["x"])
        let deep = "{\"x\":" + String(repeating: "[", count: 16) + "0" + String(repeating: "]", count: 16) + "}"
        XCTAssertThrowsError(try StrictCompanionJSON.validate(Data(deep.utf8)))
        XCTAssertThrowsError(try StrictCompanionJSON.validate(Data("{\"x\":1}".utf8), requiredKeys: []))
        XCTAssertThrowsError(try StrictCompanionJSON.validate(Data("{}".utf8), maximumBytes: 1))
    }
    func testStringEscapesAreNotMistakenForKeysOrDepth() throws {
        try StrictCompanionJSON.validate(Data(#"{"x":"{\"duplicate\":1,\"duplicate\":2}","array":["\\","\u4e2d"]}"#.utf8))
    }
}
