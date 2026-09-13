import ConjetAppCore
import XCTest

final class CommandArgumentsTests: XCTestCase {
    func testQuotedValuesAndEmptyArgumentsArePreserved() throws {
        XCTAssertEqual(try CommandArguments.parse(#"--env "GREETING=hello world" --label 'owner=My Team' "" prefix' joined'"#),
                       ["--env", "GREETING=hello world", "--label", "owner=My Team", "", "prefix joined"])
        XCTAssertEqual(try CommandArguments.parse(" \n\t "), [])
    }

    func testEscapingRespectsQuoteContext() throws {
        XCTAssertEqual(try CommandArguments.parse(#"path\ with\ spaces "a\qb\"c\\d" 'literal\slash'"#),
                       ["path with spaces", "a\\qb\"c\\d", "literal\\slash"])
        XCTAssertEqual(try CommandArguments.parse("one\\\ntwo \\\n three"), ["onetwo", "three"])
    }

    func testShellExpressionsArePassedLiterally() throws {
        XCTAssertEqual(try CommandArguments.parse(#""$HOME" '$(touch ignored)' '*.txt' ; | >"#),
                       ["$HOME", "$(touch ignored)", "*.txt", ";", "|", ">"])
    }

    func testMalformedInputFailsBeforeExecution() {
        for input in ["'unfinished", "\"unfinished", "trailing\\"] {
            XCTAssertThrowsError(try CommandArguments.parse(input))
        }
    }
}
