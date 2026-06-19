// Copyright (c) 2026 GitSwift LLC
//
// Licensed under the MIT License.
// See LICENSE for details.

import Testing
import TraversioMoshCrypto

struct MoshAES128OCBTests {
    @Test("RFC 7253 AES-128 OCB TAGLEN128 vectors", arguments: rfc7253AES128Vectors)
    func sealsAndOpensRFC7253Vector(vector: OCBVector) throws {
        let ocb = try MoshAES128OCB(rawKey: hex("000102030405060708090A0B0C0D0E0F"))
        let ciphertext = try ocb.seal(
            plaintext: hex(vector.plaintext),
            nonce: hex(vector.nonce),
            associatedData: hex(vector.associatedData)
        )

        #expect(ciphertext == hex(vector.ciphertext))

        let plaintext = try ocb.open(
            ciphertext: ciphertext,
            nonce: hex(vector.nonce),
            associatedData: hex(vector.associatedData)
        )

        #expect(plaintext == hex(vector.plaintext))
    }

    @Test
    func rejectsTamperedCiphertextTag() throws {
        let ocb = try MoshAES128OCB(rawKey: hex("000102030405060708090A0B0C0D0E0F"))
        var ciphertext = try ocb.seal(
            plaintext: hex("0001020304050607"),
            nonce: hex("BBAA99887766554433221101"),
            associatedData: hex("0001020304050607")
        )
        ciphertext[ciphertext.count - 1] ^= 0x01

        #expect(throws: MoshAES128OCBError.authenticationFailed) {
            _ = try ocb.open(
                ciphertext: ciphertext,
                nonce: hex("BBAA99887766554433221101"),
                associatedData: hex("0001020304050607")
            )
        }
    }

    @Test("Rejects invalid nonce lengths", arguments: [0, 16])
    func rejectsInvalidNonceLengths(length: Int) throws {
        let ocb = try MoshAES128OCB(rawKey: hex("000102030405060708090A0B0C0D0E0F"))

        #expect(throws: MoshAES128OCBError.invalidNonceLength(length)) {
            _ = try ocb.seal(plaintext: [], nonce: [UInt8](repeating: 0, count: length))
        }
    }

    @Test
    func rejectsCiphertextShorterThanTag() throws {
        let ocb = try MoshAES128OCB(rawKey: hex("000102030405060708090A0B0C0D0E0F"))

        #expect(throws: MoshAES128OCBError.ciphertextTooShort(15)) {
            _ = try ocb.open(
                ciphertext: [UInt8](repeating: 0, count: 15),
                nonce: hex("BBAA99887766554433221100")
            )
        }
    }
}

struct OCBVector: Sendable {
    let nonce: String
    let associatedData: String
    let plaintext: String
    let ciphertext: String
}

