// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoseidonT3} from "poseidon-solidity/PoseidonT3.sol";

/// @notice Incremental Poseidon Merkle tree with a ring buffer of recent roots, as the
/// OrvynPay circuit expects: empty leaves are 0, zeros[i+1] = Poseidon(zeros[i], zeros[i]),
/// and a node is Poseidon(left, right).
library PoseidonTree {
    uint256 internal constant FIELD_SIZE =
        21888242871839275222246405745257275088548364400416034343698204186575808495617;

    struct Tree {
        uint32 levels;
        uint32 historySize;
        uint32 nextIndex;
        uint32 currentRootIndex;
        mapping(uint256 level => uint256) zeros;
        mapping(uint256 level => uint256) filledSubtrees;
        mapping(uint256 index => uint256) roots;
    }

    error TreeFull();
    error NotInField();
    error OddIndex();

    function init(Tree storage t, uint32 levels, uint32 historySize) internal {
        require(levels > 0 && levels <= 32 && historySize > 0, "bad tree params");
        t.levels = levels;
        t.historySize = historySize;
        uint256 z = 0;
        for (uint32 i; i < levels; ++i) {
            t.zeros[i] = z;
            t.filledSubtrees[i] = z;
            z = hash(z, z);
        }
        t.zeros[levels] = z;
        t.roots[0] = z;
    }

    function hash(uint256 left, uint256 right) internal pure returns (uint256) {
        if (left >= FIELD_SIZE || right >= FIELD_SIZE) revert NotInField();
        return PoseidonT3.hash([left, right]);
    }

    /// Inserts one leaf; returns its index.
    function insert(Tree storage t, uint256 leaf) internal returns (uint32 index) {
        index = t.nextIndex;
        if (uint256(index) >= (uint256(1) << t.levels)) revert TreeFull();
        uint256 node = leaf;
        uint32 i = index;
        for (uint32 level; level < t.levels; ++level) {
            if (i % 2 == 0) {
                t.filledSubtrees[level] = node;
                node = hash(node, t.zeros[level]);
            } else {
                node = hash(t.filledSubtrees[level], node);
            }
            i /= 2;
        }
        _pushRoot(t, node);
        t.nextIndex = index + 1;
    }

    /// Inserts two sibling leaves (one hash cheaper than two inserts); returns the first index.
    function insertPair(Tree storage t, uint256 left, uint256 right) internal returns (uint32 index) {
        index = t.nextIndex;
        if (index % 2 != 0) revert OddIndex();
        if (uint256(index) + 2 > (uint256(1) << t.levels)) revert TreeFull();
        // Level 0 is never read back from filledSubtrees for pairs, but keep it consistent.
        t.filledSubtrees[0] = left;
        uint256 node = hash(left, right);
        uint32 i = index / 2;
        for (uint32 level = 1; level < t.levels; ++level) {
            if (i % 2 == 0) {
                t.filledSubtrees[level] = node;
                node = hash(node, t.zeros[level]);
            } else {
                node = hash(t.filledSubtrees[level], node);
            }
            i /= 2;
        }
        _pushRoot(t, node);
        t.nextIndex = index + 2;
    }

    function isKnownRoot(Tree storage t, uint256 root) internal view returns (bool) {
        if (root == 0) return false;
        uint32 n = t.historySize;
        uint32 i = t.currentRootIndex;
        for (uint32 k; k < n; ++k) {
            if (t.roots[i] == root) return true;
            i = i == 0 ? n - 1 : i - 1;
        }
        return false;
    }

    function lastRoot(Tree storage t) internal view returns (uint256) {
        return t.roots[t.currentRootIndex];
    }

    function _pushRoot(Tree storage t, uint256 root) private {
        uint32 next = (t.currentRootIndex + 1) % t.historySize;
        t.currentRootIndex = next;
        t.roots[next] = root;
    }
}
