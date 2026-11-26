// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {AgentIdGated, IAgentId} from "./AgentIdGated.sol";

/// @title OrvynPay (standard mode)
/// @notice Public agent-to-agent payments in USDT, USDC or BNB. Both the payer and the payee must
/// hold a Binance Agent ID.
///
/// - `pay`: the payer sends the payment itself.
/// - `payWithSig`: the payer signs an EIP-712 `Payment` off chain and anyone (a relayer, the payee)
///   submits it. Token payments only (pulled with the payer's allowance to this contract); each
///   signature carries a unique nonce and an expiry, and can be cancelled before use.
///
/// Every payment carries a `ref` (an invoice, job or x402 request id) so receivers can match it.
/// The private mode is `OrvynShieldedPool`.
contract OrvynPay is AgentIdGated, EIP712, ReentrancyGuard, Ownable2Step {
    using SafeERC20 for IERC20;

    address public constant NATIVE = address(0);

    bytes32 public constant PAYMENT_TYPEHASH = keccak256(
        "Payment(address from,address to,address token,uint256 amount,bytes32 ref,bytes32 nonce,uint256 deadline)"
    );

    struct Payment {
        address from;
        address to;
        address token;
        uint256 amount;
        bytes32 ref;
        bytes32 nonce;
        uint256 deadline;
    }

    mapping(address token => bool) public acceptedToken;
    /// Used or cancelled signature nonces, per payer.
    mapping(address payer => mapping(bytes32 nonce => bool)) public nonceUsed;

    event Paid(address indexed from, address indexed to, address indexed token, uint256 amount, bytes32 ref, bool signed);
    event NonceCancelled(address indexed payer, bytes32 nonce);
    event TokenSet(address indexed token, bool accepted);

    error TokenNotAccepted();
    error ZeroAmount();
    error SelfPayment();
    error BadValue();
    error Expired();
    error NonceUsed();
    error BadSignature();
    error TransferFailed();

    constructor(IAgentId registry, address owner_, address[] memory tokens)
        AgentIdGated(registry)
        EIP712("OrvynPay", "1")
        Ownable(owner_)
    {
        acceptedToken[NATIVE] = true;
        emit TokenSet(NATIVE, true);
        for (uint256 i; i < tokens.length; ++i) {
            acceptedToken[tokens[i]] = true;
            emit TokenSet(tokens[i], true);
        }
    }

    function setToken(address token, bool accepted) external onlyOwner {
        acceptedToken[token] = accepted;
        emit TokenSet(token, accepted);
    }

    /// @notice Pay `to` directly. For BNB pass `token = NATIVE` and send exactly `amount`.
    function pay(address to, address token, uint256 amount, bytes32 ref) external payable nonReentrant {
        _check(msg.sender, to, token, amount);
        if (token == NATIVE) {
            if (msg.value != amount) revert BadValue();
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            if (msg.value != 0) revert BadValue();
            IERC20(token).safeTransferFrom(msg.sender, to, amount);
        }
        emit Paid(msg.sender, to, token, amount, ref, false);
    }

    /// @notice Submit a payment the payer signed (EIP-712, or ERC-1271 for contract wallets).
    function payWithSig(Payment calldata p, bytes calldata signature) external nonReentrant {
        if (p.token == NATIVE) revert TokenNotAccepted(); // BNB can't be pulled with a signature
        _check(p.from, p.to, p.token, p.amount);
        if (block.timestamp > p.deadline) revert Expired();
        if (nonceUsed[p.from][p.nonce]) revert NonceUsed();
        if (!SignatureChecker.isValidSignatureNow(p.from, hashPayment(p), signature)) revert BadSignature();
        nonceUsed[p.from][p.nonce] = true;
        IERC20(p.token).safeTransferFrom(p.from, p.to, p.amount);
        emit Paid(p.from, p.to, p.token, p.amount, p.ref, true);
    }

    /// @notice Cancel a signed payment before anyone submits it.
    function cancelNonce(bytes32 nonce) external {
        if (nonceUsed[msg.sender][nonce]) revert NonceUsed();
        nonceUsed[msg.sender][nonce] = true;
        emit NonceCancelled(msg.sender, nonce);
    }

    function hashPayment(Payment calldata p) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(abi.encode(PAYMENT_TYPEHASH, p.from, p.to, p.token, p.amount, p.ref, p.nonce, p.deadline))
        );
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function _check(address from, address to, address token, uint256 amount) private view {
        if (!acceptedToken[token]) revert TokenNotAccepted();
        if (amount == 0) revert ZeroAmount();
        if (from == to) revert SelfPayment();
        _requireAgentId(from);
        _requireAgentId(to);
    }
}
