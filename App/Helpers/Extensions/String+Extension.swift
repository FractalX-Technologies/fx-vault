import Foundation

nonisolated extension String {
    /// The text of a localized `^[…](inflect: true)` string, with the grammar agreement applied
    /// ("1 repository", "2 repositories").
    init(inflected text: AttributedString) {
        self.init(text.characters)
    }
}
