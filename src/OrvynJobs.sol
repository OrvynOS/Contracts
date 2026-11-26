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

/// @title Orvyn jobs escrow (BNB Smart Chain)
/// @notice A client hires an Orvyn agent for a one-off task by funding a job here in USDT, USDC or
/// BNB. The money stays in this contract until the job ends:
///
/// - Approve: the client approves at any time and the payee (the agent's wallet) is paid, minus
///   Orvyn's fee.
/// - Release: once the agent has delivered, the client has a review window to approve or dispute.
///   After it, anyone can call `release` and the payee is paid.
/// - Refund: the payee or Orvyn's operator can refund the client in full at any time before payout.
///   The operator can never pay anyone but the client.
/// - Reclaim: if nothing was delivered by the deadline, the client takes the money back.
/// - Dispute: within the review window the client can dispute; the owner then splits the amount
///   between payee and client (`resolve`).
///
/// The fee and review window are snapshotted into each job when it's funded. Every state change is
/// final before any transfer goes out. A payout that fails (a reverting receiver, a blocklisted
/// address) is kept as `owed` and withdrawn by the receiver later.
///
/// Upgradeable (UUPS) by the owner, keeping all state.
contract OrvynJobs is Initializable, UUPSUpgradeable, Ownable2StepUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    address public constant NATIVE = address(0);
    uint16 public constant MAX_FEE_BPS = 2_000;
    uint256 public constant BPS = 10_000;
    uint64 public constant MIN_DEADLINE = 1 hours;
    uint64 public constant MAX_DEADLINE = 30 days;
    uint256 public constant MAX_REASON = 1_000;

    enum Status {
        None,
        Funded, // paid in, work in progress
        Delivered, // the agent delivered; the review window is running
        Disputed, // disputed within the review window; the owner resolves it
        Released, // paid out to the payee
        Refunded, // returned to the client in full
        Resolved // a dispute the owner split
    }

    struct Job {
        address client;
        address payee; // the agent's own wallet
        address token; // NATIVE for BNB
        uint16 feeBps; // as it was when funded
        Status status;
        uint64 reviewPeriod; // seconds, as it was when funded
        uint64 fundedAt;
        uint64 deadline;
        uint64 deliveredAt;
        uint256 amount;
        uint256 paidToPayee;
        uint256 refunded;
        uint256 fee;
        bytes32 resultHash; // sha256 of the delivered result
        string agentId;
    }

    // ---------- Storage (append only) ----------

    EnumerableSet.AddressSet private _operators;
    EnumerableSet.AddressSet private _tokens;
    /// Smallest job per accepted token, in its base units (stops dust jobs).
    mapping(address token => uint256) public minAmount;
    uint16 public feeBps;
    uint64 public reviewPeriod;
    mapping(bytes32 jobKey => Job) private _jobs;
    /// Orvyn's fees collected and not yet withdrawn, per token.
    mapping(address token => uint256) public fees;
    /// Payouts that couldn't be delivered, per receiver and token.
    mapping(address account => mapping(address token => uint256)) public owed;
    /// Money held for open jobs plus owed payouts, per token (never withdrawable as fees).
    mapping(address token => uint256) public held;

    uint256[40] private __gap;

    // ---------- Events ----------

    event JobFunded(
        bytes32 indexed jobKey,
        string jobId,
        string agentId,
        address indexed client,
        address indexed payee,
        address token,
        uint256 amount,
        uint16 feeBps,
        uint64 deadline
    );
    event JobDelivered(bytes32 indexed jobKey, bytes32 resultHash, uint64 reviewEnds);
    event JobDisputed(bytes32 indexed jobKey, string reason);
    event JobSettled(
        bytes32 indexed jobKey, Status status, string reason, address token, uint256 toPayee, uint256 toClient, uint256 fee
    );
    event PayoutOwed(address indexed account, address indexed token, uint256 amount);
    event OwedWithdrawn(address indexed account, address indexed token, uint256 amount);
    event FeesWithdrawn(address indexed token, uint256 amount, address indexed receiver);
    event TokenSet(address indexed token, uint256 minAmount);
    event TokenRemoved(address indexed token);
    event OperatorSet(address indexed account, bool enabled);
    event FeeBpsSet(uint16 feeBps);
    event ReviewPeriodSet(uint64 reviewPeriod);

    // ---------- Errors ----------

    error ZeroAddress();
    error FeeTooHigh();
    error BadReviewWindow();
    error TokenNotAccepted();
    error JobExists();
    error UnknownJob();
    error BelowMinimum();
    error PayeeIsClient();
    error BadDeadline();
    error BadValue();
    error ReceivedLess();
    error NotAgentOrOperator();
    error NotClient();
    error WrongStatus();
    error ReviewWindowOpen();
    error ReviewWindowEnded();
    error DeadlineNotPassed();
    error EmptyResult();
    error ReasonTooLong();
    error BadSplit();
    error NothingOwed();
    error ExceedsCollected();
    error TransferFailed();

    // ---------- Init / upgrades ----------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_, uint16 feeBps_, uint32 reviewHours) external initializer {
        if (owner_ == address(0)) revert ZeroAddress();
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        if (reviewHours == 0 || reviewHours > 336) revert BadReviewWindow();
        __Ownable_init(owner_);
        __Ownable2Step_init();
        __ReentrancyGuard_init();
        feeBps = feeBps_;
        reviewPeriod = uint64(reviewHours) * 1 hours;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function version() external pure virtual returns (string memory) {
        return "1.0.0";
    }

    // ---------- Admin ----------

    function _isOperatorOrOwner(address account) private view returns (bool) {
        return _operators.contains(account) || account == owner();
    }

    /// @notice Accept `token` (NATIVE for BNB) with a minimum job size in its base units.
    function setToken(address token, uint256 minAmount_) external onlyOwner {
        _tokens.add(token);
        minAmount[token] = minAmount_;
        emit TokenSet(token, minAmount_);
    }

    function removeToken(address token) external onlyOwner {
        _tokens.remove(token);
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

    /// @notice Applies to jobs funded from now on.
    function setFeeBps(uint16 feeBps_) external onlyOwner {
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        feeBps = feeBps_;
        emit FeeBpsSet(feeBps_);
    }

    /// @notice Applies to jobs funded from now on.
    function setReviewHours(uint32 reviewHours) external onlyOwner {
        if (reviewHours == 0 || reviewHours > 336) revert BadReviewWindow();
        reviewPeriod = uint64(reviewHours) * 1 hours;
        emit ReviewPeriodSet(reviewPeriod);
    }

    /// @notice Send collected fees in `token` to `receiver`. Only fees, never money held for jobs.
    function withdrawFees(address token, uint256 amount, address receiver) external onlyOwner nonReentrant {
        if (receiver == address(0)) revert ZeroAddress();
        if (amount == 0 || amount > fees[token]) revert ExceedsCollected();
        fees[token] -= amount;
        emit FeesWithdrawn(token, amount, receiver);
        if (!_trySend(token, receiver, amount)) revert TransferFailed();
    }

    // ---------- Funding ----------

    /// @notice Fund a job. For BNB pass `token = NATIVE` and send exactly `amount`; for a token,
    /// approve this contract for `amount` first. `deadline` is a unix time 1 hour to 30 days away.
    function fund(
        string calldata jobId,
        string calldata agentId,
        address payee,
        address token,
        uint256 amount,
        uint64 deadline
    ) external payable nonReentrant {
        if (!_tokens.contains(token)) revert TokenNotAccepted();
        bytes32 k = OrvynIds.check(jobId);
        OrvynIds.check(agentId);
        if (_jobs[k].status != Status.None) revert JobExists();
        if (amount == 0 || amount < minAmount[token]) revert BelowMinimum();
        if (payee == address(0)) revert ZeroAddress();
        if (payee == msg.sender) revert PayeeIsClient();
        uint64 now_ = uint64(block.timestamp);
        if (deadline < now_ + MIN_DEADLINE || deadline > now_ + MAX_DEADLINE) revert BadDeadline();

        if (token == NATIVE) {
            if (msg.value != amount) revert BadValue();
        } else {
            if (msg.value != 0) revert BadValue();
            uint256 before = IERC20(token).balanceOf(address(this));
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
            if (IERC20(token).balanceOf(address(this)) - before != amount) revert ReceivedLess();
        }

        Job storage j = _jobs[k];
        j.client = msg.sender;
        j.payee = payee;
        j.token = token;
        j.feeBps = feeBps;
        j.status = Status.Funded;
        j.reviewPeriod = reviewPeriod;
        j.fundedAt = now_;
        j.deadline = deadline;
        j.amount = amount;
        j.agentId = agentId;
        held[token] += amount;
        emit JobFunded(k, jobId, agentId, msg.sender, payee, token, amount, j.feeBps, deadline);
    }

    // ---------- Lifecycle ----------

    /// @notice The agent delivered. Its own wallet or an operator; starts the client's review window.
    function markDelivered(string calldata jobId, bytes32 resultHash) external {
        bytes32 k = OrvynIds.key(jobId);
        Job storage j = _job(k);
        if (msg.sender != j.payee && !_isOperatorOrOwner(msg.sender)) revert NotAgentOrOperator();
        if (j.status != Status.Funded) revert WrongStatus();
        if (resultHash == bytes32(0)) revert EmptyResult();
        j.status = Status.Delivered;
        j.deliveredAt = uint64(block.timestamp);
        j.resultHash = resultHash;
        emit JobDelivered(k, resultHash, j.deliveredAt + j.reviewPeriod);
    }

    /// @notice The client approves the work: the payee is paid now.
    function approve(string calldata jobId) external nonReentrant {
        bytes32 k = OrvynIds.key(jobId);
        Job storage j = _job(k);
        if (msg.sender != j.client) revert NotClient();
        if (j.status != Status.Funded && j.status != Status.Delivered) revert WrongStatus();
        _settle(k, j, BPS, Status.Released, "approved");
    }

    /// @notice Anyone: pay the payee once a delivered job's review window has passed undisputed.
    function release(string calldata jobId) external nonReentrant {
        bytes32 k = OrvynIds.key(jobId);
        Job storage j = _job(k);
        if (j.status != Status.Delivered) revert WrongStatus();
        if (block.timestamp < j.deliveredAt + j.reviewPeriod) revert ReviewWindowOpen();
        _settle(k, j, BPS, Status.Released, "review window passed");
    }

    /// @notice The client disputes a delivery within the review window.
    function dispute(string calldata jobId, string calldata reason) external {
        bytes32 k = OrvynIds.key(jobId);
        Job storage j = _job(k);
        if (msg.sender != j.client) revert NotClient();
        if (j.status != Status.Delivered) revert WrongStatus();
        if (block.timestamp >= j.deliveredAt + j.reviewPeriod) revert ReviewWindowEnded();
        if (bytes(reason).length > MAX_REASON) revert ReasonTooLong();
        j.status = Status.Disputed;
        emit JobDisputed(k, reason);
    }

    /// @notice The payee or an operator refunds the client in full, before payout.
    function refund(string calldata jobId) external nonReentrant {
        bytes32 k = OrvynIds.key(jobId);
        Job storage j = _job(k);
        if (msg.sender != j.payee && !_isOperatorOrOwner(msg.sender)) revert NotAgentOrOperator();
        if (j.status != Status.Funded && j.status != Status.Delivered && j.status != Status.Disputed) {
            revert WrongStatus();
        }
        _settle(k, j, 0, Status.Refunded, "refunded");
    }

    /// @notice The client takes the money back when nothing was delivered by the deadline.
    function reclaim(string calldata jobId) external nonReentrant {
        bytes32 k = OrvynIds.key(jobId);
        Job storage j = _job(k);
        if (msg.sender != j.client) revert NotClient();
        if (j.status != Status.Funded) revert WrongStatus();
        if (block.timestamp <= j.deadline) revert DeadlineNotPassed();
        _settle(k, j, 0, Status.Refunded, "deadline passed without delivery");
    }

    /// @notice Owner: settle a disputed job, `payeeBps` of it to the payee (the fee applies to
    /// that share) and the rest back to the client.
    function resolve(string calldata jobId, uint16 payeeBps) external onlyOwner nonReentrant {
        bytes32 k = OrvynIds.key(jobId);
        Job storage j = _job(k);
        if (j.status != Status.Disputed) revert WrongStatus();
        if (payeeBps > BPS) revert BadSplit();
        _settle(k, j, payeeBps, Status.Resolved, "dispute resolved");
    }

    /// @notice Withdraw a payout that couldn't be delivered earlier.
    function withdrawOwed(address token) external nonReentrant {
        uint256 amount = owed[msg.sender][token];
        if (amount == 0) revert NothingOwed();
        owed[msg.sender][token] = 0;
        held[token] -= amount;
        emit OwedWithdrawn(msg.sender, token, amount);
        if (!_trySend(token, msg.sender, amount)) revert TransferFailed();
    }

    // ---------- Views ----------

    function getJob(string calldata jobId) external view returns (Job memory job, uint64 reviewEnds) {
        job = _jobs[OrvynIds.key(jobId)];
        if (job.deliveredAt != 0) reviewEnds = job.deliveredAt + job.reviewPeriod;
    }

    function tokens() external view returns (address[] memory) {
        return _tokens.values();
    }

    function isOperator(address account) external view returns (bool) {
        return _operators.contains(account);
    }

    // ---------- Internal ----------

    function _job(bytes32 k) private view returns (Job storage j) {
        j = _jobs[k];
        if (j.status == Status.None) revert UnknownJob();
    }

    /// Pays `payeeBps` of the job to the payee (minus the fee) and the rest to the client.
    /// State is final before any transfer goes out.
    function _settle(bytes32 k, Job storage j, uint256 payeeBps, Status status, string memory why) private {
        uint256 amount = j.amount;
        uint256 toPayeeGross = amount * payeeBps / BPS;
        uint256 fee = toPayeeGross * j.feeBps / BPS;
        uint256 toPayee = toPayeeGross - fee;
        uint256 toClient = amount - toPayeeGross;
        address token = j.token;

        j.status = status;
        j.paidToPayee = toPayee;
        j.refunded = toClient;
        j.fee = fee;
        held[token] -= amount;
        fees[token] += fee;
        emit JobSettled(k, status, why, token, toPayee, toClient, fee);

        _payOrOwe(token, j.payee, toPayee);
        _payOrOwe(token, j.client, toClient);
    }

    function _payOrOwe(address token, address to, uint256 amount) private {
        if (amount == 0) return;
        if (_trySend(token, to, amount)) return;
        owed[to][token] += amount;
        held[token] += amount;
        emit PayoutOwed(to, token, amount);
    }

    /// Sends without reverting; false if the transfer failed.
    function _trySend(address token, address to, uint256 amount) private returns (bool) {
        if (token == NATIVE) {
            (bool ok,) = to.call{value: amount}("");
            return ok;
        }
        (bool success, bytes memory data) = token.call(abi.encodeCall(IERC20.transfer, (to, amount)));
        return success && (data.length == 0 ? token.code.length > 0 : abi.decode(data, (bool)));
    }
}
