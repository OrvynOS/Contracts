// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {OrvynRNG} from "../src/rng/OrvynRNG.sol";
import {OrvynPriceFeed, OrvynFeedAdapter, IOrvynNodes} from "../src/rng/OrvynPriceFeed.sol";

/// A reference feed with Chainlink's interface, 8 decimals, whose price the test sets.
contract MockAggregator {
    int256 public answer;

    function set(int256 a) external {
        answer = a;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, block.timestamp, block.timestamp, 1);
    }
}

/// Signed BTC / USD reports from three staked nodes (test/fixtures/rng.json, priceReport).
contract OrvynPriceFeedTest is Test {
    using stdJson for string;

    OrvynRNG rng;
    OrvynPriceFeed feeds;
    string fx;
    uint64 round;
    bytes32 feedId;
    int256 price;
    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address submitter = makeAddr("submitter");
    uint256 constant REWARD = 0.01 ether;

    function setUp() public {
        fx = vm.readFile("test/fixtures/rng.json");
        round = uint64(fx.readUint(".round"));
        feedId = fx.readBytes32(".priceReport.feedId");
        price = int256(vm.parseUint(fx.readString(".priceReport.price")));
        rng = new OrvynRNG(owner, makeAddr("committer"), treasury, 1, 0, 0, 7000, 2000);
        vm.deal(address(this), 10 ether);
        for (uint256 i; i < 3; ++i) {
            (bytes memory pk, address payee, bytes memory proof) = node(i);
            rng.register{value: 0.1 ether}(pk, payee, proof);
        }
        feeds = new OrvynPriceFeed(owner, IOrvynNodes(address(rng)), treasury);
        vm.prank(owner);
        // Quorum 2, a report when it moves 0.5% or hourly, 80% of each reward to the signers.
        feeds.configureFeed("BTC / USD", 2, 50, 3600, address(0), 0, REWARD, 8000);
        feeds.fund{value: 1 ether}(feedId);
        vm.warp(uint256(round) * 60 + 30);
    }

    function node(uint256 i) internal view returns (bytes memory pk, address payee, bytes memory proof) {
        string memory p = string.concat(".nodes[", vm.toString(i), "]");
        pk = fx.readBytes(string.concat(p, ".publicKey"));
        payee = fx.readAddress(string.concat(p, ".payee"));
        proof = fx.readBytes(string.concat(p, ".proof"));
    }

    function set(uint256 n) internal view returns (uint32[] memory ix, bytes memory keys) {
        ix = new uint32[](n);
        for (uint256 i; i < n; ++i) {
            ix[i] = uint32(i);
            (bytes memory pk,,) = node(i);
            keys = bytes.concat(keys, pk);
        }
    }

    function submit3() internal {
        (uint32[] memory ix, bytes memory keys) = set(3);
        vm.prank(submitter);
        feeds.submit(feedId, round, price, ix, keys, fx.readBytes(".priceReport.aggregate3"));
    }

    // ---------- Accepted reports ----------

    function test_aSignedReportIsAcceptedAndPaid() public {
        uint256 gasBefore = gasleft();
        submit3();
        emit log_named_uint("submit gas (3 signers)", gasBefore - gasleft());
        (int256 p, uint64 r,, uint16 signers) = feeds.latest(feedId);
        assertEq(p, price);
        assertEq(r, round);
        assertEq(signers, 3);
        uint256 each = (REWARD * 8000) / 10_000 / 3;
        assertEq(feeds.earnings(address(0xa1)), each, "signers are paid to their payees");
        assertEq(feeds.earnings(submitter), REWARD - each * 3, "the submitter gets the rest");
    }

    function test_aChainlinkConsumerReadsItUnchanged() public {
        submit3();
        OrvynFeedAdapter adapter = new OrvynFeedAdapter(feeds, feedId);
        (uint80 roundId, int256 answer,, uint256 updatedAt,) = adapter.latestRoundData();
        assertEq(answer, price);
        assertEq(uint256(roundId), round);
        assertEq(updatedAt, block.timestamp);
        assertEq(adapter.decimals(), 8);
        assertEq(adapter.description(), "BTC / USD");
    }

    function test_quorumOfTwoIsEnough() public {
        (uint32[] memory ix, bytes memory keys) = set(2);
        feeds.submit(feedId, round, price, ix, keys, fx.readBytes(".priceReport.aggregate2"));
        (,,, uint16 signers) = feeds.latest(feedId);
        assertEq(signers, 2);
    }

    // ---------- Refused reports ----------

    function test_belowQuorumIsRefused() public {
        vm.prank(owner);
        feeds.configureFeed("BTC / USD", 3, 50, 3600, address(0), 0, REWARD, 8000);
        (uint32[] memory ix, bytes memory keys) = set(2);
        vm.expectRevert(OrvynPriceFeed.BelowQuorum.selector);
        feeds.submit(feedId, round, price, ix, keys, fx.readBytes(".priceReport.aggregate2"));
    }

    function test_aDifferentPriceThanSignedIsRefused() public {
        (uint32[] memory ix, bytes memory keys) = set(3);
        vm.expectRevert(OrvynPriceFeed.BadSignature.selector);
        feeds.submit(feedId, round, price + 1, ix, keys, fx.readBytes(".priceReport.aggregate3"));
    }

    function test_staleFutureAndRepeatedReportsAreRefused() public {
        (uint32[] memory ix, bytes memory keys) = set(3);
        bytes memory agg = fx.readBytes(".priceReport.aggregate3");
        vm.warp(uint256(round) * 60 - 1);
        vm.expectRevert(OrvynPriceFeed.StaleOrFutureRound.selector);
        feeds.submit(feedId, round, price, ix, keys, agg);
        vm.warp(uint256(round) * 60 + 11 minutes);
        vm.expectRevert(OrvynPriceFeed.StaleOrFutureRound.selector);
        feeds.submit(feedId, round, price, ix, keys, agg);
        vm.warp(uint256(round) * 60 + 30);
        feeds.submit(feedId, round, price, ix, keys, agg);
        vm.expectRevert(OrvynPriceFeed.NotNewer.selector);
        feeds.submit(feedId, round, price, ix, keys, agg);
    }

    function test_onlyUsefulReportsAreTaken() public {
        submit3();
        assertFalse(feeds.isUseful(feedId, price), "an unchanged price isn't worth a report");
        assertFalse(feeds.isUseful(feedId, price + price / 1000), "0.1% is under the 0.5% threshold");
        assertTrue(feeds.isUseful(feedId, price + price / 100), "1% is worth a report");
        vm.warp(block.timestamp + 3600);
        assertTrue(feeds.isUseful(feedId, price), "the heartbeat makes it due");
    }

    function test_aReportFarFromTheReferenceIsRefused() public {
        MockAggregator ref = new MockAggregator();
        ref.set((price * 95) / 100); // the reference says 5% lower
        vm.prank(owner);
        feeds.configureFeed("BTC / USD", 2, 50, 3600, address(ref), 200, REWARD, 8000);
        (uint32[] memory ix, bytes memory keys) = set(3);
        bytes memory agg = fx.readBytes(".priceReport.aggregate3");
        vm.expectRevert(OrvynPriceFeed.OffReference.selector);
        feeds.submit(feedId, round, price, ix, keys, agg);
        ref.set((price * 995) / 1000); // within 2%
        feeds.submit(feedId, round, price, ix, keys, agg);
    }

    function test_aLeavingNodeNoLongerCounts() public {
        vm.prank(address(0xa3));
        rng.exit(2);
        (uint32[] memory ix, bytes memory keys) = set(3);
        vm.expectRevert(OrvynPriceFeed.NodeNotActive.selector);
        feeds.submit(feedId, round, price, ix, keys, fx.readBytes(".priceReport.aggregate3"));
    }

    function test_unknownKeysAreRefused() public {
        (uint32[] memory ix, bytes memory keys) = set(3);
        keys[300] = bytes1(uint8(keys[300]) ^ 1);
        vm.expectRevert(OrvynPriceFeed.UnknownNode.selector);
        feeds.submit(feedId, round, price, ix, keys, fx.readBytes(".priceReport.aggregate3"));
    }

    // ---------- Slashing a node that signed two prices ----------

    function test_signingTwoPricesForOneRoundIsSlashed() public {
        (bytes memory pk,,) = node(0);
        int256 a = int256(vm.parseUint(fx.readString(".priceReport.equivocation.priceA")));
        int256 b = int256(vm.parseUint(fx.readString(".priceReport.equivocation.priceB")));
        bytes memory sigA = fx.readBytes(".priceReport.equivocation.sigA");
        bytes memory sigB = fx.readBytes(".priceReport.equivocation.sigB");
        vm.expectRevert(OrvynRNG.SameReport.selector);
        rng.reportEquivocation(0, pk, feedId, round, a, sigA, a, sigA);
        // Another round's message doesn't match these signatures.
        vm.expectRevert(OrvynRNG.BadProof.selector);
        rng.reportEquivocation(0, pk, feedId, round + 1, a, sigA, b, sigB);
        address reporter = makeAddr("reporter");
        vm.prank(reporter);
        rng.reportEquivocation(0, pk, feedId, round, a, sigA, b, sigB);
        (,,,, uint128 stake,, bool slashed) = rng.nodes(0);
        assertTrue(slashed);
        assertEq(stake, 0);
        assertEq(rng.earnings(reporter), 0.05 ether);
        // A slashed node can't sign reports any more.
        (uint32[] memory ix, bytes memory keys) = set(3);
        vm.expectRevert(OrvynPriceFeed.NodeNotActive.selector);
        feeds.submit(feedId, round, price, ix, keys, fx.readBytes(".priceReport.aggregate3"));
    }

    function test_onlyTheOwnerConfiguresFeeds() public {
        vm.prank(makeAddr("mallory"));
        vm.expectRevert();
        feeds.configureFeed("BTC / USD", 1, 0, 1, address(0), 0, 0, 0);
    }
}
