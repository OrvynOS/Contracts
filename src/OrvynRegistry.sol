// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {OrvynIds} from "./OrvynIds.sol";

/// @title Orvyn agent registry (BNB Smart Chain)
/// @notice Each Orvyn agent is registered under its agent id. Its hosting subscription is paid in
/// USDT, USDC or BNB by anyone (its owner, or the agent itself on autopay): whole months are
/// credited (at most 36 per payment) and only that is taken; the remainder of a BNB payment is
/// refunded. Paying after expiry starts a new period from now. There is no free trial: a newly
/// registered agent is inactive until its first payment.
///
/// Hosting is Orvyn's only charge here: agents keep all of their token tax income. Collected
/// subscription revenue leaves only through the owner's withdraw.
///
/// Subscriptions paid off chain through Binance Pay are credited by a creditor (a backend key the
/// owner appoints, separate from operators) once Binance Pay confirms the order. Each order ref
/// credits once, and the payment is recorded like any other (token = BINANCE_PAY, amount = USD).
///
/// Hosting comes in tiers: Basic (0), Pro (1) and Studio (2). A token's `monthlyPrice` is the
/// Basic price; a higher tier costs `tierBps` of it (Pro 3x and Studio 7.5x at launch: $20, $60,
/// $150). An agent's tier gates which jobs it can take, so it is kept here where anyone can read
/// it. Changing tier converts the time already paid at the ratio of the two tier prices.
///
/// For agents Orvyn hosts, an operator also records `environmentHash`: the keccak256 of the
/// environment record (hardware, runtime, tier) published with the agent's metadata, so anyone
/// can check that the published record is the one Orvyn attested.
///
/// Upgradeable (UUPS) by the owner, keeping all state.
contract OrvynRegistry is Initializable, UUPSUpgradeable, Ownable2StepUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @notice Payment "token" meaning native BNB.
    address public constant NATIVE = address(0);
    uint64 public constant MONTH = 30 days;
    uint256 public constant MAX_MONTHS = 36;
    /// @notice Payment "token" recorded for subscriptions paid through Binance Pay (off chain).
    address public constant BINANCE_PAY = address(0xB1A9CE);
    uint8 public constant BASIC = 0;
    uint8 public constant PRO = 1;
    uint8 public constant STUDIO = 2;

    struct Agent {
        address owner; // the human who created the agent
        address agentWallet; // the agent's own wallet (autopay pays from here)
        uint64 paidUntil;
        uint64 registeredAt;
        uint32 payments;
    }

    /// One subscription payment, kept on chain so invoices and receipts can be rebuilt from the
    /// registry alone.
    struct Payment {
        address payer;
        address token;
        uint256 amount; // credited (any remainder was refunded or never taken)
        uint32 months;
        uint64 periodStart; // the period bought: [periodStart, paidUntil)
        uint64 paidUntil;
        uint64 paidAt;
        uint64 blockNumber;
    }

    struct AgentView {
        string agentId;
        address owner;
        address agentWallet;
        uint64 paidUntil;
        uint64 registeredAt;
        uint32 payments;
        bool active;
        uint8 tier;
        bytes32 environmentHash;
    }

    struct TokenPrice {
        address token;
        uint256 monthlyPrice;
    }

    // ---------- Storage (append only) ----------

    EnumerableSet.AddressSet private _tokens;
    mapping(address token => uint256) public monthlyPrice;
    EnumerableSet.AddressSet private _operators;
    mapping(bytes32 agentKey => Agent) private _agents;
    mapping(bytes32 agentKey => string) private _agentIds;
    mapping(bytes32 agentKey => mapping(uint256 index => Payment)) private _payments;
    mapping(bytes32 agentKey => mapping(address token => uint256)) public totalPaid;
    /// Subscription revenue collected and not yet withdrawn, per token.
    mapping(address token => uint256) public revenue;

    /// Binance Pay order refs already credited (each credits once).
    mapping(bytes32 ref => bool) public externalRefs;
    EnumerableSet.AddressSet private _creditors;

    /// Price of a tier as basis points of the Basic price (tier 0 is always 10000; 0 = not offered).
    mapping(uint8 tier => uint32) private _tierBps;
    mapping(bytes32 agentKey => uint8) private _agentTier;
    /// keccak256 of the hosted environment record an operator attested for the agent.
    mapping(bytes32 agentKey => bytes32) public environmentHash;

    uint256[36] private __gap;

    // ---------- Events ----------

    event AgentRegistered(bytes32 indexed agentKey, string agentId, address indexed owner, address agentWallet, uint64 paidUntil);
    event SubscriptionPaid(
        bytes32 indexed agentKey,
        string agentId,
        uint256 paymentIndex,
        address indexed payer,
        address indexed token,
        uint256 amount,
        uint32 months,
        uint64 periodStart,
        uint64 paidUntil
    );
    event DaysGranted(bytes32 indexed agentKey, string agentId, uint32 days_, uint64 paidUntil);
    event RevenueWithdrawn(address indexed token, uint256 amount, address indexed receiver);
    event PriceSet(address indexed token, uint256 monthlyPrice);
    event TokenRemoved(address indexed token);
    event OperatorSet(address indexed account, bool enabled);
    event CreditorSet(address indexed account, bool enabled);
    event ExternalPaymentCredited(bytes32 indexed agentKey, bytes32 indexed ref, uint32 months, uint256 usdAmount);
    event TierPriceSet(uint8 indexed tier, uint32 bps);
    event TierChanged(bytes32 indexed agentKey, string agentId, uint8 fromTier, uint8 toTier, uint64 paidUntil);
    event EnvironmentAttested(bytes32 indexed agentKey, string agentId, bytes32 environmentHash);

    // ---------- Errors ----------

    error NotOperator();
    error ZeroAddress();
    error ZeroPrice();
    error TokenNotAccepted();
    error UnknownAgent();
    error AgentExists();
    error LessThanOneMonth();
    error UnexpectedValue();
    error ExceedsCollected();
    error TransferFailed();
    error ReceivedLess();
    error NotCreditor();
    error RefUsed();
    error BadMonths();
    error TierUnavailable();
    error SameTier();
    error NotAgentOwner();

    // ---------- Init / upgrades ----------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_) external initializer {
        if (owner_ == address(0)) revert ZeroAddress();
        __Ownable_init(owner_);
        __Ownable2Step_init();
        __ReentrancyGuard_init();
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    /// @notice The deployed code's version, to confirm an upgrade.
    function version() external pure virtual returns (string memory) {
        return "1.1.0";
    }

    // ---------- Admin ----------

    modifier onlyOperator() {
        if (!_operators.contains(msg.sender) && msg.sender != owner()) revert NotOperator();
        _;
    }

    /// @notice Accept `token` (NATIVE for BNB) at `price` base units per month.
    function setPrice(address token, uint256 price) external onlyOwner {
        if (price == 0) revert ZeroPrice();
        _tokens.add(token);
        monthlyPrice[token] = price;
        emit PriceSet(token, price);
    }

    /// @notice Price tier `tier` (1 Pro, 2 Studio) at `bps` basis points of the Basic price; 0 stops
    /// offering it (agents already on it keep it, but can't pay for more time on it).
    function setTierPrice(uint8 tier, uint32 bps) external onlyOwner {
        if (tier == 0 || tier > STUDIO) revert TierUnavailable();
        if (bps != 0 && bps < 10000) revert ZeroPrice(); // a higher tier never costs less than Basic
        _tierBps[tier] = bps;
        emit TierPriceSet(tier, bps);
    }

    function removeToken(address token) external onlyOwner {
        _tokens.remove(token);
        delete monthlyPrice[token];
        emit TokenRemoved(token);
    }

    function addOperator(address account) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        _operators.add(account);
        emit OperatorSet(account, true);
    }

    function removeOperator(address account) external onlyOwner {
        _operators.remove(account);
        emit OperatorSet(account, false);
    }

    function addCreditor(address account) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        _creditors.add(account);
        emit CreditorSet(account, true);
    }

    function removeCreditor(address account) external onlyOwner {
        _creditors.remove(account);
        emit CreditorSet(account, false);
    }

    /// @notice Credit free days (promotions, support refunds).
    function grantDays(string calldata agentId, uint32 days_) external onlyOwner {
        bytes32 k = OrvynIds.key(agentId);
        Agent storage a = _agent(k);
        uint64 base = _max(a.paidUntil, uint64(block.timestamp));
        a.paidUntil = base + uint64(days_) * 1 days;
        emit DaysGranted(k, agentId, days_, a.paidUntil);
    }

    /// @notice Send collected subscription revenue in `token` (NATIVE for BNB) to `receiver`.
    function withdraw(address token, uint256 amount, address receiver) external onlyOwner nonReentrant {
        if (receiver == address(0)) revert ZeroAddress();
        if (amount == 0 || amount > revenue[token]) revert ExceedsCollected();
        revenue[token] -= amount;
        emit RevenueWithdrawn(token, amount, receiver);
        _send(token, receiver, amount);
    }

    // ---------- Registration ----------

    /// @notice Register an agent. Operators only (the Orvyn backend, when an agent is created). It
    /// starts unpaid: hosting begins with the first payment.
    function registerAgent(string calldata agentId, address owner_, address agentWallet)
        external
        onlyOperator
        returns (AgentView memory)
    {
        bytes32 k = OrvynIds.check(agentId);
        if (_agents[k].registeredAt != 0) revert AgentExists();
        if (owner_ == address(0) || agentWallet == address(0)) revert ZeroAddress();
        uint64 now_ = uint64(block.timestamp);
        Agent storage a = _agents[k];
        a.owner = owner_;
        a.agentWallet = agentWallet;
        a.registeredAt = now_;
        a.paidUntil = now_;
        _agentIds[k] = agentId;
        emit AgentRegistered(k, agentId, owner_, agentWallet, a.paidUntil);
        return _view(k);
    }

    // ---------- Subscriptions ----------

    /// @notice Pay `agentId`'s subscription. For BNB pass `token = NATIVE` and send the BNB
    /// (`amount` is ignored; the unused remainder is refunded). For a token, approve this
    /// contract first; only whole months, up to `amount`, are taken.
    /// @return months Months credited. @return used Amount taken.
    function pay(string calldata agentId, address token, uint256 amount)
        external
        payable
        nonReentrant
        returns (uint32 months, uint256 used)
    {
        bytes32 k = OrvynIds.key(agentId);
        uint256 price = priceFor(_agentTier[k], token);
        if (price == 0) revert TokenNotAccepted();
        if (token == NATIVE) amount = msg.value;
        else if (msg.value != 0) revert UnexpectedValue();

        uint256 m = amount / price;
        if (m > MAX_MONTHS) m = MAX_MONTHS;
        if (m == 0) revert LessThanOneMonth();
        months = uint32(m);
        used = m * price;

        _credit(k, agentId, token, used, months);
        revenue[token] += used;

        if (token == NATIVE) {
            if (amount > used) _send(NATIVE, msg.sender, amount - used);
        } else {
            _pull(token, msg.sender, used);
        }
    }

    /// @notice Credit `months` paid off chain through Binance Pay. Creditors only; `ref` is the
    /// Binance Pay order (keccak256 of its merchantTradeNo) and credits once. `usdAmount` (18
    /// decimals) is recorded for invoices; no funds move on chain.
    function creditExternal(string calldata agentId, uint32 months, bytes32 ref, uint256 usdAmount)
        external
        nonReentrant
    {
        if (!_creditors.contains(msg.sender)) revert NotCreditor();
        if (months == 0 || months > MAX_MONTHS) revert BadMonths();
        if (externalRefs[ref]) revert RefUsed();
        externalRefs[ref] = true;

        bytes32 k = OrvynIds.key(agentId);
        _credit(k, agentId, BINANCE_PAY, usdAmount, months);
        emit ExternalPaymentCredited(k, ref, months, usdAmount);
    }

    // ---------- Tiers and environment ----------

    /// @notice Move `agentId` to `newTier`. Its owner or an operator. Time already paid is
    /// converted at the ratio of the two tier prices (an upgrade shortens it, a downgrade
    /// lengthens it), so no payment is lost and none is needed to switch.
    function changeTier(string calldata agentId, uint8 newTier) external returns (uint64 paidUntil) {
        bytes32 k = OrvynIds.key(agentId);
        Agent storage a = _agent(k);
        if (msg.sender != a.owner && !_operators.contains(msg.sender) && msg.sender != owner()) revert NotAgentOwner();
        uint8 old = _agentTier[k];
        if (newTier == old) revert SameTier();
        uint256 toBps = tierBps(newTier);
        if (toBps == 0) revert TierUnavailable();
        uint64 now_ = uint64(block.timestamp);
        if (a.paidUntil > now_) {
            uint256 left = uint256(a.paidUntil - now_) * tierBps(old) / toBps;
            a.paidUntil = now_ + uint64(left);
        }
        _agentTier[k] = newTier;
        emit TierChanged(k, agentId, old, newTier, a.paidUntil);
        return a.paidUntil;
    }

    /// @notice Record the keccak256 of the agent's hosted environment record. Operators only:
    /// Orvyn attests the environments it runs. Self-hosted environments are self-reported off chain.
    function attestEnvironment(string calldata agentId, bytes32 hash) external onlyOperator {
        bytes32 k = OrvynIds.key(agentId);
        _agent(k);
        environmentHash[k] = hash;
        emit EnvironmentAttested(k, agentId, hash);
    }

    /// @notice A tier's price as basis points of the Basic price (0 = not offered).
    function tierBps(uint8 tier) public view returns (uint256) {
        if (tier == BASIC) return 10000;
        if (tier > STUDIO) return 0;
        return _tierBps[tier];
    }

    /// @notice One month of `tier` in `token` (0 = not payable).
    function priceFor(uint8 tier, address token) public view returns (uint256) {
        return monthlyPrice[token] * tierBps(tier) / 10000;
    }

    function tierOf(string calldata agentId) external view returns (uint8) {
        return _agentTier[OrvynIds.key(agentId)];
    }

    // ---------- Views ----------

    function getAgent(string calldata agentId) external view returns (bool found, AgentView memory agent) {
        bytes32 k = OrvynIds.key(agentId);
        if (_agents[k].registeredAt == 0) return (false, agent);
        return (true, _view(k));
    }

    function isActive(string calldata agentId) external view returns (bool) {
        return _agents[OrvynIds.key(agentId)].paidUntil > block.timestamp;
    }

    /// @notice An agent's payments, oldest first, from `from` (at most 100 per call).
    function getPayments(string calldata agentId, uint256 from, uint256 limit)
        external
        view
        returns (Payment[] memory page)
    {
        bytes32 k = OrvynIds.key(agentId);
        uint256 count = _agents[k].payments;
        if (limit > 100) limit = 100;
        uint256 end = from + limit < count ? from + limit : count;
        if (from >= end) return new Payment[](0);
        page = new Payment[](end - from);
        for (uint256 i = from; i < end; ++i) {
            page[i - from] = _payments[k][i];
        }
    }

    function getPrices() external view returns (TokenPrice[] memory prices) {
        uint256 n = _tokens.length();
        prices = new TokenPrice[](n);
        for (uint256 i; i < n; ++i) {
            address t = _tokens.at(i);
            prices[i] = TokenPrice(t, monthlyPrice[t]);
        }
    }

    function isOperator(address account) external view returns (bool) {
        return _operators.contains(account);
    }

    function operators() external view returns (address[] memory) {
        return _operators.values();
    }

    function isCreditor(address account) external view returns (bool) {
        return _creditors.contains(account);
    }

    // ---------- Internal ----------

    function _agent(bytes32 k) private view returns (Agent storage a) {
        a = _agents[k];
        if (a.registeredAt == 0) revert UnknownAgent();
    }

    function _view(bytes32 k) private view returns (AgentView memory) {
        Agent storage a = _agents[k];
        return AgentView({
            agentId: _agentIds[k],
            owner: a.owner,
            agentWallet: a.agentWallet,
            paidUntil: a.paidUntil,
            registeredAt: a.registeredAt,
            payments: a.payments,
            active: a.paidUntil > block.timestamp,
            tier: _agentTier[k],
            environmentHash: environmentHash[k]
        });
    }

    /// Pulls exactly `amount` of `token`; rejects fee-on-transfer tokens.
    function _pull(address token, address from, uint256 amount) private {
        uint256 before = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(from, address(this), amount);
        if (IERC20(token).balanceOf(address(this)) - before != amount) revert ReceivedLess();
    }

    function _send(address token, address to, uint256 amount) private {
        if (token == NATIVE) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    /// Add `months` to the agent's paid period (from now if it has lapsed, else from its end), record
    /// the payment and emit SubscriptionPaid. Shared by on-chain payments and Binance Pay credits.
    function _credit(bytes32 k, string calldata agentId, address token, uint256 amount, uint32 months) private {
        Agent storage a = _agent(k);
        uint64 start = _max(a.paidUntil, uint64(block.timestamp));
        uint64 until = start + uint64(months) * MONTH;
        a.paidUntil = until;
        uint256 index = a.payments;
        a.payments += 1;
        totalPaid[k][token] += amount;
        _payments[k][index] = Payment({
            payer: msg.sender,
            token: token,
            amount: amount,
            months: months,
            periodStart: start,
            paidUntil: until,
            paidAt: uint64(block.timestamp),
            blockNumber: uint64(block.number)
        });
        emit SubscriptionPaid(k, agentId, index, msg.sender, token, amount, months, start, until);
    }

    function _max(uint64 a, uint64 b) private pure returns (uint64) {
        return a > b ? a : b;
    }
}
