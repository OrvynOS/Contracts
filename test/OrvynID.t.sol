// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OrvynID, IAgentIdRegistry} from "../src/OrvynID.sol";
import {OrvynIds} from "../src/OrvynIds.sol";

/// A stand-in for Binance's Agent ID registry: ownerOf reverts for names that aren't minted.
contract MockAgentIds is IAgentIdRegistry {
    mapping(uint256 => address) public holders;

    function set(string memory name, address holder) external {
        holders[uint256(keccak256(bytes(name)))] = holder;
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        address h = holders[tokenId];
        require(h != address(0), "ERC721NonexistentToken");
        return h;
    }
}

contract OrvynIDTest is Test {
    OrvynID id;
    MockAgentIds agentIds;
    address owner = address(0xA11CE);
    address issuer = address(0xB0B);
    address creator = address(0xC0FFEE);
    address wallet = address(0xA6E47);
    address stranger = address(0xBAD);

    function setUp() public {
        agentIds = new MockAgentIds();
        OrvynID impl = new OrvynID();
        id = OrvynID(address(new ERC1967Proxy(address(impl), abi.encodeCall(OrvynID.initialize, (owner, agentIds, "orvyn.cash")))));
        vm.prank(owner);
        id.setIssuer(issuer, true);
    }

    function _issue() internal returns (uint256) {
        vm.prank(issuer);
        return id.issue("agent-1", wallet, creator, "atlas");
    }

    function test_issue_one_per_agent_and_wallet() public {
        uint256 t = _issue();
        assertEq(t, 1);
        assertEq(id.ownerOf(t), wallet);
        assertEq(id.tokenOfAgentId("agent-1"), t);
        assertEq(id.tokenOfWallet(wallet), t);
        assertTrue(id.locked(t));
        assertEq(id.tokenURI(t), "https://atlas.orvyn.cash/.well-known/orvyn-id.json");
        vm.startPrank(issuer);
        vm.expectRevert(OrvynID.AlreadyIssued.selector);
        id.issue("agent-1", address(0x1234), creator, "atlas2");
        vm.expectRevert(OrvynID.WalletTaken.selector);
        id.issue("agent-2", wallet, creator, "nova");
        vm.expectRevert(OrvynID.InvalidHandle.selector);
        id.issue("agent-2", address(0x1234), creator, "No-Caps");
        vm.expectRevert(OrvynID.InvalidHandle.selector);
        id.issue("agent-2", address(0x1234), creator, "a--b");
        vm.expectRevert(OrvynIds.InvalidId.selector);
        id.issue("bad id", address(0x1234), creator, "nova");
        vm.stopPrank();
    }

    function test_only_issuers_issue() public {
        vm.prank(stranger);
        vm.expectRevert(OrvynID.NotIssuer.selector);
        id.issue("agent-1", wallet, creator, "atlas");
    }

    function test_soulbound() public {
        uint256 t = _issue();
        vm.startPrank(wallet);
        vm.expectRevert(OrvynID.Soulbound.selector);
        id.transferFrom(wallet, stranger, t);
        vm.expectRevert(OrvynID.Soulbound.selector);
        id.safeTransferFrom(wallet, stranger, t);
        vm.expectRevert(OrvynID.Soulbound.selector);
        id.approve(stranger, t);
        vm.expectRevert(OrvynID.Soulbound.selector);
        id.setApprovalForAll(stranger, true);
        vm.stopPrank();
        assertTrue(id.supportsInterface(0xb45a3c0e), "ERC-5192");
        assertTrue(id.supportsInterface(0x80ac58cd), "ERC-721");
    }

    function test_agent_id_recorded_and_live() public {
        uint256 t = _issue();
        // Not held by the agent or its creator: refused.
        vm.prank(issuer);
        vm.expectRevert(OrvynID.AgentIdNotHeld.selector);
        id.recordAgentId(t, "atlas");
        agentIds.set("atlas", stranger);
        vm.prank(issuer);
        vm.expectRevert(OrvynID.AgentIdNotHeld.selector);
        id.recordAgentId(t, "atlas");
        // Held by the creator (an agent may use its owner's Agent ID): recorded, with an event.
        agentIds.set("atlas", creator);
        vm.expectEmit(true, false, false, true);
        emit OrvynID.AgentIdRecorded(t, "atlas", uint256(keccak256("atlas")), creator);
        vm.prank(issuer);
        id.recordAgentId(t, "atlas");
        (string memory name, uint256 token, address holder, bool heldNow) = id.agentIdOf(t);
        assertEq(name, "atlas");
        assertEq(token, uint256(keccak256("atlas")));
        assertEq(holder, creator);
        assertTrue(heldNow);
        // Sold: the live check sees it at once; the record stays until an issuer clears it.
        agentIds.set("atlas", stranger);
        (,, holder, heldNow) = id.agentIdOf(t);
        assertEq(holder, stranger);
        assertFalse(heldNow);
        (OrvynID.Identity memory ident,, bool held) = id.identityOf(t);
        assertEq(ident.agentIdName, "atlas");
        assertFalse(held);
        vm.prank(issuer);
        id.clearAgentId(t);
        (name,,, heldNow) = id.agentIdOf(t);
        assertEq(name, "");
        assertFalse(heldNow);
        vm.prank(issuer);
        vm.expectRevert(OrvynID.InvalidName.selector);
        id.recordAgentId(t, "Atlas");
    }

    function test_links_and_updates() public {
        uint256 t = _issue();
        vm.startPrank(issuer);
        id.linkErc8004(t, 42);
        id.setHandle(t, "atlas-two");
        id.setCreator(t, address(0x5EED));
        vm.stopPrank();
        (OrvynID.Identity memory ident, address w,) = id.identityOf(t);
        assertEq(ident.erc8004Id, 42);
        assertEq(ident.handle, "atlas-two");
        assertEq(ident.creator, address(0x5EED));
        assertEq(ident.agentKey, keccak256("agent-1"));
        assertEq(w, wallet);
        assertEq(id.tokenURI(t), "https://atlas-two.orvyn.cash/.well-known/orvyn-id.json");
    }

    function test_move_wallet_and_revoke() public {
        uint256 t = _issue();
        address next = address(0x2E7);
        vm.prank(stranger);
        vm.expectRevert(OrvynID.NotIssuer.selector);
        id.moveWallet(t, next);
        vm.prank(issuer);
        id.moveWallet(t, next);
        assertEq(id.ownerOf(t), next);
        assertEq(id.tokenOfWallet(next), t);
        assertEq(id.tokenOfWallet(wallet), 0);
        // Still locked for its new holder.
        vm.prank(next);
        vm.expectRevert(OrvynID.Soulbound.selector);
        id.transferFrom(next, wallet, t);
        // Revoked: burned, and the agent can be issued again.
        vm.prank(issuer);
        id.revoke(t);
        vm.expectRevert();
        id.ownerOf(t);
        assertEq(id.tokenOfAgentId("agent-1"), 0);
        vm.prank(issuer);
        uint256 again = id.issue("agent-1", next, creator, "atlas");
        assertEq(again, 2);
    }

    function test_only_owner_upgrades_and_appoints() public {
        vm.prank(stranger);
        vm.expectRevert();
        id.setIssuer(stranger, true);
        OrvynID next = new OrvynID();
        vm.prank(stranger);
        vm.expectRevert();
        id.upgradeToAndCall(address(next), "");
        vm.prank(owner);
        id.upgradeToAndCall(address(next), "");
    }
}
