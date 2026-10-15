# Third-party notices

FX Vault includes the following third-party software, fonts and data. Package versions are
pinned in `Packages/FXVaultKit/Package.resolved`.

| Component | Version | License | Used by |
|---|---|---|---|
| [GRDB.swift](https://github.com/groue/GRDB.swift) | 7.11.1 | MIT | VaultStore (SQLite access) |
| [swift-sodium](https://github.com/jedisct1/swift-sodium) (`Clibsodium`, prebuilt libsodium) | 0.11.0 | ISC | VaultCrypto (Argon2id) |
| [Geist Sans and Geist Mono](https://github.com/vercel/geist-font) | 1.7.2 | SIL OFL 1.1 | The app UI (`App/Resources/Fonts`) |
| [EFF Large Wordlist](https://www.eff.org/dice) | sha256 `addd35536511597a02fa0a9ff1e5284677b8883b83e986e43f15a3db996b903e` | CC BY 3.0 US | SharingKit (share passphrases) |

The EFF Large Wordlist is by the Electronic Frontier Foundation, licensed under the Creative
Commons Attribution 3.0 United States license (https://creativecommons.org/licenses/by/3.0/us/).
FX Vault bundles it unmodified as `Sources/SharingKit/Resources/eff_large_wordlist.txt` and, at
run time, excludes its four hyphenated words.

Geist Sans and Geist Mono are by The Geist Project Authors, licensed under the SIL Open Font
License 1.1 (no Reserved Font Name). FX Vault bundles six unmodified static faces from the
`geist-font-v1.7.2.zip` release asset (sha256
`7fc800d2ac6b92844895196e5041aca55d814c15db70c44f79b3b83ab82b04e2`), with the license as
`App/Resources/Fonts/Geist-OFL.txt`:

| File | sha256 |
|---|---|
| `Geist-Regular.ttf` | `5c8968eafb98a4c4f47033daf29e38e284a6f2a82eb017d171ab040fe7c4b615` |
| `Geist-Medium.ttf` | `0090e004725f6f64b841715b4167920580f883fcf9b67fc6d744089103fec101` |
| `Geist-SemiBold.ttf` | `612ec98df33935354f39e81e54101656961ab6e5549f64b63eb57868ba7bab8d` |
| `GeistMono-Regular.ttf` | `42d8ad2e610238e64e8abfcde3037c63f7850a73928742b7ab7229d897bcb155` |
| `GeistMono-Medium.ttf` | `90b15711dc3779b2e64e8aff5228154dd019a90bce4947549c4a8a8a43f2ac25` |
| `GeistMono-SemiBold.ttf` | `8b6e127117b03046495b40d4227de66bf5f81f7fe2f4546ee578e89738052314` |
| `Geist-OFL.txt` | `c683bfbcc7e087f5d37a54ef628f10387c451a83ddc459b151403a164ac46c90` |

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

## Geist Sans and Geist Mono (SIL OFL 1.1)

```
Copyright 2024 The Geist Project Authors (https://github.com/vercel/geist-font)

This Font Software is licensed under the SIL Open Font License, Version 1.1.
This license is copied below, and is also available with a FAQ at:
https://openfontlicense.org


-----------------------------------------------------------
SIL OPEN FONT LICENSE Version 1.1 - 26 February 2007
-----------------------------------------------------------

PREAMBLE
The goals of the Open Font License (OFL) are to stimulate worldwide
development of collaborative font projects, to support the font creation
efforts of academic and linguistic communities, and to provide a free and
open framework in which fonts may be shared and improved in partnership
with others.

The OFL allows the licensed fonts to be used, studied, modified and
redistributed freely as long as they are not sold by themselves. The
fonts, including any derivative works, can be bundled, embedded, 
redistributed and/or sold with any software provided that any reserved
names are not used by derivative works. The fonts and derivatives,
however, cannot be released under any other type of license. The
requirement for fonts to remain under this license does not apply
to any document created using the fonts or their derivatives.

DEFINITIONS
"Font Software" refers to the set of files released by the Copyright
Holder(s) under this license and clearly marked as such. This may
include source files, build scripts and documentation.

"Reserved Font Name" refers to any names specified as such after the
copyright statement(s).

"Original Version" refers to the collection of Font Software components as
distributed by the Copyright Holder(s).

"Modified Version" refers to any derivative made by adding to, deleting,
or substituting -- in part or in whole -- any of the components of the
Original Version, by changing formats or by porting the Font Software to a
new environment.

"Author" refers to any designer, engineer, programmer, technical
writer or other person who contributed to the Font Software.

PERMISSION & CONDITIONS
Permission is hereby granted, free of charge, to any person obtaining
a copy of the Font Software, to use, study, copy, merge, embed, modify,
redistribute, and sell modified and unmodified copies of the Font
Software, subject to the following conditions:

1) Neither the Font Software nor any of its individual components,
in Original or Modified Versions, may be sold by itself.

2) Original or Modified Versions of the Font Software may be bundled,
redistributed and/or sold with any software, provided that each copy
contains the above copyright notice and this license. These can be
included either as stand-alone text files, human-readable headers or
in the appropriate machine-readable metadata fields within text or
binary files as long as those fields can be easily viewed by the user.

3) No Modified Version of the Font Software may use the Reserved Font
Name(s) unless explicit written permission is granted by the corresponding
Copyright Holder. This restriction only applies to the primary font name as
presented to the users.

4) The name(s) of the Copyright Holder(s) or the Author(s) of the Font
Software shall not be used to promote, endorse or advertise any
Modified Version, except to acknowledge the contribution(s) of the
Copyright Holder(s) and the Author(s) or with their explicit written
permission.

5) The Font Software, modified or unmodified, in part or in whole,
must be distributed entirely under this license, and must not be
distributed under any other license. The requirement for fonts to
remain under this license does not apply to any document created
using the Font Software.

TERMINATION
This license becomes null and void if any of the above conditions are
not met.

DISCLAIMER
THE FONT SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO ANY WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT
OF COPYRIGHT, PATENT, TRADEMARK, OR OTHER RIGHT. IN NO EVENT SHALL THE
COPYRIGHT HOLDER BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
INCLUDING ANY GENERAL, SPECIAL, INDIRECT, INCIDENTAL, OR CONSEQUENTIAL
DAMAGES, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF THE USE OR INABILITY TO USE THE FONT SOFTWARE OR FROM
OTHER DEALINGS IN THE FONT SOFTWARE.
```
