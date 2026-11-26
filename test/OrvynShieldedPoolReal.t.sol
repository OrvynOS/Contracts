// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {OrvynShieldedPool, IVerifier} from "../src/pay/OrvynShieldedPool.sol";
import {IAgentId} from "../src/pay/AgentIdGated.sol";
import {MockAgentId} from "./Mocks.sol";
import {Groth16VerifierDev} from "./fixtures/Groth16VerifierDev.sol";

/// The shielded pool with the REAL Groth16 verifier and a REAL proof made by Orvyn's SDK
/// (`orvyn-admin fixture orvynpay`): a 1 BNB deposit into a note of a freshly
/// registered key. Checks that the SDK's Merkle trees match PoseidonTree.sol, that its
/// extDataHash matches abi.encode, and that the verifier accepts its proof.
contract OrvynShieldedPoolRealTest is Test {
    OrvynShieldedPool pool;
    MockAgentId agentIds;
    string json;
    address alice;

    function setUp() public {
        json = vm.readFile("test/fixtures/deposit.json");
        alice = vm.parseJsonAddress(json, ".account");
        assertEq(alice, makeAddr("alice"), "fixture account is makeAddr(alice)");
        agentIds = new MockAgentId();
        agentIds.set(alice, true);
        pool = new OrvynShieldedPool(IVerifier(address(new Groth16VerifierDev())), IAgentId(address(agentIds)), 20, 16, address(this));
        pool.setAsset(address(0), true, 0);
        vm.deal(alice, 10 ether);
    }

    function _proof() internal view returns (OrvynShieldedPool.Proof memory p) {
        uint256[] memory a = vm.parseJsonUintArray(json, ".proof.a");
        uint256[] memory b0 = vm.parseJsonUintArray(json, ".proof.b[0]");
        uint256[] memory b1 = vm.parseJsonUintArray(json, ".proof.b[1]");
        uint256[] memory c = vm.parseJsonUintArray(json, ".proof.c");
        uint256[] memory nul = vm.parseJsonUintArray(json, ".proof.inputNullifiers");
        uint256[] memory out = vm.parseJsonUintArray(json, ".proof.outputCommitments");
        p.a = [a[0], a[1]];
        p.b = [[b0[0], b0[1]], [b1[0], b1[1]]];
        p.c = [c[0], c[1]];
        p.root = vm.parseJsonUint(json, ".proof.root");
        p.keyRoot = vm.parseJsonUint(json, ".proof.keyRoot");
        p.publicAmount = vm.parseJsonUint(json, ".proof.publicAmount");
        p.extDataHash = vm.parseJsonUint(json, ".proof.extDataHash");
        p.asset = vm.parseJsonUint(json, ".proof.asset");
        p.inputNullifiers = [nul[0], nul[1]];
        p.outputCommitments = [out[0], out[1]];
    }

    function _ext() internal view returns (OrvynShieldedPool.ExtData memory e) {
        e.recipient = vm.parseJsonAddress(json, ".ext.recipient");
        e.extAmount = vm.parseJsonInt(json, ".ext.extAmount");
        e.relayer = vm.parseJsonAddress(json, ".ext.relayer");
        e.fee = vm.parseJsonUint(json, ".ext.fee");
        e.encryptedOutput1 = vm.parseJsonBytes(json, ".ext.encryptedOutput1");
        e.encryptedOutput2 = vm.parseJsonBytes(json, ".ext.encryptedOutput2");
    }

    function _register() internal {
        vm.prank(alice);
        pool.registerKey(vm.parseJsonUint(json, ".shieldedKey"), vm.parseJsonBytes(json, ".encryptionKey"));
    }

    function test_sdkEmptyRootMatchesTheContract() public view {
        assertEq(pool.noteRoot(), vm.parseJsonUint(json, ".emptyNoteRoot"), "empty note tree root");
    }

    function test_sdkKeyTreeMatchesTheContract() public {
        _register();
        assertEq(pool.keyRoot(), vm.parseJsonUint(json, ".keyRoot"), "key tree root after one key");
    }

    function test_sdkExtDataHashMatchesAbiEncode() public view {
        OrvynShieldedPool.ExtData memory e = _ext();
        assertEq(uint256(keccak256(abi.encode(e))) % pool.FIELD_SIZE(), _proof().extDataHash);
    }

    function test_realProofDepositsAndUpdatesTheTree() public {
        _register();
        OrvynShieldedPool.Proof memory p = _proof();
        OrvynShieldedPool.ExtData memory e = _ext();
        uint256 value = vm.parseJsonUint(json, ".value");
        vm.prank(alice);
        pool.transact{value: value}(p, e);
        assertEq(address(pool).balance, value, "the pool holds the deposit");
        assertEq(pool.noteRoot(), vm.parseJsonUint(json, ".noteRootAfter"), "note tree root after the deposit");
        assertTrue(pool.nullifierSpent(p.inputNullifiers[0]) && pool.nullifierSpent(p.inputNullifiers[1]));
    }

    function test_replayingTheProofIsRefused() public {
        _register();
        OrvynShieldedPool.Proof memory p = _proof();
        OrvynShieldedPool.ExtData memory e = _ext();
        uint256 value = vm.parseJsonUint(json, ".value");
        vm.startPrank(alice);
        pool.transact{value: value}(p, e);
        vm.expectRevert();
        pool.transact{value: value}(p, e);
        vm.stopPrank();
    }

    function test_aTamperedProofIsRefusedByTheVerifier() public {
        _register();
        OrvynShieldedPool.Proof memory p = _proof();
        p.a[0] = p.a[0] ^ 1;
        OrvynShieldedPool.ExtData memory e = _ext();
        uint256 value = vm.parseJsonUint(json, ".value");
        vm.prank(alice);
        vm.expectRevert();
        pool.transact{value: value}(p, e);
    }
}
