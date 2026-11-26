// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PoseidonT3} from "poseidon-solidity/PoseidonT3.sol";
import {OrvynShieldedPool, IVerifier} from "../src/pay/OrvynShieldedPool.sol";
import {AgentIdGated, IAgentId} from "../src/pay/AgentIdGated.sol";
import {MockERC20, MockAgentId, MockVerifier} from "./Mocks.sol";

contract OrvynShieldedPoolTest is Test {
    OrvynShieldedPool pool;
    MockVerifier verifier;
    MockAgentId agentId;
    MockERC20 usdt;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address relayer = makeAddr("relayer");
    address outsider = makeAddr("outsider");

    uint32 constant LEVELS = 20;
    uint32 constant KEY_LEVELS = 16;
    uint256 constant FIELD = 21888242871839275222246405745257275088548364400416034343698204186575808495617;

    uint256 nextNullifier = 1;
    uint256 nextCommitment = 1_000;

    function setUp() public {
        verifier = new MockVerifier();
        agentId = new MockAgentId();
        usdt = new MockERC20("USDT");
        pool = new OrvynShieldedPool(
            IVerifier(address(verifier)), IAgentId(address(agentId)), LEVELS, KEY_LEVELS, owner
        );
        vm.startPrank(owner);
        pool.setAsset(address(usdt), true, 1_000e18);
        pool.setAsset(address(0), true, 0);
        vm.stopPrank();
        agentId.set(alice, true);
        agentId.set(bob, true);
        agentId.set(relayer, true);
        usdt.mint(alice, 10_000e18);
        vm.prank(alice);
        usdt.approve(address(pool), type(uint256).max);
        vm.deal(alice, 10 ether);
    }

    // ---------- helpers ----------

    function _ext(address recipient, int256 extAmount, address relayer_, uint256 fee)
        internal
        pure
        returns (OrvynShieldedPool.ExtData memory)
    {
        return OrvynShieldedPool.ExtData({
            recipient: recipient,
            extAmount: extAmount,
            relayer: relayer_,
            fee: fee,
            encryptedOutput1: hex"01",
            encryptedOutput2: hex"02"
        });
    }

    function _proof(OrvynShieldedPool.ExtData memory e, address token)
        internal
        returns (OrvynShieldedPool.Proof memory p)
    {
        p.root = pool.noteRoot();
        p.keyRoot = pool.keyRoot();
        p.publicAmount = pool.publicAmountOf(e.extAmount, e.fee);
        p.extDataHash = uint256(keccak256(abi.encode(e))) % FIELD;
        p.asset = uint256(uint160(token));
        p.inputNullifiers = [nextNullifier++, nextNullifier++];
        p.outputCommitments = [nextCommitment++, nextCommitment++];
    }

    function _depositUsdt(uint256 amount) internal returns (OrvynShieldedPool.Proof memory p) {
        OrvynShieldedPool.ExtData memory e = _ext(address(0), int256(amount), address(0), 0);
        p = _proof(e, address(usdt));
        vm.prank(alice);
        pool.transact(p, e);
    }

    // ---------- tree ----------

    function test_emptyRootMatchesTheCircuitConvention() public view {
        uint256 z;
        for (uint256 i; i < LEVELS; ++i) z = PoseidonT3.hash([z, z]);
        assertEq(pool.noteRoot(), z);
        assertTrue(pool.isKnownNoteRoot(z));
    }

    function test_insertedPairGivesTheExpectedRoot() public {
        OrvynShieldedPool.Proof memory p = _depositUsdt(5e18);
        uint256 node = PoseidonT3.hash([p.outputCommitments[0], p.outputCommitments[1]]);
        uint256 z = PoseidonT3.hash([uint256(0), uint256(0)]); // zeros[1]
        for (uint256 level = 1; level < LEVELS; ++level) {
            node = PoseidonT3.hash([node, z]);
            z = PoseidonT3.hash([z, z]);
        }
        assertEq(pool.noteRoot(), node);
        assertEq(pool.nextNoteIndex(), 2);
    }

    // ---------- keys ----------

    function test_registeringAKeyNeedsAnAgentId() public {
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(AgentIdGated.NoAgentId.selector, outsider));
        pool.registerKey(123, hex"aa");

        uint256 before = pool.keyRoot();
        vm.prank(alice);
        pool.registerKey(123, hex"aa");
        assertEq(pool.shieldedKeyOf(alice), 123);
        assertTrue(pool.keyRegistered(123));
        assertTrue(pool.keyRoot() != before);
        assertTrue(pool.isKnownKeyRoot(before)); // recent roots stay valid for in-flight proofs
    }

    function test_oneKeyPerWalletAndNoDuplicates() public {
        vm.prank(alice);
        pool.registerKey(123, "");
        vm.prank(alice);
        vm.expectRevert(OrvynShieldedPool.KeyExists.selector);
        pool.registerKey(456, "");
        vm.prank(bob);
        vm.expectRevert(OrvynShieldedPool.KeyExists.selector);
        pool.registerKey(123, "");
        vm.prank(bob);
        vm.expectRevert(OrvynShieldedPool.BadKey.selector);
        pool.registerKey(FIELD, "");
    }

    // ---------- deposits ----------

    function test_depositPullsTokensAndAddsNotes() public {
        OrvynShieldedPool.Proof memory p = _depositUsdt(100e18);
        assertEq(usdt.balanceOf(address(pool)), 100e18);
        assertTrue(pool.nullifierSpent(p.inputNullifiers[0]));
        assertTrue(pool.nullifierSpent(p.inputNullifiers[1]));
    }

    function test_depositNeedsAnAgentId() public {
        usdt.mint(outsider, 10e18);
        vm.prank(outsider);
        usdt.approve(address(pool), type(uint256).max);
        OrvynShieldedPool.ExtData memory e = _ext(address(0), 1e18, address(0), 0);
        OrvynShieldedPool.Proof memory p = _proof(e, address(usdt));
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(AgentIdGated.NoAgentId.selector, outsider));
        pool.transact(p, e);
    }

    function test_bnbDepositNeedsTheExactValue() public {
        OrvynShieldedPool.ExtData memory e = _ext(address(0), 1 ether, address(0), 0);
        OrvynShieldedPool.Proof memory p = _proof(e, address(0));
        vm.prank(alice);
        vm.expectRevert(OrvynShieldedPool.BadValue.selector);
        pool.transact{value: 0.5 ether}(p, e);
        vm.prank(alice);
        pool.transact{value: 1 ether}(p, e);
        assertEq(address(pool).balance, 1 ether);
    }

    function test_depositLimitsAndPause() public {
        OrvynShieldedPool.ExtData memory e = _ext(address(0), 1_001e18, address(0), 0);
        OrvynShieldedPool.Proof memory p = _proof(e, address(usdt));
        vm.prank(alice);
        vm.expectRevert(OrvynShieldedPool.DepositLimit.selector);
        pool.transact(p, e);

        vm.prank(owner);
        pool.setDepositsPaused(true);
        e = _ext(address(0), 1e18, address(0), 0);
        p = _proof(e, address(usdt));
        vm.prank(alice);
        vm.expectRevert(OrvynShieldedPool.Paused.selector);
        pool.transact(p, e);
    }

    function test_unlistedAssetCantBeDeposited() public {
        MockERC20 scam = new MockERC20("SCAM");
        OrvynShieldedPool.ExtData memory e = _ext(address(0), 1e18, address(0), 0);
        OrvynShieldedPool.Proof memory p = _proof(e, address(scam));
        vm.prank(alice);
        vm.expectRevert(OrvynShieldedPool.AssetNotAccepted.selector);
        pool.transact(p, e);
    }

    // ---------- withdrawals ----------

    function test_withdrawalToAVerifiedAgentWithARelayerFee() public {
        _depositUsdt(100e18);
        OrvynShieldedPool.ExtData memory e = _ext(bob, -40e18, relayer, 1e18);
        OrvynShieldedPool.Proof memory p = _proof(e, address(usdt));
        assertEq(p.publicAmount, FIELD - 41e18);
        vm.prank(relayer);
        pool.transact(p, e);
        assertEq(usdt.balanceOf(bob), 40e18);
        assertEq(usdt.balanceOf(relayer), 1e18);
        assertEq(usdt.balanceOf(address(pool)), 59e18);
    }

    function test_withdrawalRecipientNeedsAnAgentId() public {
        _depositUsdt(100e18);
        OrvynShieldedPool.ExtData memory e = _ext(outsider, -10e18, address(0), 0);
        OrvynShieldedPool.Proof memory p = _proof(e, address(usdt));
        vm.expectRevert(abi.encodeWithSelector(AgentIdGated.NoAgentId.selector, outsider));
        pool.transact(p, e);
    }

    function test_relayerNeedsAnAgentId() public {
        _depositUsdt(100e18);
        OrvynShieldedPool.ExtData memory e = _ext(bob, -10e18, outsider, 1e18);
        OrvynShieldedPool.Proof memory p = _proof(e, address(usdt));
        vm.expectRevert(abi.encodeWithSelector(AgentIdGated.NoAgentId.selector, outsider));
        pool.transact(p, e);
    }

    function test_withdrawalsWorkWhilePausedAndAfterDelisting() public {
        _depositUsdt(100e18);
        vm.startPrank(owner);
        pool.setDepositsPaused(true);
        pool.setAsset(address(usdt), false, 0);
        vm.stopPrank();
        OrvynShieldedPool.ExtData memory e = _ext(bob, -100e18, address(0), 0);
        OrvynShieldedPool.Proof memory p = _proof(e, address(usdt));
        pool.transact(p, e);
        assertEq(usdt.balanceOf(bob), 100e18);
    }

    // ---------- proof binding ----------

    function test_spentNullifiersAreRefused() public {
        OrvynShieldedPool.Proof memory p = _depositUsdt(1e18);
        OrvynShieldedPool.ExtData memory e = _ext(address(0), 1e18, address(0), 0);
        OrvynShieldedPool.Proof memory q = _proof(e, address(usdt));
        q.inputNullifiers[0] = p.inputNullifiers[0];
        vm.prank(alice);
        vm.expectRevert(OrvynShieldedPool.NullifierSpent.selector);
        pool.transact(q, e);
    }

    function test_duplicateNullifiersInOneTransaction() public {
        OrvynShieldedPool.ExtData memory e = _ext(address(0), 1e18, address(0), 0);
        OrvynShieldedPool.Proof memory p = _proof(e, address(usdt));
        p.inputNullifiers[1] = p.inputNullifiers[0];
        vm.prank(alice);
        vm.expectRevert(OrvynShieldedPool.DuplicateNullifier.selector);
        pool.transact(p, e);
    }

    function test_extDataIsBoundToTheProof() public {
        _depositUsdt(100e18);
        OrvynShieldedPool.ExtData memory e = _ext(bob, -10e18, address(0), 0);
        OrvynShieldedPool.Proof memory p = _proof(e, address(usdt));
        e.recipient = alice; // a front-runner swapping the recipient
        vm.expectRevert(OrvynShieldedPool.BadExtData.selector);
        pool.transact(p, e);
    }

    function test_publicAmountMustMatch() public {
        OrvynShieldedPool.ExtData memory e = _ext(address(0), 1e18, address(0), 0);
        OrvynShieldedPool.Proof memory p = _proof(e, address(usdt));
        p.publicAmount = 2e18;
        vm.prank(alice);
        vm.expectRevert(OrvynShieldedPool.BadPublicAmount.selector);
        pool.transact(p, e);
    }

    function test_unknownRootsAreRefused() public {
        OrvynShieldedPool.ExtData memory e = _ext(address(0), 1e18, address(0), 0);
        OrvynShieldedPool.Proof memory p = _proof(e, address(usdt));
        p.root = 42;
        vm.prank(alice);
        vm.expectRevert(OrvynShieldedPool.UnknownRoot.selector);
        pool.transact(p, e);
        p.root = pool.noteRoot();
        p.keyRoot = 42;
        vm.prank(alice);
        vm.expectRevert(OrvynShieldedPool.UnknownKeyRoot.selector);
        pool.transact(p, e);
    }

    function test_invalidProofsAreRefused() public {
        verifier.set(false);
        OrvynShieldedPool.ExtData memory e = _ext(address(0), 1e18, address(0), 0);
        OrvynShieldedPool.Proof memory p = _proof(e, address(usdt));
        vm.prank(alice);
        vm.expectRevert(OrvynShieldedPool.BadProof.selector);
        pool.transact(p, e);
    }

    function test_assetMustBeAnAddress() public {
        OrvynShieldedPool.ExtData memory e = _ext(address(0), 1e18, address(0), 0);
        OrvynShieldedPool.Proof memory p = _proof(e, address(usdt));
        p.asset = uint256(1) << 160;
        vm.prank(alice);
        vm.expectRevert(OrvynShieldedPool.BadAsset.selector);
        pool.transact(p, e);
    }

    function test_shieldedTransferMovesNoFunds() public {
        _depositUsdt(100e18);
        OrvynShieldedPool.ExtData memory e = _ext(address(0), 0, address(0), 0);
        OrvynShieldedPool.Proof memory p = _proof(e, address(usdt));
        vm.prank(outsider); // anyone may submit a pure shielded transfer; the circuit gates the receiver
        pool.transact(p, e);
        assertEq(usdt.balanceOf(address(pool)), 100e18);
        assertEq(pool.nextNoteIndex(), 4);
    }
}
