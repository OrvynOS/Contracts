// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Agent, client and job ids: 1-64 characters of [A-Za-z0-9_-], stored by their keccak256.
library OrvynIds {
    error InvalidId();

    function check(string calldata id) internal pure returns (bytes32) {
        bytes calldata b = bytes(id);
        if (b.length == 0 || b.length > 64) revert InvalidId();
        for (uint256 i; i < b.length; ++i) {
            bytes1 c = b[i];
            bool ok = (c >= "0" && c <= "9") || (c >= "A" && c <= "Z") || (c >= "a" && c <= "z") || c == "-" || c == "_";
            if (!ok) revert InvalidId();
        }
        return keccak256(b);
    }

    function key(string calldata id) internal pure returns (bytes32) {
        return keccak256(bytes(id));
    }
}
