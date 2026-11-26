// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor(string memory symbol) ERC20(symbol, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// Takes 1% of every transfer: must be refused.
contract FeeOnTransferERC20 is ERC20 {
    constructor() ERC20("FOT", "FOT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 cut = value / 100;
            super._update(from, address(0xdead), cut);
            value -= cut;
        }
        super._update(from, to, value);
    }
}

/// Stands in for the Binance Agent ID registry.
contract MockAgentId {
    mapping(address => uint256) public balanceOf;

    function set(address account, bool holds) external {
        balanceOf[account] = holds ? 1 : 0;
    }
}

contract MockVerifier {
    bool public result = true;

    function set(bool r) external {
        result = r;
    }

    function verifyProof(uint256[2] calldata, uint256[2][2] calldata, uint256[2] calldata, uint256[9] calldata)
        external
        view
        returns (bool)
    {
        return result;
    }
}

/// A receiver that refuses BNB.
contract Rejecter {
    receive() external payable {
        revert("no");
    }

    function exec(address target, uint256 value, bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = target.call{value: value}(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        return ret;
    }

    function fund() external payable {}
}
