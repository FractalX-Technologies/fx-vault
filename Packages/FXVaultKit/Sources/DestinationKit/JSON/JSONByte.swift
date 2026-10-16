/// The ASCII bytes of JSON's grammar (RFC 8259), shared by the writer and the scanner.
enum JSONByte {
    static let quote: UInt8 = 0x22
    static let backslash: UInt8 = 0x5C
    static let slash: UInt8 = 0x2F
    static let comma: UInt8 = 0x2C
    static let colon: UInt8 = 0x3A
    static let minus: UInt8 = 0x2D
    static let plus: UInt8 = 0x2B
    static let dot: UInt8 = 0x2E
    static let zero: UInt8 = 0x30
    static let nine: UInt8 = 0x39
    static let openBrace: UInt8 = 0x7B
    static let closeBrace: UInt8 = 0x7D
    static let openBracket: UInt8 = 0x5B
    static let closeBracket: UInt8 = 0x5D
    static let space: UInt8 = 0x20
    static let tab: UInt8 = 0x09
    static let lineFeed: UInt8 = 0x0A
    static let carriageReturn: UInt8 = 0x0D
    static let backspace: UInt8 = 0x08
    static let formFeed: UInt8 = 0x0C
    static let lowercaseA: UInt8 = 0x61
    static let lowercaseB: UInt8 = 0x62
    static let lowercaseE: UInt8 = 0x65
    static let lowercaseF: UInt8 = 0x66
    static let lowercaseN: UInt8 = 0x6E
    static let lowercaseR: UInt8 = 0x72
    static let lowercaseT: UInt8 = 0x74
    static let lowercaseU: UInt8 = 0x75
    static let uppercaseA: UInt8 = 0x41
    static let uppercaseE: UInt8 = 0x45
    static let uppercaseF: UInt8 = 0x46
    /// Bytes below this are control characters, which a JSON string must escape.
    static let firstPrintable: UInt8 = 0x20
}
