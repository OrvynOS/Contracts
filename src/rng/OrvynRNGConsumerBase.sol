// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IOrvynRNGConsumer} from "./OrvynRNG.sol";

interface IOrvynRNG {
    function requestRandomness(uint256 subId, uint32 callbackGasLimit) external returns (uint256 requestId, uint64 round);
    function feeFor(uint32 callbackGasLimit) external view returns (uint256);
    function randomnessFor(uint256 requestId) external view returns (bytes32);
}

/// @title Base for contracts that use Orvyn RNG
/// @notice Inherit, request with `_requestRandomness`, and receive the value in
/// `fulfillRandomness`. Your subscription (created and funded on OrvynRNG, with this contract
/// added as a consumer) pays for each request; the agents that produce each round earn the fees.
///
/// ```solidity
/// contract Raffle is OrvynRNGConsumerBase {
///     constructor(address rng, uint256 subId) OrvynRNGConsumerBase(rng, subId) {}
///     function draw() external { _requestRandomness(100_000); }
///     function fulfillRandomness(uint256, bytes32 r) internal override { winner = entrants[uint256(r) % entrants.length]; }
/// }
/// ```
abstract contract OrvynRNGConsumerBase is IOrvynRNGConsumer {
    IOrvynRNG public immutable orvynRNG;
    uint256 public immutable orvynSubscription;

    error OnlyOrvynRNG();

    constructor(address rng, uint256 subId) {
        orvynRNG = IOrvynRNG(rng);
        orvynSubscription = subId;
    }

    /// Request randomness for the next round, charged to this contract's subscription.
    function _requestRandomness(uint32 callbackGasLimit) internal returns (uint256 requestId) {
        (requestId,) = orvynRNG.requestRandomness(orvynSubscription, callbackGasLimit);
    }

    /// Called by Orvyn RNG with the verified value. Keep it cheap: it runs with the gas you asked for.
    function fulfillRandomness(uint256 requestId, bytes32 randomness) internal virtual;

    /// @inheritdoc IOrvynRNGConsumer
    function rawFulfillRandomness(uint256 requestId, bytes32 randomness) external {
        if (msg.sender != address(orvynRNG)) revert OnlyOrvynRNG();
        fulfillRandomness(requestId, randomness);
    }
}
