import Foundation

/// Plaintext input for creating or editing a login item. It exists only in
/// memory while an edit sheet is open; the provider encrypts every field before
/// it leaves the device, and nothing here is persisted in the clear.
struct VaultItemDraft: Sendable, Hashable {
    /// The item being edited, or nil when creating a new one.
    var itemID: VaultItemID?
    var title: String
    var username: String
    var password: String
    /// A TOTP seed (`otpauth://` URI or bare Base32), or empty for none.
    var totp: String
    var websites: [String]
    var notes: String
    var favorite: Bool

    init(
        itemID: VaultItemID? = nil,
        title: String = "",
        username: String = "",
        password: String = "",
        totp: String = "",
        websites: [String] = [],
        notes: String = "",
        favorite: Bool = false
    ) {
        self.itemID = itemID
        self.title = title
        self.username = username
        self.password = password
        self.totp = totp
        self.websites = websites
        self.notes = notes
        self.favorite = favorite
    }

    var isEditing: Bool { itemID != nil }

    /// A draft is submittable when it has a title; every other field is
    /// optional, matching what a Vaultwarden login requires.
    var canSubmit: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
