// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {OrvynRNG} from "../src/rng/OrvynRNG.sol";
import {BLS12381} from "../src/rng/BLS12381.sol";
import {DiceRoller} from "../src/rng/examples/DiceRoller.sol";

/// Exposes the library for a direct test against the reference implementation (noble-curves).
contract BLSHarness {
    function hashToG1(bytes memory m, bytes memory dst) external view returns (bytes memory) {
        return BLS12381.hashToG1(m, dst);
    }

    function compress(bytes memory p) external pure returns (bytes memory) {
        return BLS12381.compressG1(p);
    }
}

/// Runs against a real round: three node keys and the live drand quicknet signature for the
/// round's drand round (test/fixtures/rng.json, made by `orvyn-admin fixture rng`).
contract OrvynRNGTest is Test {
    using stdJson for string;

    OrvynRNG rng;
    DiceRoller dice;
    string fx;
    uint64 round;
    address owner = makeAddr("owner");
    address committer = makeAddr("committer");
    address treasury = makeAddr("treasury");
    address dev = makeAddr("dev");
    address fulfiller = makeAddr("fulfiller");
    uint256 constant BASE_FEE = 0.001 ether;
    uint256 constant PER_GAS = 1 gwei;
    uint256 subId;

    function setUp() public {
        vm.deal(address(this), 10 ether);
        fx = vm.readFile("test/fixtures/rng.json");
        round = uint64(fx.readUint(".round"));
        // 70% to the round's nodes, 20% to the fulfiller, 10% to the treasury.
        rng = new OrvynRNG(owner, committer, treasury, 1, BASE_FEE, PER_GAS, 7000, 2000);
        vm.deal(dev, 10 ether);
        vm.startPrank(dev);
        subId = rng.createSubscription();
        rng.fund{value: 1 ether}(subId);
        dice = new DiceRoller(address(rng), subId);
        rng.setConsumer(subId, address(dice), true);
        vm.stopPrank();
    }

    function node(uint256 i) internal view returns (bytes memory pk, address payee, bytes memory proof) {
        string memory p = string.concat(".nodes[", vm.toString(i), "]");
        pk = fx.readBytes(string.concat(p, ".publicKey"));
        payee = fx.readAddress(string.concat(p, ".payee"));
        proof = fx.readBytes(string.concat(p, ".proof"));
    }

    function registerAll() internal {
        for (uint256 i; i < 3; ++i) {
            (bytes memory pk, address payee, bytes memory proof) = node(i);
            rng.register{value: 0.1 ether}(pk, payee, proof);
        }
    }

    function indices() internal pure returns (uint32[] memory ix) {
        ix = new uint32[](3);
        (ix[0], ix[1], ix[2]) = (0, 1, 2);
    }

    function keys() internal view returns (bytes memory all) {
        for (uint256 i; i < 3; ++i) {
            (bytes memory pk,,) = node(i);
            all = bytes.concat(all, pk);
        }
    }

    /// A roll requested during the minute before the fixture's round, then committed and fulfilled.
    function rollAndCommit() internal returns (uint256 requestId) {
        registerAll();
        vm.warp(uint256(round - 1) * 60 + 30);
        requestId = dice.roll();
        vm.warp(rng.roundClose(round) + 5);
        bytes memory agg = fx.readBytes(".aggregateSignature");
        bytes32 c = rng.commitmentFor(round, indices(), agg);
        vm.prank(committer);
        rng.commit(round, c);
        vm.warp(fx.readUint(".drandTime") + 1);
    }

    function fulfill() internal returns (bytes32) {
        vm.prank(fulfiller);
        return rng.fulfill(round, indices(), keys(), fx.readBytes(".aggregateSignature"), fx.readBytes(".drandSignature"));
    }

    // ---------- The library against the reference implementation ----------

    function test_hashToCurveMatchesReference() public {
        BLSHarness h = new BLSHarness();
        bytes memory got = h.hashToG1(fx.readBytes(".hashToCurve.message"), bytes(fx.readString(".hashToCurve.dst")));
        assertEq(got, fx.readBytes(".hashToCurve.expected"));
    }

    function test_compressionMatchesDrand() public {
        BLSHarness h = new BLSHarness();
        assertEq(sha256(h.compress(fx.readBytes(".drandSignature"))), fx.readBytes32(".drandRandomness"));
        assertEq(h.compress(fx.readBytes(".aggregateSignature")), fx.readBytes(".aggregateCompressed"));
    }

    function test_timingMatchesOffChain() public view {
        assertEq(rng.roundClose(round), fx.readUint(".roundClose"));
        assertEq(rng.drandRoundFor(round), fx.readUint(".drandRound"));
        assertEq(rng.drandTime(rng.drandRoundFor(round)), fx.readUint(".drandTime"));
    }

    // ---------- Nodes ----------

    function test_registerNodes() public {
        registerAll();
        assertEq(rng.nodeCount(), 3);
        (, address payee,,,,,) = rng.nodes(1);
        assertEq(payee, address(0xa2));
    }

    function test_registrationRejects() public {
        (bytes memory pk, address payee, bytes memory proof) = node(0);
        (, , bytes memory otherProof) = node(1);
        vm.expectRevert(OrvynRNG.BadProof.selector);
        rng.register{value: 0.1 ether}(pk, payee, otherProof);
        // A copied registration can't redirect earnings: the proof binds the payee.
        vm.expectRevert(OrvynRNG.BadProof.selector);
        rng.register{value: 0.1 ether}(pk, makeAddr("thief"), proof);
        vm.expectRevert(OrvynRNG.StakeTooLow.selector);
        rng.register{value: 0.05 ether}(pk, payee, proof);
        rng.register{value: 0.1 ether}(pk, payee, proof);
        vm.expectRevert(OrvynRNG.AlreadyRegistered.selector);
        rng.register{value: 0.1 ether}(pk, payee, proof);
    }

    function test_setPayeeNeedsTheNodeKey() public {
        registerAll();
        (bytes memory pk,,) = node(0);
        address newPayee = fx.readAddress(".newPayee");
        bytes memory proof = fx.readBytes(".payeeProof");
        vm.expectRevert(OrvynRNG.BadProof.selector);
        rng.setPayee(0, pk, makeAddr("thief"), proof);
        rng.setPayee(0, pk, newPayee, proof);
        (, address payee,,,,,) = rng.nodes(0);
        assertEq(payee, newPayee);
        // The nonce moved on: the same proof can't be replayed.
        vm.expectRevert(OrvynRNG.BadProof.selector);
        rng.setPayee(0, pk, newPayee, proof);
    }

    // ---------- The full path: request, commit, fulfil, deliver, earn ----------

    function test_rollIsFulfilledWithTheVerifiedOutput() public {
        uint256 requestId = rollAndCommit();
        uint256 gasBefore = gasleft();
        bytes32 out = fulfill();
        emit log_named_uint("fulfill gas (3 nodes, 1 callback)", gasBefore - gasleft());
        assertEq(out, fx.readBytes32(".output"), "the output matches the off-chain protocol");
        assertEq(rng.randomness(round), out);
        bytes32 value = rng.randomnessFor(requestId);
        assertEq(value, keccak256(abi.encode(out, requestId)));
        uint8 landed = dice.lastRoll(address(this));
        assertEq(landed, uint8(uint256(value) % 6) + 1);
    }

    function test_feesArePaidToTheRoundsAgents() public {
        rollAndCommit();
        uint256 fee = rng.feeFor(60_000);
        (, uint256 balance,) = rng.subscriptions(subId);
        assertEq(balance, 1 ether - fee, "the request was charged to the subscription");
        fulfill();
        uint256 each = (BASE_FEE * 7000) / 10_000 / 3;
        assertEq(rng.earnings(address(0xa1)), each);
        assertEq(rng.earnings(address(0xa2)), each);
        assertEq(rng.earnings(address(0xa3)), each);
        // The fulfiller delivered the callback too, so it earns its share plus the callback fee.
        assertEq(rng.earnings(fulfiller), (BASE_FEE * 2000) / 10_000 + 60_000 * PER_GAS);
        assertEq(rng.earnings(treasury), BASE_FEE - each * 3 - (BASE_FEE * 2000) / 10_000);
        (,,, uint64 signed,,,) = rng.nodes(0);
        assertEq(signed, 1);
        rng.withdrawFor(address(0xa1));
        assertEq(address(0xa1).balance, each);
        vm.expectRevert(OrvynRNG.NothingToWithdraw.selector);
        rng.withdrawFor(address(0xa1));
    }

    // ---------- What can't happen ----------

    function test_fulfilRejectsTampering() public {
        rollAndCommit();
        bytes memory agg = fx.readBytes(".aggregateSignature");
        bytes memory drand = fx.readBytes(".drandSignature");
        // A different participant set than committed.
        uint32[] memory two = new uint32[](2);
        (two[0], two[1]) = (0, 1);
        vm.expectRevert(OrvynRNG.CommitmentMismatch.selector);
        rng.fulfill(round, two, keys(), agg, drand);
        // A forged drand signature (the aggregate in its place).
        vm.expectRevert(OrvynRNG.BadDrandSignature.selector);
        rng.fulfill(round, indices(), keys(), agg, agg);
        // Keys that don't match the registered nodes.
        bytes memory k = keys();
        k[100] = bytes1(uint8(k[100]) ^ 1);
        vm.expectRevert(OrvynRNG.UnknownNode.selector);
        rng.fulfill(round, indices(), k, agg, drand);
        fulfill();
        vm.expectRevert(OrvynRNG.AlreadyFulfilled.selector);
        fulfill();
    }

    function test_aWrongAggregateIsRejectedEvenIfCommitted() public {
        registerAll();
        vm.warp(rng.roundClose(round) + 5);
        bytes memory bad = fx.readBytes(".drandSignature"); // a valid G1 point, but not the agents' signature
        bytes32 c = rng.commitmentFor(round, indices(), bad);
        vm.prank(committer);
        rng.commit(round, c);
        vm.warp(fx.readUint(".drandTime") + 1);
        vm.expectRevert(OrvynRNG.BadAggregateSignature.selector);
        rng.fulfill(round, indices(), keys(), bad, fx.readBytes(".drandSignature"));
    }

    function test_commitOnlyByTheCommitterInsideTheWindow() public {
        registerAll();
        bytes32 c = rng.commitmentFor(round, indices(), fx.readBytes(".aggregateSignature"));
        vm.warp(rng.roundClose(round) - 1);
        vm.prank(committer);
        vm.expectRevert(OrvynRNG.CommitOutsideWindow.selector);
        rng.commit(round, c);
        vm.warp(rng.roundClose(round) + 1);
        vm.expectRevert(OrvynRNG.NotCommitter.selector);
        rng.commit(round, c);
        // Once drand's round is out, it's too late: the value would be known.
        vm.warp(rng.drandTime(rng.drandRoundFor(round)));
        vm.prank(committer);
        vm.expectRevert(OrvynRNG.CommitOutsideWindow.selector);
        rng.commit(round, c);
    }

    function test_cantFulfilBeforeDrand() public {
        rollAndCommit();
        vm.warp(rng.drandTime(rng.drandRoundFor(round)) - 1);
        vm.expectRevert(OrvynRNG.DrandNotYetPublished.selector);
        fulfill();
    }

    // ---------- Subscriptions ----------

    function test_onlyListedConsumersCanRequest() public {
        vm.expectRevert(OrvynRNG.NotConsumer.selector);
        rng.requestRandomness(subId, 50_000);
        vm.prank(dev);
        rng.setConsumer(subId, address(dice), false);
        vm.expectRevert(OrvynRNG.NotConsumer.selector);
        dice.roll();
    }

    function test_anEmptySubscriptionCantRequest() public {
        vm.prank(dev);
        rng.withdrawSubscription(subId, type(uint256).max, dev);
        vm.expectRevert(OrvynRNG.InsufficientBalance.selector);
        dice.roll();
    }

    function test_onlyTheOwnerWithdrawsASubscription() public {
        vm.prank(makeAddr("mallory"));
        vm.expectRevert(OrvynRNG.NotSubscriptionOwner.selector);
        rng.withdrawSubscription(subId, 1, makeAddr("mallory"));
        uint256 before = dev.balance;
        vm.prank(dev);
        rng.withdrawSubscription(subId, 0.4 ether, dev);
        assertEq(dev.balance, before + 0.4 ether);
    }

    function test_unfulfilledRequestsAreRefunded() public {
        vm.warp(uint256(round - 1) * 60 + 30);
        uint256 id = dice.roll();
        uint256 fee = rng.feeFor(60_000);
        vm.expectRevert(OrvynRNG.NotRefundable.selector);
        rng.refund(id);
        vm.warp(rng.roundClose(round) + rng.REFUND_DELAY());
        rng.refund(id);
        (, uint256 balance,) = rng.subscriptions(subId);
        assertEq(balance, 1 ether, "the whole fee went back");
        assertEq(rng.roundEscrow(round), 0);
        vm.expectRevert(OrvynRNG.NotRefundable.selector);
        rng.refund(id);
        assertEq(fee, BASE_FEE + 60_000 * PER_GAS);
    }

    function test_theOwnerCantTakeSubscriptionsOrEarnings() public {
        rollAndCommit();
        fulfill();
        // The owner has no function that moves a subscription's balance or a node's earnings.
        vm.startPrank(owner);
        vm.expectRevert(OrvynRNG.NotSubscriptionOwner.selector);
        rng.withdrawSubscription(subId, 1, owner);
        vm.expectRevert(OrvynRNG.NothingToWithdraw.selector);
        rng.withdraw();
        vm.stopPrank();
    }

    // ---------- Staking and slashing ----------

    function test_aNodeThatSignsAheadIsSlashed() public {
        registerAll();
        (bytes memory pk,,) = node(0);
        uint64 early = uint64(fx.readUint(".earlyRound"));
        bytes memory sig = fx.readBytes(".earlySignature");
        vm.warp(uint256(round) * 60);
        address reporter = makeAddr("reporter");
        // A signature for a round that has already started proves nothing.
        vm.warp(uint256(early) * 60);
        vm.expectRevert(OrvynRNG.NotEarly.selector);
        rng.reportEarlySignature(0, pk, early, sig);
        vm.warp(uint256(early) * 60 - 1);
        // Someone else's key, or a signature for another round, isn't proof either.
        (bytes memory pk1,,) = node(1);
        vm.expectRevert(OrvynRNG.BadProof.selector);
        rng.reportEarlySignature(1, pk1, early, sig);
        vm.expectRevert(OrvynRNG.BadProof.selector);
        rng.reportEarlySignature(0, pk, early + 1, sig);
        vm.prank(reporter);
        rng.reportEarlySignature(0, pk, early, sig);
        (,,,, uint128 stake,, bool slashed) = rng.nodes(0);
        assertTrue(slashed);
        assertEq(stake, 0);
        assertEq(rng.earnings(reporter), 0.05 ether, "half the stake to the reporter");
        assertEq(rng.earnings(treasury), 0.05 ether, "half to the treasury");
        vm.expectRevert(OrvynRNG.NodeNotActive.selector);
        rng.reportEarlySignature(0, pk, early, sig);
    }

    function test_aSlashedNodeNoLongerCounts() public {
        registerAll();
        (bytes memory pk,,) = node(0);
        vm.warp(uint256(round) * 60 - 100);
        rng.reportEarlySignature(0, pk, uint64(fx.readUint(".earlyRound")), fx.readBytes(".earlySignature"));
        vm.warp(rng.roundClose(round) + 5);
        bytes32 c = rng.commitmentFor(round, indices(), fx.readBytes(".aggregateSignature"));
        vm.prank(committer);
        rng.commit(round, c);
        vm.warp(fx.readUint(".drandTime") + 1);
        vm.expectRevert(OrvynRNG.NodeNotActive.selector);
        fulfill();
    }

    function test_exitUnbondsThenReturnsTheStakeToThePayee() public {
        registerAll();
        vm.expectRevert(OrvynRNG.NotPayee.selector);
        rng.exit(1);
        vm.prank(address(0xa2));
        rng.exit(1);
        assertFalse(rng.eligible(1, rng.roundOf(block.timestamp) + 1), "it stops counting in new rounds");
        vm.prank(address(0xa2));
        vm.expectRevert(OrvynRNG.StillBonded.selector);
        rng.withdrawStake(1);
        vm.warp(block.timestamp + rng.UNBONDING());
        vm.prank(address(0xa2));
        rng.withdrawStake(1);
        assertEq(address(0xa2).balance, 0.1 ether);
    }

    function test_theOwnerCantSlashWithoutProof() public {
        registerAll();
        (bytes memory pk,,) = node(0);
        vm.prank(owner);
        vm.expectRevert(OrvynRNG.BadProof.selector);
        rng.reportEarlySignature(0, pk, round + 5000, fx.readBytes(".aggregateSignature"));
    }

    function test_aSplitChangeDoesntTouchRequestsAlreadyMade() public {
        uint256 requestId = rollAndCommit();
        requestId;
        // After the request, the owner moves everything to the treasury.
        vm.prank(owner);
        rng.configure(committer, 1, BASE_FEE, PER_GAS, 0, 0, treasury);
        fulfill();
        uint256 each = (BASE_FEE * 7000) / 10_000 / 3;
        assertEq(rng.earnings(address(0xa1)), each, "the round pays with the split its requests were made under");
    }

    function test_configBounds() public {
        vm.prank(owner);
        vm.expectRevert(OrvynRNG.BadConfig.selector);
        rng.configure(committer, 1, BASE_FEE, PER_GAS, 9000, 2000, treasury);
        vm.prank(makeAddr("mallory"));
        vm.expectRevert();
        rng.configure(committer, 1, 0, 0, 0, 0, treasury);
    }
}