private let rfc7253AES128Vectors = [
    OCBVector(
        nonce: "BBAA99887766554433221100",
        associatedData: "",
        plaintext: "",
        ciphertext: "785407BFFFC8AD9EDCC5520AC9111EE6"
    ),
    OCBVector(
        nonce: "BBAA99887766554433221101",
        associatedData: "0001020304050607",
        plaintext: "0001020304050607",
        ciphertext: "6820B3657B6F615A5725BDA0D3B4EB3A257C9AF1F8F03009"
    ),
    OCBVector(
        nonce: "BBAA99887766554433221102",
        associatedData: "0001020304050607",
        plaintext: "",
        ciphertext: "81017F8203F081277152FADE694A0A00"
    ),
    OCBVector(
        nonce: "BBAA99887766554433221103",
        associatedData: "",
        plaintext: "0001020304050607",
        ciphertext: "45DD69F8F5AAE72414054CD1F35D82760B2CD00D2F99BFA9"
    ),
    OCBVector(
        nonce: "BBAA99887766554433221104",
        associatedData: "000102030405060708090A0B0C0D0E0F",
        plaintext: "000102030405060708090A0B0C0D0E0F",
        ciphertext: "571D535B60B277188BE5147170A9A22C3AD7A4FF3835B8C5701C1CCEC8FC3358"
    ),
    OCBVector(
        nonce: "BBAA99887766554433221105",
        associatedData: "000102030405060708090A0B0C0D0E0F",
        plaintext: "",
        ciphertext: "8CF761B6902EF764462AD86498CA6B97"
    ),
    OCBVector(
        nonce: "BBAA99887766554433221106",
        associatedData: "",
        plaintext: "000102030405060708090A0B0C0D0E0F",
        ciphertext: "5CE88EC2E0692706A915C00AEB8B2396F40E1C743F52436BDF06D8FA1ECA343D"
    ),
    OCBVector(
        nonce: "BBAA99887766554433221107",
        associatedData: "000102030405060708090A0B0C0D0E0F1011121314151617",
        plaintext: "000102030405060708090A0B0C0D0E0F1011121314151617",
        ciphertext: "1CA2207308C87C010756104D8840CE1952F09673A448A122C92C62241051F57356D7F3C90BB0E07F"
    ),
    OCBVector(
        nonce: "BBAA99887766554433221108",
        associatedData: "000102030405060708090A0B0C0D0E0F1011121314151617",
        plaintext: "",
        ciphertext: "6DC225A071FC1B9F7C69F93B0F1E10DE"
    ),
    OCBVector(
        nonce: "BBAA99887766554433221109",
        associatedData: "",
        plaintext: "000102030405060708090A0B0C0D0E0F1011121314151617",
        ciphertext: "221BD0DE7FA6FE993ECCD769460A0AF2D6CDED0C395B1C3CE725F32494B9F914D85C0B1EB38357FF"
    ),
    OCBVector(
        nonce: "BBAA9988776655443322110A",
        associatedData: "000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F",
        plaintext: "000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F",
        ciphertext: "BD6F6C496201C69296C11EFD138A467ABD3C707924B964DEAFFC40319AF5A48540FBBA186C5553C68AD9F592A79A4240"
    ),
    OCBVector(
        nonce: "BBAA9988776655443322110B",
        associatedData: "000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F",
        plaintext: "",
        ciphertext: "FE80690BEE8A485D11F32965BC9D2A32"
    ),
    OCBVector(
        nonce: "BBAA9988776655443322110C",
        associatedData: "",
        plaintext: "000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F",
        ciphertext: "2942BFC773BDA23CABC6ACFD9BFD5835BD300F0973792EF46040C53F1432BCDFB5E1DDE3BC18A5F840B52E653444D5DF"
    ),
    OCBVector(
        nonce: "BBAA9988776655443322110D",
        associatedData: "000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F2021222324252627",
        plaintext: "000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F2021222324252627",
        ciphertext: "D5CA91748410C1751FF8A2F618255B68A0A12E093FF454606E59F9C1D0DDC54B65E8628E568BAD7AED07BA06A4A69483A7035490C5769E60"
    ),
    OCBVector(
        nonce: "BBAA9988776655443322110E",
        associatedData: "000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F2021222324252627",
        plaintext: "",
        ciphertext: "C5CD9D1850C141E358649994EE701B68"
    ),
    OCBVector(
        nonce: "BBAA9988776655443322110F",
        associatedData: "",
        plaintext: "000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F2021222324252627",
        ciphertext: "4412923493C57D5DE0D700F753CCE0D1D2D95060122E9F15A5DDBFC5787E50B5CC55EE507BCB084E479AD363AC366B95A98CA5F3000B1479"
    ),
]

private func hex(_ string: String) -> [UInt8] {
    var bytes: [UInt8] = []
    var index = string.startIndex

    while index < string.endIndex {
        let next = string.index(index, offsetBy: 2)
        bytes.append(UInt8(string[index..<next], radix: 16)!)
        index = next
    }

    return bytes
}
