import Testing
import SQLiteVecStore

// MARK: - SQLiteError

@Suite("SQLiteError.errorDescription")
struct SQLiteErrorTests {
    private let allCases: [SQLiteError] = [
        .databaseOpenFailed(code: 1, message: "detail"),
        .databaseOpenFailed(code: 1, message: nil),
        .databaseNotOpen,
        .registrationFailed(code: 2, message: "detail"),
        .registrationFailed(code: 2, message: nil),
        .executionFailed(code: 3, message: "detail"),
        .executionFailed(code: 3, message: nil),
        .prepareFailed(code: 4, message: "detail"),
        .prepareFailed(code: 4, message: nil),
        .stepFailed(code: 5, message: "detail"),
        .stepFailed(code: 5, message: nil),
        .invalidTableName("my table"),
        .invalidDimension(0),
        .schemaMismatch(expected: "CREATE ...", found: "CREATE ..."),
        .dimensionMismatch(expected: 512, got: 384),
        .metadataTooLarge(limit: 16_384, got: 20_000),
        .invalidTopK(0),
        .rowNotFound(id: 42),
        .invalidTextQuery("\"broken", detail: "fts5: syntax error"),
        .invalidTextQuery("\"broken", detail: nil),
        .lexicalSearchDisabled,
    ]

    @Test func allCasesHaveNonEmptyDescription() {
        for error in allCases {
            let desc = error.errorDescription
            #expect(desc != nil)
            #expect(desc?.isEmpty == false)
        }
    }

    @Test func descriptionsContainNumericCode() {
        let coded: [SQLiteError] = [
            .databaseOpenFailed(code: 99, message: nil),
            .registrationFailed(code: 99, message: nil),
            .executionFailed(code: 99, message: nil),
            .prepareFailed(code: 99, message: nil),
            .stepFailed(code: 99, message: nil),
        ]
        for error in coded {
            #expect(error.errorDescription?.contains("99") == true, "\(error) missing code")
        }
    }

    @Test func nilMessageFallsBackToPlaceholder() {
        let error = SQLiteError.databaseOpenFailed(code: 1, message: nil)
        #expect(error.errorDescription?.contains("no detail") == true)
    }

    @Test func providedMessageAppearsInDescription() {
        let error = SQLiteError.databaseOpenFailed(code: 1, message: "custom msg")
        #expect(error.errorDescription?.contains("custom msg") == true)
    }
}
