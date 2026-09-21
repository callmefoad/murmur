import AppKit
import ApplicationServices
import Contacts
import Foundation

/// Resolves a spoken contact name and prepares a message draft. Sending is
/// deliberately absent from this API: the user must see and send the message
/// themselves in Messages.
enum VoiceCommandExecutor {
    struct ContactDestination: Equatable {
        let displayName: String
        let address: String
    }

    enum PreparationResult: Equatable {
        case placed(displayName: String)
        case copied

        var status: String {
            switch self {
            case .placed(let displayName):
                return "Draft placed in Messages with \(displayName) — review before sending."
            case .copied:
                return "Draft copied — open Messages, choose the contact, and paste to review."
            }
        }
    }

    /// Opens Messages for the contact when Contacts can resolve an address.
    /// After the app opens, waits for Messages and its composer to become
    /// ready before inserting. Otherwise the draft is copied, which is safer
    /// than typing into an unexpected application or falsely claiming success.
    static func prepareMessageDraft(
        contactName: String,
        draft: String
    ) async -> PreparationResult {
        let destination = await resolveContact(named: contactName)
        let openedAddressedConversation = openMessages(for: destination?.address)

        guard openedAddressedConversation else {
            TextInserter.place(draft)
            return .copied
        }

        // Messages can report itself as frontmost before the conversation's
        // composer is focused. Poll briefly rather than racing that handoff;
        // this keeps the fast path quick while making the common URL-launch
        // case reliable.
        for _ in 0..<12 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                    == "com.apple.MobileSMS"
            else { continue }

            if TextInserter.hasFocusedEditableElement() {
                _ = TextInserter.insert(draft)
                return .placed(displayName: destination?.displayName ?? contactName)
            }

            // An addressed sms: URL can select the right conversation without
            // focusing its composer. Ask Messages' accessibility tree for the
            // multiline editor, then let the next poll verify that focus moved
            // before any text is written.
            _ = TextInserter.focusFirstEditableElement(
                in: NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)
        }

        TextInserter.place(draft)
        return .copied
    }

    /// Contact lookup is intentionally deferred until the user approves the
    /// preview. The first command may prompt for Contacts access; denying it
    /// simply falls back to opening Messages and copying the draft.
    private static func resolveContact(named name: String) async -> ContactDestination? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let store = CNContactStore()
                let status = CNContactStore.authorizationStatus(for: .contacts)

                let finish: (Bool) -> Void = { granted in
                    guard granted else {
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: lookup(name: name, in: store))
                }

                switch status {
                case .authorized, .limited:
                    finish(true)
                case .notDetermined:
                    store.requestAccess(for: .contacts) { granted, _ in
                        finish(granted)
                    }
                case .denied, .restricted:
                    finish(false)
                @unknown default:
                    finish(false)
                }
            }
        }
    }

    private static func lookup(
        name: String,
        in store: CNContactStore
    ) -> ContactDestination? {
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
        ]
        guard let contacts = try? store.unifiedContacts(
            matching: CNContact.predicateForContacts(matchingName: name),
            keysToFetch: keys),
            let contact = contacts.first(where: {
                displayName(of: $0).localizedCaseInsensitiveCompare(name) == .orderedSame
            }) ?? contacts.first else {
            return nil
        }

        if let phone = contact.phoneNumbers.first?.value.stringValue,
           !phone.isEmpty {
            return ContactDestination(
                displayName: displayName(of: contact), address: phone)
        }
        if let email = contact.emailAddresses.first?.value as String?, !email.isEmpty {
            return ContactDestination(
                displayName: displayName(of: contact), address: email)
        }
        return nil
    }

    private static func displayName(of contact: CNContact) -> String {
        let name = CNContactFormatter.string(from: contact, style: .fullName)
        return name?.trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
            ? name!
            : contact.givenName
    }

    private static func openMessages(for address: String?) -> Bool {
        if let address, !address.isEmpty {
            let encoded = address.addingPercentEncoding(
                withAllowedCharacters: .urlPathAllowed) ?? address
            if let url = URL(string: "sms:\(encoded)"), NSWorkspace.shared.open(url) {
                return true
            }
        }

        if let appURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.MobileSMS") {
            NSWorkspace.shared.openApplication(
                at: appURL, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(
                URL(fileURLWithPath: "/System/Applications/Messages.app"))
        }
        return false
    }
}
