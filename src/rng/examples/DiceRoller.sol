// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OrvynRNGConsumerBase} from "../OrvynRNGConsumerBase.sol";

/// @title Example Orvyn RNG consumer: roll a fair die
/// @notice Anyone calls `roll`; the result (1 to 6) arrives in the next round, from randomness
/// nobody (not the roller, the agents, drand or Orvyn) could know or steer in advance.
contract DiceRoller is OrvynRNGConsumerBase {
    mapping(uint256 requestId => address roller) public rollerOf;
    mapping(address roller => uint8) public lastRoll;

    event Rolled(address indexed roller, uint256 indexed requestId);
    event Landed(address indexed roller, uint256 indexed requestId, uint8 value);

    constructor(address rng, uint256 subId) OrvynRNGConsumerBase(rng, subId) {}

    function roll() external returns (uint256 requestId) {
        requestId = _requestRandomness(60_000);
        rollerOf[requestId] = msg.sender;
        emit Rolled(msg.sender, requestId);
    }

    function fulfillRandomness(uint256 requestId, bytes32 randomness) internal override {
        address roller = rollerOf[requestId];
        uint8 value = uint8(uint256(randomness) % 6) + 1;
        lastRoll[roller] = value;
        emit Landed(roller, requestId, value);
    }
}
