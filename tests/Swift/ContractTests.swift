import Foundation
import CoreFoundation

private struct ContractCaseError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

enum ContractTestRunner {
    private static func integer(_ value: Any) throws -> Int {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == Double(number.intValue) else {
            throw ContractCaseError("offset must be an integer, not bool")
        }
        return number.intValue
    }

    private static func ranges(_ value: Any?) throws -> [NSRange] {
        guard let entries = value as? [[Any]] else { throw ContractCaseError("missing [a,b] regions") }
        return try entries.map { pair in
            guard pair.count == 2 else { throw ContractCaseError("region must contain a,b") }
            let a = try integer(pair[0]), b = try integer(pair[1])
            guard a >= 0, b >= 0 else { throw ContractCaseError("negative region endpoint") }
            return NSRange(location: min(a, b), length: max(a, b) - min(a, b))
        }
    }

    private static func flag(_ key: String, _ args: [String: Any]) throws -> Bool {
        guard let raw = args[key] else { return false }
        guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw ContractCaseError("\(key) must be bool")
        }
        return number.boolValue
    }

    private static func matching(_ actual: String, _ expected: Any?) throws {
        guard let expected = expected as? String else { throw ContractCaseError("missing expected text") }
        guard actual.utf16.elementsEqual(expected.utf16) else {
            throw ContractCaseError("text mismatch; expected \(String(reflecting: expected)), got \(String(reflecting: actual))")
        }
    }

    private static func compare(_ result: TextEditResult, _ expected: [String: Any]) throws {
        if let error = result.error { throw ContractCaseError("text operation failed: \(error)") }
        try matching(result.text, expected["text"])
        if let selections = expected["selections"] {
            guard result.selections == (try ranges(selections)) else { throw ContractCaseError("selection mismatch") }
        }
    }

    private static func evaluate(_ vector: [String: Any]) throws -> String? {
        guard let scope = vector["scope"] as? String,
              let input = vector["input"] as? [String: Any],
              let expected = vector["expected"] as? [String: Any] else {
            throw ContractCaseError("vector requires scope/input/expected")
        }
        let args = input["args"] as? [String: Any] ?? [:]
        switch scope {
        case "line-list":
            guard let lines = input["lines"] as? [String], let wanted = expected["lines"] as? [String] else {
                throw ContractCaseError("line-list requires lines arrays")
            }
            let text = lines.joined(separator: "\n")
            let result = TextOperations.sortLines(in: text,
                selections: [NSRange(location: 0, length: (text as NSString).length)],
                caseSensitive: try flag("case_sensitive", args), reverse: try flag("reverse", args),
                removeDuplicates: try flag("remove_duplicates", args))
            try compare(result, ["text": wanted.joined(separator: "\n")])
        case "string-transform":
            guard let command = input["command"] as? String, let text = input["text"] as? String else {
                throw ContractCaseError("string-transform requires command/text")
            }
            guard command == "upper_case" || command == "lower_case" else {
                return "TextOperations exposes upper/lower only; swap_case/title_case are not implemented"
            }
            let result = TextOperations.transform(in: text,
                selections: [NSRange(location: 0, length: (text as NSString).length)], upper: command == "upper_case")
            try compare(result, expected)
        case "buffer-command":
            guard let text = input["text"] as? String, let command = input["command"] as? String else {
                throw ContractCaseError("buffer-command requires text/command")
            }
            let selections = try ranges(input["selections"])
            switch command {
            case "sort_lines":
                try compare(TextOperations.sortLines(in: text, selections: selections,
                    caseSensitive: try flag("case_sensitive", args), reverse: try flag("reverse", args),
                    removeDuplicates: try flag("remove_duplicates", args)), expected)
            case "insert":
                guard let characters = args["characters"] as? String else { throw ContractCaseError("insert needs characters") }
                try compare(TextOperations.apply(in: text,
                    edits: selections.map { TextReplacement(range: $0, text: characters) }), expected)
            case "upper_case", "lower_case":
                try compare(TextOperations.transform(in: text, selections: selections, upper: command == "upper_case"), expected)
            default:
                return "TextOperations is not a named command router; unsupported command behavior belongs to the UI/SDK boundary"
            }
        case "search-query", "search-replace":
            guard let text = input["text"] as? String, let pattern = input["pattern"] as? String,
                  let flags = input["flags"] as? [String], flags.contains("LITERAL") else {
                throw ContractCaseError("search vector requires text/pattern and explicit LITERAL")
            }
            if !Set(flags).isSubset(of: ["LITERAL", "IGNORECASE"]) {
                return "SearchEngine does not implement this vector's full FindFlags"
            }
            let sensitive = !flags.contains("IGNORECASE")
            if scope == "search-query" {
                let actual = try SearchEngine.find(in: text, query: pattern, regex: false, caseSensitive: sensitive)
                guard actual == (try ranges(expected["regions"])) else { throw ContractCaseError("search regions mismatch") }
            } else {
                guard let replacement = input["replacement"] as? String else { throw ContractCaseError("missing replacement") }
                try compare(SearchEngine.replacing(in: text, query: pattern, replacement: replacement,
                    regex: false, caseSensitive: sensitive), expected)
            }
        case "command-sequence":
            return "undo/redo and selection history belong to EditorDocument/UI; this runner tests text operation contracts"
        case "instrumented-command-host", "command-name":
            return "Python SDK command lifecycle/naming has separate plugin_host_test.py validation"
        case "resource-declarations":
            return "shipped declarations are static provenance, not proof of current UI key binding or build execution"
        case "file-roundtrip", "project-roundtrip":
            return "file/project ownership is outside TextOperations; use the dedicated document/project tests"
        case "loader-resolution-decision":
            return "shipped ZipLoader override behavior is not implemented by the explicit one-shot SDK"
        default:
            return "scope is not supported by this bounded text contract runner: \(scope)"
        }
        return nil
    }

    static func run(path: String) -> Int32 {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let version = document["format_version"] as? Int, version == 1,
                  let vectors = document["vectors"] as? [[String: Any]] else {
                throw ContractCaseError("unsupported contract JSON format")
            }
            var rows: [[String: Any]] = []
            var seen = Set<String>()
            for vector in vectors {
                guard let id = vector["id"] as? String, seen.insert(id).inserted,
                      let provenance = vector["provenance"] as? String,
                      let executed = vector["target_executed"] as? Bool, executed == false else {
                    throw ContractCaseError("vector identity/provenance must be unique and target_executed:false")
                }
                var row: [String: Any] = ["id": id, "provenance": provenance]
                do {
                    if let reason = try evaluate(vector) {
                        row["status"] = "skipped"; row["reason"] = reason
                    } else { row["status"] = "passed" }
                } catch {
                    row["status"] = "failed"; row["reason"] = String(describing: error)
                }
                rows.append(row)
            }
            let passed = rows.filter { $0["status"] as? String == "passed" }.count
            let failed = rows.filter { $0["status"] as? String == "failed" }.count
            let report: [String: Any] = ["ok": failed == 0, "vectors": rows.count, "passed": passed,
                "skipped": rows.count - passed - failed, "failed": failed, "results": rows,
                "scope": "independent implementation compared to source-derived/proposed contracts",
                "target_runtime_executed": false, "sublime_runtime_compatibility_verified": false]
            print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
            return failed == 0 ? 0 : 1
        } catch {
            let report: [String: Any] = ["ok": false, "error": String(describing: error), "target_runtime_executed": false]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
                print(String(decoding: data, as: UTF8.self))
            }
            return 1
        }
    }
}
