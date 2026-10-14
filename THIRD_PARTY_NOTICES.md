# Third-party notices

FX Vault includes the following third-party software and data. Versions are pinned in
`Packages/FXVaultKit/Package.resolved`.

| Component | Version | License | Used by |
|---|---|---|---|
| [GRDB.swift](https://github.com/groue/GRDB.swift) | 7.11.1 | MIT | VaultStore (SQLite access) |
| [swift-sodium](https://github.com/jedisct1/swift-sodium) (`Clibsodium`, prebuilt libsodium) | 0.11.0 | ISC | VaultCrypto (Argon2id) |
| [EFF Large Wordlist](https://www.eff.org/dice) | sha256 `addd35536511597a02fa0a9ff1e5284677b8883b83e986e43f15a3db996b903e` | CC BY 3.0 US | SharingKit (share passphrases) |

The EFF Large Wordlist is by the Electronic Frontier Foundation, licensed under the Creative
Commons Attribution 3.0 United States license (https://creativecommons.org/licenses/by/3.0/us/).
FX Vault bundles it unmodified as `Sources/SharingKit/Resources/eff_large_wordlist.txt` and, at
run time, excludes its four hyphenated words.

## GRDB.swift (MIT)

```
Copyright (C) 2015-2025 Gwendal Roué

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

## swift-sodium and libsodium (ISC)

```
ISC License

Copyright (c) 2014-2026, Frank Denis <j at pureftpd dot org>

Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted, provided that the above
copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

```
