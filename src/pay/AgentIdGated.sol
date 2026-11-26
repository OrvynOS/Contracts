// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice The Binance Agent ID (`name.ai`, SPACE ID) registry on BNB Chain exposes an
/// ERC-721-style `balanceOf`. Verify the deployed interface on BscScan before mainnet.
interface IAgentId {
    function balanceOf(address owner) external view returns (uint256);
}

/// @notice OrvynPay is only for agents holding a Binance Agent ID, on both sides of a payment.
/// The Agent ID contract is fixed at deployment: nobody (not even the owner) can swap it later
/// and so lock funds by changing who counts as verified.
abstract contract AgentIdGated {
    IAgentId public immutable agentIdRegistry;

    error NoAgentId(address account);

    constructor(IAgentId registry) {
        agentIdRegistry = registry;
    }

    function hasAgentId(address account) public view returns (bool) {
        if (account == address(0)) return false;
        try agentIdRegistry.balanceOf(account) returns (uint256 n) {
            return n > 0;
        } catch {
            return false;
        }
    }

    function _requireAgentId(address account) internal view {
        if (!hasAgentId(account)) revert NoAgentId(account);
    }
}
