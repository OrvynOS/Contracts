// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {OrvynPay} from "../src/pay/OrvynPay.sol";
import {AgentIdGated, IAgentId} from "../src/pay/AgentIdGated.sol";
import {MockERC20, MockAgentId} from "./Mocks.sol";

contract OrvynPayTest is Test {
    OrvynPay pay;
    MockERC20 usdt;
    MockAgentId agentId;

    address owner = makeAddr("owner");
    uint256 alicePk = 0xA11CE;
    address alice; // paying agent
    address bob = makeAddr("bob"); // paid agent
    address relayer = makeAddr("relayer");
    address outsider = makeAddr("outsider"); // no Agent ID

    function setUp() public {
        alice = vm.addr(alicePk);
        usdt = new MockERC20("USDT");
        agentId = new MockAgentId();
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdt);
        pay = new OrvynPay(IAgentId(address(agentId)), owner, tokens);
        agentId.set(alice, true);
        agentId.set(bob, true);
        usdt.mint(alice, 1_000e18);
        vm.prank(alice);
        usdt.approve(address(pay), type(uint256).max);
        vm.deal(alice, 10 ether);
    }

    function _payment(uint256 amount, bytes32 nonce) internal view returns (OrvynPay.Payment memory) {
        return OrvynPay.Payment({
            from: alice,
            to: bob,
            token: address(usdt),
            amount: amount,
            ref: keccak256("invoice-1"),
            nonce: nonce,
            deadline: block.timestamp + 1 hours
        });
    }

    function _sign(OrvynPay.Payment memory p) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, pay.hashPayment(p));
        return abi.encodePacked(r, s, v);
    }

    function test_directTokenPayment() public {
        vm.prank(alice);
        pay.pay(bob, address(usdt), 10e18, bytes32("ref"));
        assertEq(usdt.balanceOf(bob), 10e18);
    }

    function test_directBnbPayment() public {
        vm.prank(alice);
        pay.pay{value: 1 ether}(bob, address(0), 1 ether, bytes32("ref"));
        assertEq(bob.balance, 1 ether);
        vm.prank(alice);
        vm.expectRevert(OrvynPay.BadValue.selector);
        pay.pay{value: 0.5 ether}(bob, address(0), 1 ether, bytes32("ref"));
    }

    function test_bothSidesNeedAnAgentId() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AgentIdGated.NoAgentId.selector, outsider));
        pay.pay(outsider, address(usdt), 1e18, 0);

        usdt.mint(outsider, 10e18);
        vm.startPrank(outsider);
        usdt.approve(address(pay), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(AgentIdGated.NoAgentId.selector, outsider));
        pay.pay(bob, address(usdt), 1e18, 0);
        vm.stopPrank();
    }

    function test_losingTheAgentIdStopsPayments() public {
        agentId.set(bob, false);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AgentIdGated.NoAgentId.selector, bob));
        pay.pay(bob, address(usdt), 1e18, 0);
    }

    function test_basicChecks() public {
        MockERC20 scam = new MockERC20("SCAM");
        vm.startPrank(alice);
        vm.expectRevert(OrvynPay.TokenNotAccepted.selector);
        pay.pay(bob, address(scam), 1, 0);
        vm.expectRevert(OrvynPay.ZeroAmount.selector);
        pay.pay(bob, address(usdt), 0, 0);
        vm.expectRevert(OrvynPay.SelfPayment.selector);
        pay.pay(alice, address(usdt), 1, 0);
        vm.stopPrank();
    }

    function test_signedPaymentIsRelayed() public {
        OrvynPay.Payment memory p = _payment(25e18, bytes32(uint256(1)));
        bytes memory sig = _sign(p);
        vm.prank(relayer);
        pay.payWithSig(p, sig);
        assertEq(usdt.balanceOf(bob), 25e18);
        assertTrue(pay.nonceUsed(alice, p.nonce));

        vm.prank(relayer);
        vm.expectRevert(OrvynPay.NonceUsed.selector);
        pay.payWithSig(p, sig);
    }

    function test_signatureMustMatchThePayment() public {
        OrvynPay.Payment memory p = _payment(25e18, bytes32(uint256(2)));
        bytes memory sig = _sign(p);
        p.amount = 26e18;
        vm.expectRevert(OrvynPay.BadSignature.selector);
        pay.payWithSig(p, sig);

        p.amount = 25e18;
        p.to = makeAddr("other");
        agentId.set(p.to, true);
        vm.expectRevert(OrvynPay.BadSignature.selector);
        pay.payWithSig(p, sig);
    }

    function test_expiredSignaturesAreRefused() public {
        OrvynPay.Payment memory p = _payment(1e18, bytes32(uint256(3)));
        bytes memory sig = _sign(p);
        vm.warp(p.deadline + 1);
        vm.expectRevert(OrvynPay.Expired.selector);
        pay.payWithSig(p, sig);
    }

    function test_payerCanCancelASignature() public {
        OrvynPay.Payment memory p = _payment(1e18, bytes32(uint256(4)));
        bytes memory sig = _sign(p);
        vm.prank(alice);
        pay.cancelNonce(p.nonce);
        vm.expectRevert(OrvynPay.NonceUsed.selector);
        pay.payWithSig(p, sig);
    }

    function test_signedBnbIsRefused() public {
        OrvynPay.Payment memory p = _payment(1e18, bytes32(uint256(5)));
        p.token = address(0);
        bytes memory sig = _sign(p);
        vm.expectRevert(OrvynPay.TokenNotAccepted.selector);
        pay.payWithSig(p, sig);
    }

    function test_onlyOwnerListsTokens() public {
        MockERC20 usdc = new MockERC20("USDC");
        vm.expectRevert();
        pay.setToken(address(usdc), true);
        vm.prank(owner);
        pay.setToken(address(usdc), true);
        assertTrue(pay.acceptedToken(address(usdc)));
    }
}
