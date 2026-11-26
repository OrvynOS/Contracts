// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {OrvynJobs} from "../src/OrvynJobs.sol";
import {MockERC20, Rejecter} from "./Mocks.sol";

contract OrvynJobsTest is Test {
    OrvynJobs c;
    MockERC20 usdc;

    address owner = makeAddr("owner");
    address op = makeAddr("op1");
    address client = makeAddr("client");
    address agent1 = makeAddr("agent1");
    address stranger = makeAddr("stranger");

    uint256 constant USDC = 1e18;
    uint64 constant T0 = 1_700_000_000;
    bytes32 constant RESULT = keccak256("result");

    function setUp() public {
        vm.warp(T0);
        usdc = new MockERC20("USDC");
        OrvynJobs impl = new OrvynJobs();
        c = OrvynJobs(address(new ERC1967Proxy(address(impl), abi.encodeCall(OrvynJobs.initialize, (owner, 1_000, 72)))));
        vm.startPrank(owner);
        c.setToken(address(usdc), USDC);
        c.setToken(address(0), 0.001 ether);
        c.addOperator(op);
        vm.stopPrank();
        usdc.mint(client, 1_000 * USDC);
        vm.prank(client);
        usdc.approve(address(c), type(uint256).max);
        vm.deal(client, 100 ether);
    }

    /// A funded 50 USDC job, due in 2 days.
    function _fund() internal {
        vm.prank(client);
        c.fund("job-1", "agent-1", agent1, address(usdc), 50 * USDC, T0 + 2 days);
    }

    function _job() internal view returns (OrvynJobs.Job memory j) {
        (j,) = c.getJob("job-1");
    }

    function _deliver(uint256 at) internal {
        vm.warp(at);
        vm.prank(op);
        c.markDelivered("job-1", RESULT);
    }

    function test_fundingRecordsTheJobWithTheCurrentFee() public {
        _fund();
        (OrvynJobs.Job memory j, uint64 reviewEnds) = c.getJob("job-1");
        assertEq(uint8(j.status), uint8(OrvynJobs.Status.Funded));
        assertEq(j.amount, 50 * USDC);
        assertEq(j.feeBps, 1_000);
        assertEq(j.reviewPeriod, 72 hours);
        assertEq(j.client, client);
        assertEq(j.payee, agent1);
        assertEq(j.agentId, "agent-1");
        assertEq(reviewEnds, 0);
        assertEq(c.held(address(usdc)), 50 * USDC);
    }

    function test_approvalPaysThePayeeMinusTheFee() public {
        _fund();
        _deliver(T0 + 1 hours);
        vm.prank(client);
        c.approve("job-1");
        OrvynJobs.Job memory j = _job();
        assertEq(uint8(j.status), uint8(OrvynJobs.Status.Released));
        assertEq(j.paidToPayee, 45 * USDC);
        assertEq(j.fee, 5 * USDC);
        assertEq(j.refunded, 0);
        assertEq(usdc.balanceOf(agent1), 45 * USDC);
        assertEq(c.fees(address(usdc)), 5 * USDC);
        assertEq(c.held(address(usdc)), 0);
    }

    function test_clientCanApproveBeforeDelivery() public {
        _fund();
        vm.prank(client);
        c.approve("job-1");
        assertEq(uint8(_job().status), uint8(OrvynJobs.Status.Released));
    }

    function test_onlyTheClientApproves() public {
        _fund();
        vm.prank(agent1);
        vm.expectRevert(OrvynJobs.NotClient.selector);
        c.approve("job-1");
    }

    function test_anyoneReleasesAfterTheReviewWindow() public {
        _fund();
        _deliver(T0 + 1 hours);
        vm.warp(T0 + 1 hours + 72 hours);
        vm.prank(stranger);
        c.release("job-1");
        assertEq(uint8(_job().status), uint8(OrvynJobs.Status.Released));
    }

    function test_noReleaseDuringTheReviewWindow() public {
        _fund();
        _deliver(T0 + 1 hours);
        vm.warp(T0 + 2 hours);
        vm.expectRevert(OrvynJobs.ReviewWindowOpen.selector);
        c.release("job-1");
    }

    function test_noReleaseWithoutDelivery() public {
        _fund();
        vm.warp(T0 + 10 days);
        vm.expectRevert(OrvynJobs.WrongStatus.selector);
        c.release("job-1");
    }

    function test_disputeThenOwnerSplits() public {
        _fund();
        _deliver(T0 + 1 hours);
        vm.prank(client);
        c.dispute("job-1", "half of it is missing");
        assertEq(uint8(_job().status), uint8(OrvynJobs.Status.Disputed));
        vm.prank(owner);
        c.resolve("job-1", 5_000);
        OrvynJobs.Job memory j = _job();
        assertEq(uint8(j.status), uint8(OrvynJobs.Status.Resolved));
        // 25 to the payee's side, 10% fee on that, 25 back to the client.
        assertEq(j.paidToPayee, 22.5e18);
        assertEq(j.fee, 2.5e18);
        assertEq(j.refunded, 25 * USDC);
        assertEq(usdc.balanceOf(client), 1_000 * USDC - 25 * USDC);
    }

    function test_aDisputedJobIsntReleased() public {
        _fund();
        _deliver(T0 + 1 hours);
        vm.prank(client);
        c.dispute("job-1", "");
        vm.warp(T0 + 10 days);
        vm.expectRevert(OrvynJobs.WrongStatus.selector);
        c.release("job-1");
    }

    function test_noDisputeAfterTheWindow() public {
        _fund();
        _deliver(T0 + 1 hours);
        vm.warp(T0 + 1 hours + 72 hours);
        vm.prank(client);
        vm.expectRevert(OrvynJobs.ReviewWindowEnded.selector);
        c.dispute("job-1", "late");
    }

    function test_onlyTheOwnerResolves() public {
        _fund();
        _deliver(T0 + 1 hours);
        vm.prank(client);
        c.dispute("job-1", "");
        vm.prank(op);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, op));
        c.resolve("job-1", 10_000);
    }

    function test_operatorAndAgentCanRefundInFull() public {
        _fund();
        vm.prank(op);
        c.refund("job-1");
        OrvynJobs.Job memory j = _job();
        assertEq(uint8(j.status), uint8(OrvynJobs.Status.Refunded));
        assertEq(j.refunded, 50 * USDC);
        assertEq(j.fee, 0);
        assertEq(usdc.balanceOf(client), 1_000 * USDC);

        vm.prank(client);
        c.fund("job-2", "agent-1", agent1, address(usdc), 5 * USDC, T0 + 1 days);
        vm.prank(agent1);
        c.refund("job-2");
        (OrvynJobs.Job memory j2,) = c.getJob("job-2");
        assertEq(uint8(j2.status), uint8(OrvynJobs.Status.Refunded));
    }

    function test_strangersCannotRefund() public {
        _fund();
        vm.prank(stranger);
        vm.expectRevert(OrvynJobs.NotAgentOrOperator.selector);
        c.refund("job-1");
    }

    function test_noRefundAfterPayout() public {
        _fund();
        vm.prank(client);
        c.approve("job-1");
        vm.prank(op);
        vm.expectRevert(OrvynJobs.WrongStatus.selector);
        c.refund("job-1");
    }

    function test_clientReclaimsAfterAMissedDeadline() public {
        _fund();
        vm.warp(T0 + 2 days + 1);
        vm.prank(client);
        c.reclaim("job-1");
        assertEq(uint8(_job().status), uint8(OrvynJobs.Status.Refunded));
    }

    function test_noReclaimBeforeTheDeadline() public {
        _fund();
        vm.warp(T0 + 1 days);
        vm.prank(client);
        vm.expectRevert(OrvynJobs.DeadlineNotPassed.selector);
        c.reclaim("job-1");
    }

    function test_noReclaimOnceDelivered() public {
        _fund();
        _deliver(T0 + 1 hours);
        vm.warp(T0 + 3 days);
        vm.prank(client);
        vm.expectRevert(OrvynJobs.WrongStatus.selector);
        c.reclaim("job-1");
    }

    function test_strangersCannotMarkDelivered() public {
        _fund();
        vm.prank(client);
        vm.expectRevert(OrvynJobs.NotAgentOrOperator.selector);
        c.markDelivered("job-1", RESULT);
    }

    function test_payeeCanMarkDelivered() public {
        _fund();
        vm.prank(agent1);
        c.markDelivered("job-1", RESULT);
        (OrvynJobs.Job memory j, uint64 reviewEnds) = c.getJob("job-1");
        assertEq(j.resultHash, RESULT);
        assertEq(reviewEnds, T0 + 72 hours);
    }

    function test_fundingChecks() public {
        _fund();
        vm.startPrank(client);
        vm.expectRevert(OrvynJobs.JobExists.selector);
        c.fund("job-1", "agent-1", agent1, address(usdc), 50 * USDC, T0 + 1 days);
        vm.expectRevert(OrvynJobs.BelowMinimum.selector);
        c.fund("job-2", "agent-1", agent1, address(usdc), USDC - 1, T0 + 1 days);
        vm.expectRevert(OrvynJobs.BadDeadline.selector);
        c.fund("job-2", "agent-1", agent1, address(usdc), 50 * USDC, T0 + 31 days);
        vm.expectRevert(OrvynJobs.BadDeadline.selector);
        c.fund("job-2", "agent-1", agent1, address(usdc), 50 * USDC, T0 + 30 minutes);
        vm.expectRevert(OrvynJobs.PayeeIsClient.selector);
        c.fund("job-2", "agent-1", client, address(usdc), 50 * USDC, T0 + 1 days);
        MockERC20 scam = new MockERC20("SCAM");
        vm.expectRevert(OrvynJobs.TokenNotAccepted.selector);
        c.fund("job-2", "agent-1", agent1, address(scam), 50 * USDC, T0 + 1 days);
        vm.expectRevert(OrvynJobs.BadValue.selector);
        c.fund{value: 1}("job-2", "agent-1", agent1, address(usdc), 50 * USDC, T0 + 1 days);
        vm.stopPrank();
    }

    function test_bnbJobs() public {
        vm.startPrank(client);
        vm.expectRevert(OrvynJobs.BadValue.selector);
        c.fund{value: 0.5 ether}("job-b", "agent-1", agent1, address(0), 1 ether, T0 + 1 days);
        c.fund{value: 1 ether}("job-b", "agent-1", agent1, address(0), 1 ether, T0 + 1 days);
        c.approve("job-b");
        vm.stopPrank();
        assertEq(agent1.balance, 0.9 ether);
        assertEq(c.fees(address(0)), 0.1 ether);
    }

    function test_failedPayoutIsOwedAndWithdrawnLater() public {
        Rejecter payee = new Rejecter();
        vm.prank(client);
        c.fund{value: 1 ether}("job-r", "agent-1", address(payee), address(0), 1 ether, T0 + 1 days);
        vm.prank(client);
        c.approve("job-r");
        assertEq(c.owed(address(payee), address(0)), 0.9 ether);
        assertEq(c.held(address(0)), 0.9 ether);

        // The fee is withdrawable, the owed payout isn't.
        vm.startPrank(owner);
        vm.expectRevert(OrvynJobs.ExceedsCollected.selector);
        c.withdrawFees(address(0), 0.2 ether, owner);
        c.withdrawFees(address(0), 0.1 ether, owner);
        vm.stopPrank();

        // Still refusing BNB: the withdrawal reverts and the debt stays.
        vm.expectRevert(OrvynJobs.TransferFailed.selector);
        payee.exec(address(c), 0, abi.encodeCall(OrvynJobs.withdrawOwed, (address(0))));
        assertEq(c.owed(address(payee), address(0)), 0.9 ether);
    }

    function test_nothingOwedByDefault() public {
        vm.prank(agent1);
        vm.expectRevert(OrvynJobs.NothingOwed.selector);
        c.withdrawOwed(address(usdc));
    }

    function test_ownerWithdrawsOnlyFees() public {
        _fund();
        vm.prank(owner);
        vm.expectRevert(OrvynJobs.ExceedsCollected.selector);
        c.withdrawFees(address(usdc), 1, owner);
    }

    function test_feeChangesApplyToNewJobsOnly() public {
        _fund();
        vm.prank(owner);
        c.setFeeBps(500);
        assertEq(_job().feeBps, 1_000);
        assertEq(c.feeBps(), 500);
    }

    function test_feeIsCapped() public {
        vm.prank(owner);
        vm.expectRevert(OrvynJobs.FeeTooHigh.selector);
        c.setFeeBps(2_001);
    }

    function test_upgradeKeepsState() public {
        _fund();
        OrvynJobs v2 = new OrvynJobs();
        vm.prank(owner);
        c.upgradeToAndCall(address(v2), "");
        assertEq(_job().amount, 50 * USDC);
        assertEq(c.feeBps(), 1_000);
    }
}
