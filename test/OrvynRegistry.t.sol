// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {OrvynRegistry} from "../src/OrvynRegistry.sol";
import {OrvynIds} from "../src/OrvynIds.sol";
import {MockERC20, FeeOnTransferERC20} from "./Mocks.sol";

contract OrvynRegistryV2 is OrvynRegistry {
    function version() external pure override returns (string memory) {
        return "2.0.0";
    }
}

contract OrvynRegistryTest is Test {
    OrvynRegistry r;
    MockERC20 usdc;
    MockERC20 usdt;

    address owner = makeAddr("owner");
    address backend = makeAddr("backend");
    address alice = makeAddr("alice");
    address agent1 = makeAddr("agent1");
    address mallory = makeAddr("mallory");

    uint256 constant PRICE = 20e18; // 20 USDC (18 decimals on BSC)
    uint256 constant BNB_PRICE = 0.03 ether;
    uint256 constant T0 = 1_700_000_000;

    function setUp() public {
        vm.warp(T0);
        usdc = new MockERC20("USDC");
        usdt = new MockERC20("USDT");
        OrvynRegistry impl = new OrvynRegistry();
        r = OrvynRegistry(address(new ERC1967Proxy(address(impl), abi.encodeCall(OrvynRegistry.initialize, (owner)))));
        vm.startPrank(owner);
        r.setPrice(address(usdc), PRICE);
        r.setPrice(address(usdt), PRICE);
        r.setPrice(address(0), BNB_PRICE);
        r.addOperator(backend);
        vm.stopPrank();
        vm.prank(backend);
        r.registerAgent("agent-1", alice, agent1);

        usdc.mint(alice, 10_000e18);
        usdt.mint(agent1, 10_000e18);
        vm.prank(alice);
        usdc.approve(address(r), type(uint256).max);
        vm.prank(agent1);
        usdt.approve(address(r), type(uint256).max);
        vm.deal(alice, 100 ether);
        vm.deal(agent1, 100 ether);
    }

    function _repeat(string memory c, uint256 n) internal pure returns (string memory out) {
        for (uint256 i; i < n; ++i) out = string.concat(out, c);
    }

    function paidUntil() internal view returns (uint64) {
        (, OrvynRegistry.AgentView memory a) = r.getAgent("agent-1");
        return a.paidUntil;
    }

    function test_registrationStartsUnpaid() public view {
        // No free trial: hosting starts with the first payment.
        assertEq(paidUntil(), T0);
        assertFalse(r.isActive("agent-1"));
        (bool found, OrvynRegistry.AgentView memory a) = r.getAgent("agent-1");
        assertTrue(found);
        assertEq(a.owner, alice);
        assertEq(a.agentWallet, agent1);
        assertEq(a.agentId, "agent-1");
    }

    function test_strangersCannotRegister() public {
        vm.prank(mallory);
        vm.expectRevert(OrvynRegistry.NotOperator.selector);
        r.registerAgent("agent-2", mallory, mallory);
    }

    function test_agentRegistersOnce() public {
        vm.prank(backend);
        vm.expectRevert(OrvynRegistry.AgentExists.selector);
        r.registerAgent("agent-1", alice, agent1);
    }

    function test_invalidIdsAreRefused() public {
        vm.startPrank(backend);
        vm.expectRevert(OrvynIds.InvalidId.selector);
        r.registerAgent("", alice, agent1);
        vm.expectRevert(OrvynIds.InvalidId.selector);
        r.registerAgent("bad id", alice, agent1);
        vm.expectRevert(OrvynIds.InvalidId.selector);
        r.registerAgent(_repeat("a", 65), alice, agent1);
        vm.stopPrank();
    }

    function test_tokenPaymentTakesWholeMonthsOnly() public {
        vm.prank(alice);
        (uint32 months, uint256 used) = r.pay("agent-1", address(usdc), PRICE * 2 + 5);
        assertEq(months, 2);
        assertEq(used, PRICE * 2);
        assertEq(usdc.balanceOf(address(r)), PRICE * 2); // the remainder was never taken
        assertEq(paidUntil(), T0 + 2 * 30 days);
        assertEq(r.revenue(address(usdc)), PRICE * 2);
        assertEq(r.totalPaid(keccak256("agent-1"), address(usdc)), PRICE * 2);
    }

    function test_bnbPaymentRefundsTheRemainder() public {
        uint256 before = alice.balance;
        vm.prank(alice);
        (uint32 months,) = r.pay{value: BNB_PRICE * 3 + 1}("agent-1", address(0), 0);
        assertEq(months, 3);
        assertEq(before - alice.balance, BNB_PRICE * 3);
        assertEq(r.revenue(address(0)), BNB_PRICE * 3);
    }

    function test_valueWithATokenPaymentIsRefused() public {
        vm.prank(alice);
        vm.expectRevert(OrvynRegistry.UnexpectedValue.selector);
        r.pay{value: 1}("agent-1", address(usdc), PRICE);
    }

    function test_paymentAfterExpiryStartsFromNow() public {
        uint256 later = T0 + 40 days;
        vm.warp(later);
        assertFalse(r.isActive("agent-1"));
        vm.prank(agent1);
        r.pay("agent-1", address(usdt), PRICE);
        assertEq(paidUntil(), later + 30 days);
        assertTrue(r.isActive("agent-1"));
    }

    function test_capsMonths() public {
        vm.prank(alice);
        (uint32 months, uint256 used) = r.pay("agent-1", address(usdc), PRICE * 40);
        assertEq(months, 36);
        assertEq(used, PRICE * 36);
    }

    function test_rejectsOtherTokens() public {
        MockERC20 scam = new MockERC20("SCAM");
        vm.prank(alice);
        vm.expectRevert(OrvynRegistry.TokenNotAccepted.selector);
        r.pay("agent-1", address(scam), PRICE);
    }

    function test_rejectsUnknownAgent() public {
        vm.prank(alice);
        vm.expectRevert(OrvynRegistry.UnknownAgent.selector);
        r.pay("nope", address(usdc), PRICE);
    }

    function test_rejectsUnderpayment() public {
        vm.prank(alice);
        vm.expectRevert(OrvynRegistry.LessThanOneMonth.selector);
        r.pay("agent-1", address(usdc), PRICE - 1);
    }

    function test_rejectsFeeOnTransferTokens() public {
        FeeOnTransferERC20 fot = new FeeOnTransferERC20();
        vm.prank(owner);
        r.setPrice(address(fot), PRICE);
        fot.mint(alice, PRICE);
        vm.startPrank(alice);
        fot.approve(address(r), PRICE);
        vm.expectRevert(OrvynRegistry.ReceivedLess.selector);
        r.pay("agent-1", address(fot), PRICE);
        vm.stopPrank();
    }

    function test_paymentsAreLoggedForInvoices() public {
        vm.warp(T0 + 1000);
        vm.prank(alice);
        r.pay("agent-1", address(usdc), PRICE * 2 + 5);
        vm.warp(T0 + 5000);
        vm.prank(agent1);
        r.pay("agent-1", address(usdt), PRICE);

        OrvynRegistry.Payment[] memory all = r.getPayments("agent-1", 0, 50);
        assertEq(all.length, 2);
        assertEq(all[0].payer, alice);
        assertEq(all[0].token, address(usdc));
        assertEq(all[0].months, 2);
        assertEq(all[0].amount, PRICE * 2);
        assertEq(all[0].periodStart, T0 + 1000); // no trial: the first period starts when paid
        assertEq(all[0].paidUntil, T0 + 1000 + 60 days);
        assertEq(all[1].periodStart, all[0].paidUntil);
        assertEq(all[1].token, address(usdt));
        assertEq(all[1].paidAt, T0 + 5000);

        OrvynRegistry.Payment[] memory page = r.getPayments("agent-1", 1, 10);
        assertEq(page.length, 1);
        assertEq(page[0].payer, agent1);
        assertEq(r.getPayments("agent-1", 5, 10).length, 0);
        assertEq(r.getPayments("nobody", 0, 10).length, 0);
    }

    function test_ownerWithdrawsOnlyCollectedRevenue() public {
        vm.prank(alice);
        r.pay{value: BNB_PRICE}("agent-1", address(0), 0);
        address treasury = makeAddr("treasury");
        vm.startPrank(owner);
        r.withdraw(address(0), BNB_PRICE, treasury);
        assertEq(treasury.balance, BNB_PRICE);
        vm.expectRevert(OrvynRegistry.ExceedsCollected.selector);
        r.withdraw(address(0), 1, treasury);
        vm.stopPrank();
    }

    function test_onlyTheOwnerWithdraws() public {
        vm.prank(alice);
        r.pay{value: BNB_PRICE}("agent-1", address(0), 0);
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, mallory));
        r.withdraw(address(0), 1, mallory);
    }

    function test_cannotWithdrawMoreTokenRevenueThanCollected() public {
        vm.prank(owner);
        vm.expectRevert(OrvynRegistry.ExceedsCollected.selector);
        r.withdraw(address(usdc), 1, owner);
    }

    function test_binancePayCreditsOnce() public {
        address creditor = makeAddr("creditor");
        vm.prank(owner);
        r.addCreditor(creditor);
        bytes32 ref = keccak256("ORV1234");
        vm.prank(creditor);
        r.creditExternal("agent-1", 2, ref, 40e18);
        assertEq(paidUntil(), T0 + 60 days);
        assertTrue(r.externalRefs(ref));
        OrvynRegistry.Payment[] memory ps = r.getPayments("agent-1", 0, 10);
        assertEq(ps.length, 1);
        assertEq(ps[0].token, r.BINANCE_PAY());
        assertEq(ps[0].amount, 40e18);
        assertEq(ps[0].months, 2);
        // No on-chain revenue: nothing was paid on chain.
        assertEq(r.revenue(r.BINANCE_PAY()), 0);

        vm.prank(creditor);
        vm.expectRevert(OrvynRegistry.RefUsed.selector);
        r.creditExternal("agent-1", 2, ref, 40e18);
    }

    function test_binancePayCreditRules() public {
        address creditor = makeAddr("creditor");
        vm.prank(owner);
        r.addCreditor(creditor);
        // Operators and strangers can't credit.
        vm.prank(backend);
        vm.expectRevert(OrvynRegistry.NotCreditor.selector);
        r.creditExternal("agent-1", 1, keccak256("a"), 20e18);
        vm.prank(owner);
        vm.expectRevert(OrvynRegistry.NotCreditor.selector);
        r.creditExternal("agent-1", 1, keccak256("a"), 20e18);
        vm.startPrank(creditor);
        vm.expectRevert(OrvynRegistry.BadMonths.selector);
        r.creditExternal("agent-1", 0, keccak256("a"), 0);
        vm.expectRevert(OrvynRegistry.BadMonths.selector);
        r.creditExternal("agent-1", 37, keccak256("a"), 0);
        vm.expectRevert(OrvynRegistry.UnknownAgent.selector);
        r.creditExternal("nobody", 1, keccak256("a"), 20e18);
        vm.stopPrank();
        vm.prank(owner);
        r.removeCreditor(creditor);
        vm.prank(creditor);
        vm.expectRevert(OrvynRegistry.NotCreditor.selector);
        r.creditExternal("agent-1", 1, keccak256("b"), 20e18);
    }

    function test_grantDays() public {
        vm.prank(owner);
        r.grantDays("agent-1", 10);
        assertEq(paidUntil(), T0 + 10 days);
    }

    function test_removeTokenStopsPayments() public {
        vm.prank(owner);
        r.removeToken(address(usdc));
        vm.prank(alice);
        vm.expectRevert(OrvynRegistry.TokenNotAccepted.selector);
        r.pay("agent-1", address(usdc), PRICE);
        assertEq(r.getPrices().length, 2);
    }

    function test_upgradeKeepsState() public {
        vm.prank(alice);
        r.pay("agent-1", address(usdc), PRICE);
        OrvynRegistryV2 v2 = new OrvynRegistryV2();

        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, mallory));
        r.upgradeToAndCall(address(v2), "");

        vm.prank(owner);
        r.upgradeToAndCall(address(v2), "");
        assertEq(r.version(), "2.0.0");
        assertEq(r.revenue(address(usdc)), PRICE);
        (, OrvynRegistry.AgentView memory a) = r.getAgent("agent-1");
        assertEq(a.owner, alice);
        assertEq(a.payments, 1);
    }

    // ---------- Tiers ----------

    function _offerTiers() internal {
        vm.startPrank(owner);
        r.setTierPrice(1, 30000); // Pro: 3x ($60)
        r.setTierPrice(2, 75000); // Studio: 7.5x ($150)
        vm.stopPrank();
    }

    function test_newAgentsStartOnBasic() public view {
        (, OrvynRegistry.AgentView memory a) = r.getAgent("agent-1");
        assertEq(a.tier, 0);
        assertEq(r.priceFor(0, address(usdc)), PRICE);
        assertEq(r.priceFor(1, address(usdc)), 0); // not offered until priced
    }

    function test_tierPricing() public {
        _offerTiers();
        assertEq(r.priceFor(1, address(usdc)), 60e18);
        assertEq(r.priceFor(2, address(usdc)), 150e18);
        assertEq(r.priceFor(2, address(0)), BNB_PRICE * 75 / 10);
        assertEq(r.priceFor(3, address(usdc)), 0);

        vm.startPrank(owner);
        vm.expectRevert(OrvynRegistry.TierUnavailable.selector);
        r.setTierPrice(0, 20000); // Basic is the base price
        vm.expectRevert(OrvynRegistry.TierUnavailable.selector);
        r.setTierPrice(3, 20000);
        vm.expectRevert(OrvynRegistry.ZeroPrice.selector);
        r.setTierPrice(1, 9000); // never below Basic
        vm.stopPrank();

        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, mallory));
        r.setTierPrice(1, 10000);
    }

    function test_paymentUsesTheAgentsTier() public {
        _offerTiers();
        vm.prank(alice);
        r.changeTier("agent-1", 2);
        vm.prank(alice);
        (uint32 months, uint256 used) = r.pay("agent-1", address(usdc), 300e18 + 1);
        assertEq(months, 2);
        assertEq(used, 300e18);
        assertEq(paidUntil(), T0 + 60 days);

        vm.prank(alice);
        vm.expectRevert(OrvynRegistry.LessThanOneMonth.selector);
        r.pay("agent-1", address(usdc), 100e18); // a Basic month's money doesn't buy a Studio month
    }

    function test_changingTierConvertsPaidTime() public {
        _offerTiers();
        vm.prank(alice);
        r.pay("agent-1", address(usdc), PRICE * 3); // 90 days of Basic ($60)
        vm.prank(alice);
        uint64 until = r.changeTier("agent-1", 1); // Pro is 3x: 30 days
        assertEq(until, T0 + 30 days);

        vm.warp(T0 + 10 days); // 20 Pro days left
        vm.prank(backend);
        until = r.changeTier("agent-1", 0); // back to Basic: 60 days
        assertEq(until, T0 + 10 days + 60 days);
        assertEq(r.tierOf("agent-1"), 0);
    }

    function test_lapsedAgentChangesTierWithoutCredit() public {
        _offerTiers();
        vm.warp(T0 + 5 days);
        vm.prank(alice);
        uint64 until = r.changeTier("agent-1", 2);
        assertEq(until, T0); // nothing left to convert
        assertFalse(r.isActive("agent-1"));
    }

    function test_tierChangeRules() public {
        vm.prank(alice);
        vm.expectRevert(OrvynRegistry.TierUnavailable.selector);
        r.changeTier("agent-1", 1); // not priced yet
        _offerTiers();
        vm.prank(mallory);
        vm.expectRevert(OrvynRegistry.NotAgentOwner.selector);
        r.changeTier("agent-1", 1);
        vm.prank(alice);
        vm.expectRevert(OrvynRegistry.SameTier.selector);
        r.changeTier("agent-1", 0);
        vm.prank(alice);
        vm.expectRevert(OrvynRegistry.UnknownAgent.selector);
        r.changeTier("agent-9", 1);

        // A tier withdrawn from sale can't be paid for or moved to.
        vm.prank(alice);
        r.changeTier("agent-1", 1);
        vm.prank(owner);
        r.setTierPrice(1, 0);
        vm.prank(alice);
        vm.expectRevert(OrvynRegistry.TokenNotAccepted.selector);
        r.pay("agent-1", address(usdc), 1000e18);
    }

    function test_operatorsAttestTheEnvironment() public {
        bytes32 h = keccak256("{\"hosting\":\"orvyn\",\"tier\":\"studio\"}");
        vm.prank(mallory);
        vm.expectRevert(OrvynRegistry.NotOperator.selector);
        r.attestEnvironment("agent-1", h);
        vm.prank(backend);
        r.attestEnvironment("agent-1", h);
        (, OrvynRegistry.AgentView memory a) = r.getAgent("agent-1");
        assertEq(a.environmentHash, h);
        assertEq(r.environmentHash(keccak256("agent-1")), h);
    }

    function test_implementationCannotBeInitialized() public {
        OrvynRegistry impl = new OrvynRegistry();
        vm.expectRevert();
        impl.initialize(owner);
    }
}
