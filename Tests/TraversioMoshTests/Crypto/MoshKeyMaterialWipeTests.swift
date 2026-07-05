// Copyright (c) 2026 GitSwift LLC
//
// Licensed under the MIT License.
// See LICENSE for details.

import Testing
@testable import TraversioMoshCrypto

/// Proves the `ae_clear`-equivalent wipe chain: when the last copy of a
/// cipher (or the sequencer that owns it) is deallocated, the cipher's own
/// key-derived material (raw AES key plus the OCB L table) is zeroed.
struct MoshKeyMaterialWipeTests {
    /// Collects the deinit wipe verdict. The observer runs synchronously on
    /// the thread that drops the last reference — in these tests, the test
    /// thread — so a plain property is race-free here.
    private final class WipeVerdict: @unchecked Sendable {
        var zeroedOnDeinit: Bool?
    }

    @Test
    func cipherKeyMaterialIsZeroedWhenLastCopyIsDeallocated() throws {
        let verdict = WipeVerdict()

        do {
            let ocb = try MoshAES128OCB(rawKey: Array(UInt8(0)..<UInt8(16)))
            ocb._installKeyMaterialDeinitWipeHook { verdict.zeroedOnDeinit = $0 }
            // Exercise the cipher so the material has been used for real work.
            _ = try ocb.seal(
                plaintext: [0x01, 0x02, 0x03],
                nonce: [UInt8](repeating: 0xbb, count: 12)
            )
            #expect(verdict.zeroedOnDeinit == nil)
        }

        #expect(verdict.zeroedOnDeinit == true)
    }

    @Test
    func keyMaterialSurvivesUntilLastCipherCopyIsReleased() throws {
        let verdict = WipeVerdict()
        let nonce = [UInt8](repeating: 0xaa, count: 12)
        var keeper: MoshAES128OCB?

        do {
            let ocb = try MoshAES128OCB(rawKey: Array(UInt8(0)..<UInt8(16)))
            ocb._installKeyMaterialDeinitWipeHook { verdict.zeroedOnDeinit = $0 }
            keeper = ocb
        }

        // The copy still holds the shared material: not wiped, still usable.
        #expect(verdict.zeroedOnDeinit == nil)
        let sealed = try #require(try keeper?.seal(plaintext: [0x42], nonce: nonce))
        let reference = try MoshAES128OCB(rawKey: Array(UInt8(0)..<UInt8(16)))
        #expect(try reference.open(ciphertext: sealed, nonce: nonce) == [0x42])

        keeper = nil
        #expect(verdict.zeroedOnDeinit == true)
    }

    @Test
    func sequencerDeallocationZeroesCipherKeyMaterial() throws {
        let verdict = WipeVerdict()

        do {
            var sequencer = try MoshDatagramSequencer(
                rawKey: Array(UInt8(0)..<UInt8(16)),
                sendDirection: .toServer,
                receiveDirection: .toClient
            )
            sequencer._installKeyMaterialDeinitWipeHook { verdict.zeroedOnDeinit = $0 }
            _ = try sequencer.seal(plaintext: [0xab, 0xcd])
            #expect(verdict.zeroedOnDeinit == nil)
        }

        #expect(verdict.zeroedOnDeinit == true)
    }

    @Test
    func datagramCipherDeallocationZeroesKeyMaterial() throws {
        let verdict = WipeVerdict()

        do {
            let sessionKey = try MoshSessionKey(rawBytes: Array(UInt8(1)..<UInt8(17)))
            let cipher = try MoshDatagramCipher(sessionKey: sessionKey)
            cipher._installKeyMaterialDeinitWipeHook { verdict.zeroedOnDeinit = $0 }
            _ = try cipher.seal(plaintext: [0x11], sequence: 7, direction: .toClient)
        }

        #expect(verdict.zeroedOnDeinit == true)
    }
}
