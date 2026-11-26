// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title BLS12-381 helpers over the EIP-2537 precompiles
/// @notice Short signatures (signatures in G1, public keys in G2), RFC 9380 hash-to-curve for G1
/// (expand_message_xmd with SHA-256, SSWU, via MAP_FP_TO_G1), and G1 point compression.
/// Points use the EIP-2537 encoding: each Fp element is 64 bytes (16 zero bytes, then 48 bytes
/// big-endian); a G1 point is x || y (128 bytes); a G2 point is x.c0 || x.c1 || y.c0 || y.c1 (256).
library BLS12381 {
    address private constant G1ADD = address(0x0b);
    address private constant G2ADD = address(0x0d);
    address private constant PAIRING = address(0x0f);
    address private constant MAP_FP_TO_G1 = address(0x10);
    address private constant MODEXP = address(0x05);

    /// The field modulus p (48 bytes).
    bytes private constant P =
        hex"1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaab";
    /// (p - 1) / 2, split into its top 16 bytes and low 32 bytes, for the sign of y.
    uint128 private constant HALF_P_HI = 0x0d0088f51cbff34d258dd3db21a5d66b;
    uint256 private constant HALF_P_LO = 0xb23ba5c279c2895fb39869507b587b120f55ffff58a9ffffdcff7fffffffd555;
    /// -G2 generator (EIP-2537 encoding), for the pairing check e(sig, -g2) * e(H(m), pk) == 1.
    bytes private constant NEG_G2 = hex"00000000000000000000000000000000024aa2b2f08f0a91260805272dc51051c6e47ad4fa403b02b4510b647ae3d1770bac0326a805bbefd48056c8c121bdb80000000000000000000000000000000013e02b6052719f607dacd3a088274f65596bd0d09920b61ab5da61bbdc7f5049334cf11213945d57e5ac7d055d042b7e000000000000000000000000000000000d1b3cc2c7027888be51d9ef691d77bcb679afda66c73f17f9ee3837a55024f78c71363275a75d75d86bab79f74782aa0000000000000000000000000000000013fa4d4a0ad8b1ce186ed5061789213d993923066dddaf1040bc3ff59f825c78df74f2d75467e25e0f55f8a00fa030ed";

    error PrecompileFailed(address precompile);

    function _call(address precompile, bytes memory input, uint256 outLen) private view returns (bytes memory out) {
        out = new bytes(outLen);
        bool ok;
        assembly {
            ok := staticcall(gas(), precompile, add(input, 32), mload(input), add(out, 32), outLen)
        }
        if (!ok) revert PrecompileFailed(precompile);
    }

    function g1Add(bytes memory a, bytes memory b) internal view returns (bytes memory) {
        return _call(G1ADD, abi.encodePacked(a, b), 128);
    }

    function g2Add(bytes memory a, bytes memory b) internal view returns (bytes memory) {
        return _call(G2ADD, abi.encodePacked(a, b), 256);
    }

    /// A 64-byte big-endian number reduced mod p, as a 64-byte EIP-2537 field element.
    function _modP(bytes memory b64) private view returns (bytes memory) {
        bytes memory r = _call(MODEXP, abi.encodePacked(uint256(64), uint256(1), uint256(48), b64, uint8(1), P), 48);
        return abi.encodePacked(bytes16(0), r);
    }

    /// RFC 9380 expand_message_xmd with SHA-256, 128 bytes out.
    function expandMessageXmd(bytes memory message, bytes memory dst) internal pure returns (bytes memory) {
        bytes memory dstPrime = abi.encodePacked(dst, uint8(dst.length));
        bytes32 b0 = sha256(abi.encodePacked(new bytes(64), message, uint16(128), uint8(0), dstPrime));
        bytes32 b1 = sha256(abi.encodePacked(b0, uint8(1), dstPrime));
        bytes32 b2 = sha256(abi.encodePacked(b0 ^ b1, uint8(2), dstPrime));
        bytes32 b3 = sha256(abi.encodePacked(b0 ^ b2, uint8(3), dstPrime));
        bytes32 b4 = sha256(abi.encodePacked(b0 ^ b3, uint8(4), dstPrime));
        return abi.encodePacked(b1, b2, b3, b4);
    }

    function _slice(bytes memory b, uint256 start, uint256 len) private pure returns (bytes memory out) {
        require(start + len <= b.length, "slice out of range");
        out = new bytes(len);
        assembly {
            // MCOPY (Cancun+): one memory-to-memory copy instead of a byte loop.
            mcopy(add(out, 32), add(add(b, 32), start), len)
        }
    }

    /// RFC 9380 hash_to_curve for G1 (BLS12381G1_XMD:SHA-256_SSWU_RO_ with this DST).
    /// MAP_FP_TO_G1 clears the cofactor; that's linear, so adding the two mapped points equals
    /// clearing the cofactor of their sum.
    function hashToG1(bytes memory message, bytes memory dst) internal view returns (bytes memory) {
        bytes memory u = expandMessageXmd(message, dst);
        bytes memory q0 = _call(MAP_FP_TO_G1, _modP(_slice(u, 0, 64)), 128);
        bytes memory q1 = _call(MAP_FP_TO_G1, _modP(_slice(u, 64, 64)), 128);
        return g1Add(q0, q1);
    }

    /// e(sig, g2) == e(hm, pk). False (not a revert) for malformed or off-subgroup inputs.
    function verify(bytes memory sig, bytes memory hm, bytes memory pk) internal view returns (bool) {
        if (sig.length != 128 || hm.length != 128 || pk.length != 256) return false;
        bytes memory input = abi.encodePacked(sig, NEG_G2, hm, pk);
        bytes memory out = new bytes(32);
        bool ok;
        assembly {
            // 0x0f: BLS12_PAIRING_CHECK
            ok := staticcall(gas(), 0x0f, add(input, 32), mload(input), add(out, 32), 32)
        }
        return ok && uint8(out[31]) == 1;
    }

    /// The 48-byte compressed (ZCash) form of a G1 point, as drand publishes signatures.
    function compressG1(bytes memory pt) internal pure returns (bytes memory c) {
        c = _slice(pt, 16, 48); // x
        bytes memory y = _slice(pt, 80, 48);
        uint128 hi;
        uint256 lo;
        assembly {
            hi := shr(128, mload(add(y, 32)))
            lo := mload(add(y, 48))
        }
        bool larger = hi > HALF_P_HI || (hi == HALF_P_HI && lo > HALF_P_LO);
        c[0] = bytes1(uint8(c[0]) | 0x80 | (larger ? 0x20 : 0));
    }
}
