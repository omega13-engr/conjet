import Foundation

/// Parses an argument field without shell expansion or command execution.
public enum CommandArguments {
    public static func parse(_ text: String) throws -> [String] {
        var arguments: [String] = []
        var argument = ""
        var quote: Character?
        var escaped = false
        var started = false

        for character in text {
            if escaped {
                if character != "\n" {
                    if quote == "\"", !["$", "`", "\"", "\\"].contains(character) {
                        argument.append("\\")
                    }
                    argument.append(character)
                    started = true
                }
                escaped = false
            } else if character == "\\", quote != "'" {
                escaped = true
            } else if let currentQuote = quote {
                if character == currentQuote { quote = nil }
                else { argument.append(character) }
            } else if character == "'" || character == "\"" {
                quote = character
                started = true
            } else if character.isWhitespace {
                if started {
                    arguments.append(argument)
                    argument = ""
                    started = false
                }
            } else {
                argument.append(character)
                started = true
            }
        }
        if escaped { throw ParseError("Arguments end with an unfinished backslash escape.") }
        if quote != nil { throw ParseError("Arguments contain an unclosed quote.") }
        if started { arguments.append(argument) }
        return arguments
    }

    public struct ParseError: Error, CustomStringConvertible {
        public let description: String
        init(_ description: String) { self.description = description }
    }
}
