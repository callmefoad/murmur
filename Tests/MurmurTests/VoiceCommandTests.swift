import XCTest
@testable import Murmur

final class VoiceCommandTests: XCTestCase {
    func testSpokenWakeWordIsStillRequiredByDefault() {
        XCTAssertNil(
            VoiceCommandParser.parse(
                "open up my text messages with Isaiah and ask him who the painter was"))
    }

    func testHotkeyAuthorizationDoesNotNeedSpokenWakeWord() {
        let command = VoiceCommandParser.parse(
            "open up my text messages with Isaiah and ask him who the painter was",
            authorization: .hotkey)

        XCTAssertEqual(
            command,
            VoiceCommand(action: .message(
                contact: "Isaiah", draft: "Who was the painter?")))
    }

    func testParsesOpenConversationWithoutDraftRequest() {
        let command = VoiceCommandParser.parse(
            "Murmer, open up my text messages with Shannon")

        XCTAssertEqual(
            command,
            VoiceCommand(action: .openMessages(contact: "Shannon")))
    }

    func testCommonRecognitionVariantStillAuthorizes() {
        let command = VoiceCommandParser.parse(
            "Murmer, open messages with Shannon")

        XCTAssertEqual(command?.contactName, "Shannon")
    }

    func testParsesMessageCommandAndBuildsQuestionDraft() {
        let command = VoiceCommandParser.parse(
            "Murmur, I need you to open up my text messages with Isaiah "
                + "and ask him who the painter was on Sunday")

        XCTAssertEqual(
            command,
            VoiceCommand(action: .message(
                contact: "Isaiah", draft: "Who was the painter on Sunday?")))
    }

    func testParsesNonQuestionAsStatementDraft() {
        let command = VoiceCommandParser.parse(
            "Murmur: please open my messages with Alex and tell him I will call tomorrow")

        XCTAssertEqual(command?.contactName, "Alex")
        XCTAssertEqual(command?.draft, "I will call tomorrow.")
    }

    func testPauseBetweenTargetAndRequestStillParses() {
        let command = VoiceCommandParser.parse(
            "Murmur, open messages with Isaiah. Ask him who the painter was")

        XCTAssertEqual(command?.draft, "Who was the painter?")
    }

    func testMalformedOrUnfinishedCommandFallsThrough() {
        XCTAssertNil(VoiceCommandParser.parse("Murmur, please"))
        XCTAssertNil(VoiceCommandParser.parse("open messages with"),
                     "Hotkey mode still requires a contact name.")
    }
}
