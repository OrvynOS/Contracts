// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {BLS12381} from "./BLS12381.sol";

/// @notice Contracts that request randomness implement this to receive it (see OrvynRNGConsumerBase).
interface IOrvynRNGConsumer {
    function rawFulfillRandomness(uint256 requestId, bytes32 randomness) external;
}

/// @title Orvyn RNG on chain
/// @notice Verifiable randomness from Orvyn's agent network, verified entirely on chain, paid for
/// from prepaid subscriptions, with the fees earned by the agents that produce each round.
///
/// Rounds. Each minute is a round. Agents (nodes) sign "orvyn-rng:v1:<round>" with BLS12-381 keys
/// registered here. After the round closes, the committer fixes the participating set and their
/// aggregate signature on chain *before* the round's drand beacon exists; once drand publishes it,
/// anyone can fulfil the round. The contract checks the aggregate signature against the
/// participants' registered keys and drand's signature against drand quicknet's key, and derives
///
///   output = sha256("orvyn-rng:v1" || round (8 bytes) || compressed aggregate (48) || sha256(drand sig))
///
/// Nobody can steer the output: participants are fixed while drand's value is still unknown, BLS
/// signatures are unique, and drand is unknown to everyone until published. The committer is
/// trusted for liveness only (it could fail to commit), never for the value.
///
/// Payments. Developers prepay BNB into a subscription and list the consumer contracts allowed to
/// use it. Each request costs `baseFee + callbackGasLimit * callbackFeePerGas`, taken from the
/// subscription into the round's escrow. When the round is fulfilled the base fees are split:
/// `nodesBps` equally among the round's participants (paid to each node's payee: the agent's
/// wallet), `fulfillerBps` to whoever fulfilled it (their gas), the rest to the protocol treasury.
/// The callback fee goes to whoever delivers the callback. Unfulfilled requests are refundable to
/// the subscription after REFUND_DELAY. Earnings are pulled with `withdraw` / `withdrawFor`.
///
/// Staking and slashing. Each node stakes BNB to register (so fee-sharing can't be farmed with
/// free keys). A node's stake is slashed, in full, on proof of a fault anyone can check on chain:
/// its valid signature for a round that hasn't started yet (it pre-signed, or let its key out).
/// The same applies to two different price reports signed for the same feed and round (OrvynPriceFeed):
/// an honest node signs one report per feed and round.
/// The reporter gets `slashReporterBps` of the stake, the treasury the rest. Nobody, including the
/// owner, can slash without that proof. Leaving takes UNBONDING: the node stops counting in new
/// rounds at once, stays slashable, and its stake returns to its payee afterwards.
contract OrvynRNG is Ownable2Step, ReentrancyGuard {
    // ---------- Protocol constants (match crates/core/src/rng) ----------

    uint256 public constant PERIOD = 60;
    uint256 public constant CLOSE_AFTER = 50;
    /// Seconds after the close during which the participant set must be committed.
    uint256 public constant COMMIT_WINDOW = 20;
    uint256 public constant DRAND_GENESIS = 1692803367;
    uint256 public constant DRAND_PERIOD = 3;
    bytes public constant DRAND_PUBLIC_KEY = hex"000000000000000000000000000000000d1fec758c921cc22b0e17e63aaf4bcb5ed66304de9cf809bd274ca73bab4af5a6e9c76a4bc09e76eae8991ef5ece45a0000000000000000000000000000000003cf0f2896adee7eb8b5f01fcad3912212c437e0073e911fb90022d3e760183c8c4b450b6a0a6c3ac6a5776a2d106451000000000000000000000000000000000e5db2b6bfbb01c867749cadffca88b36c24f3012ba09fc4d3022c5c37dce0f977d3adb5d183c7477c442b1f045152730000000000000000000000000000000001a714f2edb74119a2f2b0d5a7c75ba902d163700a61bc224ededd8e63aef7be1aaf8e93d7a9718b047ccddb3eb5d68b";

    bytes private constant DST_SIG = "BLS_SIG_BLS12381G1_XMD:SHA-256_SSWU_RO_POP_";
    bytes private constant DST_POP = "BLS_POP_BLS12381G1_XMD:SHA-256_SSWU_RO_POP_";
    bytes private constant DST_DRAND = "BLS_SIG_BLS12381G1_XMD:SHA-256_SSWU_RO_NUL_";
    uint256 public constant MAX_CALLBACK_GAS = 2_000_000;
    uint256 public constant MAX_CONSUMERS = 100;
    uint256 public constant REFUND_DELAY = 1 hours;
    uint256 private constant DELIVER_PER_FULFIL = 20;
    uint256 public constant UNBONDING = 7 days;

    // ---------- Nodes ----------

    struct Node {
        bytes32 keyHash; // keccak256 of the 256-byte EIP-2537 public key
        address payee; // where its earnings go (the agent's wallet)
        uint64 payeeNonce;
        uint64 roundsSigned;
        uint128 stake;
        uint64 exitAt; // when it asked to leave (0: active)
        bool slashed;
    }

    Node[] public nodes;
    mapping(bytes32 keyHash => bool) public isNode;

    // ---------- Rounds ----------

    mapping(uint64 round => bytes32) public commitment;
    mapping(uint64 round => bytes32) public randomness;
    /// Base fees of a round's requests, split at fulfilment.
    mapping(uint64 round => uint256) public roundEscrow;
    /// The split each round pays out with, fixed by its first request (config changes apply to later rounds).
    struct Split {
        uint16 nodesBps;
        uint16 fulfillerBps;
        bool set;
    }

    mapping(uint64 round => Split) public roundSplit;

    address public committer;
    uint16 public minParticipants;
    uint256 public minStake = 0.1 ether;
    uint16 public slashReporterBps = 5000;

    // ---------- Fees and earnings ----------

    uint256 public baseFee;
    uint256 public callbackFeePerGas;
    uint16 public nodesBps;
    uint16 public fulfillerBps;
    address public treasury;
    /// BNB owed to payees, fulfillers and the treasury.
    mapping(address account => uint256) public earnings;
    uint256 public totalEarnings;

    // ---------- Subscriptions ----------

    struct Subscription {
        address owner;
        uint256 balance;
        uint32 consumers;
    }

    mapping(uint256 subId => Subscription) public subscriptions;
    mapping(uint256 subId => mapping(address consumer => bool)) public isConsumer;
    uint256 public nextSubId = 1;

    // ---------- Requests ----------

    enum Status {
        None,
        Pending,
        Delivered,
        Refunded
    }

    struct Request {
        address consumer;
        uint64 round;
        uint32 callbackGasLimit;
        uint256 subId;
        uint128 baseFee;
        uint128 callbackFee;
        Status status;
    }

    mapping(uint256 requestId => Request) public requests;
    mapping(uint64 round => uint256[]) private _roundRequests;
    mapping(uint64 round => uint256) public deliveredUpTo;
    uint256 public nextRequestId = 1;

    // ---------- Events and errors ----------

    event NodeRegistered(uint256 indexed index, address indexed payee, bytes publicKey);
    event PayeeChanged(uint256 indexed index, address payee);
    event NodeExiting(uint256 indexed index, uint256 stakeReturnsAt);
    event StakeWithdrawn(uint256 indexed index, address payee, uint256 amount);
    event NodeSlashed(uint256 indexed index, address indexed reporter, uint64 round, uint256 amount);
    event StakingSet(uint256 minStake, uint16 slashReporterBps);
    event RoundCommitted(uint64 indexed round, bytes32 commitment);
    event RoundFulfilled(uint64 indexed round, bytes32 output, uint256 participants, uint256 paidToNodes);
    event SubscriptionCreated(uint256 indexed subId, address indexed owner);
    event SubscriptionFunded(uint256 indexed subId, address indexed from, uint256 amount);
    event ConsumerSet(uint256 indexed subId, address indexed consumer, bool allowed);
    event SubscriptionClosed(uint256 indexed subId, address to, uint256 amount);
    event RandomnessRequested(uint256 indexed requestId, uint256 indexed subId, address indexed consumer, uint64 round, uint256 fee);
    event RandomnessDelivered(uint256 indexed requestId, bytes32 randomness, bool success);
    event RequestRefunded(uint256 indexed requestId, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount);
    event ConfigSet(address committer, uint16 minParticipants, uint256 baseFee, uint256 callbackFeePerGas, uint16 nodesBps, uint16 fulfillerBps, address treasury);

    error BadLength();
    error AlreadyRegistered();
    error BadProof();
    error NotCommitter();
    error CommitOutsideWindow();
    error AlreadyCommitted();
    error NotCommitted();
    error CommitmentMismatch();
    error AlreadyFulfilled();
    error TooFewParticipants();
    error IndicesNotIncreasing();
    error UnknownNode();
    error BadAggregateSignature();
    error DrandNotYetPublished();
    error BadDrandSignature();
    error CallbackGasTooHigh();
    error BadConfig();
    error NotSubscriptionOwner();
    error NotConsumer();
    error TooManyConsumers();
    error InsufficientBalance();
    error PendingRequests();
    error NotRefundable();
    error NothingToWithdraw();
    error TransferFailed();
    error ZeroAddress();
    error StakeTooLow();
    error NotPayee();
    error NodeNotActive();
    error StillBonded();
    error NotEarly();
    error SameReport();

    constructor(
        address owner_,
        address committer_,
        address treasury_,
        uint16 minParticipants_,
        uint256 baseFee_,
        uint256 callbackFeePerGas_,
        uint16 nodesBps_,
        uint16 fulfillerBps_
    ) Ownable(owner_) {
        _configure(committer_, minParticipants_, baseFee_, callbackFeePerGas_, nodesBps_, fulfillerBps_, treasury_);
    }

    // ---------- Time ----------

    function roundOf(uint256 timestamp) public pure returns (uint64) {
        return uint64(timestamp / PERIOD);
    }

    function roundClose(uint64 round) public pure returns (uint256) {
        return uint256(round) * PERIOD + CLOSE_AFTER;
    }

    /// The drand quicknet round mixed into `round`: the first one after the commit window.
    function drandRoundFor(uint64 round) public pure returns (uint64) {
        return uint64((roundClose(round) + COMMIT_WINDOW - DRAND_GENESIS) / DRAND_PERIOD + 1) + 1;
    }

    function drandTime(uint64 drandRound) public pure returns (uint256) {
        return DRAND_GENESIS + (uint256(drandRound) - 1) * DRAND_PERIOD;
    }

    // ---------- Admin ----------

    function configure(
        address committer_,
        uint16 minParticipants_,
        uint256 baseFee_,
        uint256 callbackFeePerGas_,
        uint16 nodesBps_,
        uint16 fulfillerBps_,
        address treasury_
    ) external onlyOwner {
        _configure(committer_, minParticipants_, baseFee_, callbackFeePerGas_, nodesBps_, fulfillerBps_, treasury_);
    }

    function _configure(
        address committer_,
        uint16 minParticipants_,
        uint256 baseFee_,
        uint256 callbackFeePerGas_,
        uint16 nodesBps_,
        uint16 fulfillerBps_,
        address treasury_
    ) private {
        if (committer_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        if (uint256(nodesBps_) + fulfillerBps_ > 10_000) revert BadConfig();
        committer = committer_;
        minParticipants = minParticipants_ == 0 ? 1 : minParticipants_;
        baseFee = baseFee_;
        callbackFeePerGas = callbackFeePerGas_;
        nodesBps = nodesBps_;
        fulfillerBps = fulfillerBps_;
        treasury = treasury_;
        emit ConfigSet(committer_, minParticipants, baseFee_, callbackFeePerGas_, nodesBps_, fulfillerBps_, treasury_);
    }

    // ---------- Nodes ----------

    /// @notice Register a node key, with earnings paid to `payee`. Anyone may; `proof` is the key's
    /// signature of "orvyn-rng:v1:register:" || payee || publicKey. It proves possession of the key
    /// (preventing rogue-key attacks on aggregation) and binds the payee (so a copied registration
    /// can't redirect earnings).
    function register(bytes calldata publicKey, address payee, bytes calldata proof) external payable returns (uint256 index) {
        if (msg.value < minStake) revert StakeTooLow();
        if (publicKey.length != 256 || proof.length != 128) revert BadLength();
        if (payee == address(0)) revert ZeroAddress();
        bytes32 h = keccak256(publicKey);
        if (isNode[h]) revert AlreadyRegistered();
        bytes memory hm = BLS12381.hashToG1(abi.encodePacked("orvyn-rng:v1:register:", payee, publicKey), DST_POP);
        if (!BLS12381.verify(proof, hm, publicKey)) revert BadProof();
        isNode[h] = true;
        index = nodes.length;
        nodes.push(Node({keyHash: h, payee: payee, payeeNonce: 0, roundsSigned: 0, stake: uint128(msg.value), exitAt: 0, slashed: false}));
        emit NodeRegistered(index, payee, publicKey);
    }

    /// @notice Change a node's payee, with the node key's signature of
    /// "orvyn-rng:v1:payee:" || index || nonce || newPayee.
    function setPayee(uint256 index, bytes calldata publicKey, address newPayee, bytes calldata proof) external {
        if (newPayee == address(0)) revert ZeroAddress();
        if (index >= nodes.length || keccak256(publicKey) != nodes[index].keyHash) revert UnknownNode();
        Node storage n = nodes[index];
        bytes memory hm = BLS12381.hashToG1(abi.encodePacked("orvyn-rng:v1:payee:", index, uint256(n.payeeNonce), newPayee), DST_POP);
        if (!BLS12381.verify(proof, hm, publicKey)) revert BadProof();
        n.payee = newPayee;
        n.payeeNonce += 1;
        emit PayeeChanged(index, newPayee);
    }

    function nodeCount() external view returns (uint256) {
        return nodes.length;
    }

    function setStaking(uint256 minStake_, uint16 slashReporterBps_) external onlyOwner {
        if (slashReporterBps_ > 10_000) revert BadConfig();
        minStake = minStake_;
        slashReporterBps = slashReporterBps_;
        emit StakingSet(minStake_, slashReporterBps_);
    }

    /// @notice A node's payee starts its exit: it stops counting in new rounds now, stays
    /// slashable, and its stake can be withdrawn after UNBONDING.
    function exit(uint256 index) external {
        Node storage n = nodes[index];
        if (msg.sender != n.payee) revert NotPayee();
        if (n.exitAt != 0 || n.slashed) revert NodeNotActive();
        n.exitAt = uint64(block.timestamp);
        emit NodeExiting(index, block.timestamp + UNBONDING);
    }

    function withdrawStake(uint256 index) external nonReentrant {
        Node storage n = nodes[index];
        if (msg.sender != n.payee) revert NotPayee();
        if (n.exitAt == 0 || n.slashed || block.timestamp < uint256(n.exitAt) + UNBONDING) revert StillBonded();
        uint256 amount = n.stake;
        n.stake = 0;
        emit StakeWithdrawn(index, n.payee, amount);
        _send(n.payee, amount);
    }

    /// @notice Slash a node that signed a round before the round began: present that signature.
    /// Honest nodes only ever sign the current round, so this is proof it pre-signed or leaked its key.
    function reportEarlySignature(uint256 index, bytes calldata publicKey, uint64 round, bytes calldata signature) external {
        if (index >= nodes.length || keccak256(publicKey) != nodes[index].keyHash) revert UnknownNode();
        Node storage n = nodes[index];
        if (n.slashed) revert NodeNotActive();
        if (block.timestamp >= uint256(round) * PERIOD) revert NotEarly();
        bytes memory hm = BLS12381.hashToG1(bytes(string.concat("orvyn-rng:v1:", Strings.toString(round))), DST_SIG);
        if (!BLS12381.verify(signature, hm, publicKey)) revert BadProof();
        _slash(index, round);
    }

    /// The message a node signs for a price report: "orvyn-price:v1:" || feedId || round || price.
    function priceReportMessage(bytes32 feedId, uint64 round, int256 price) public pure returns (bytes memory) {
        return abi.encodePacked("orvyn-price:v1:", feedId, round, price);
    }

    /// @notice Slash a node that signed two different price reports for the same feed and round.
    function reportEquivocation(
        uint256 index,
        bytes calldata publicKey,
        bytes32 feedId,
        uint64 round,
        int256 priceA,
        bytes calldata sigA,
        int256 priceB,
        bytes calldata sigB
    ) external {
        if (priceA == priceB) revert SameReport();
        if (index >= nodes.length || keccak256(publicKey) != nodes[index].keyHash) revert UnknownNode();
        if (nodes[index].slashed) revert NodeNotActive();
        if (!BLS12381.verify(sigA, BLS12381.hashToG1(priceReportMessage(feedId, round, priceA), DST_SIG), publicKey)) revert BadProof();
        if (!BLS12381.verify(sigB, BLS12381.hashToG1(priceReportMessage(feedId, round, priceB), DST_SIG), publicKey)) revert BadProof();
        _slash(index, round);
    }

    function _slash(uint256 index, uint64 round) private {
        Node storage n = nodes[index];
        n.slashed = true;
        uint256 amount = n.stake;
        n.stake = 0;
        uint256 toReporter = (amount * slashReporterBps) / 10_000;
        earnings[msg.sender] += toReporter;
        earnings[treasury] += amount - toReporter;
        emit NodeSlashed(index, msg.sender, round, amount);
    }

    /// A node can count in `round` unless it was slashed or had started leaving before the round closed.
    function eligible(uint256 index, uint64 round) public view returns (bool) {
        Node storage n = nodes[index];
        return !n.slashed && (n.exitAt == 0 || roundClose(round) < n.exitAt);
    }

    // ---------- Subscriptions ----------

    function createSubscription() external returns (uint256 subId) {
        subId = nextSubId++;
        subscriptions[subId].owner = msg.sender;
        emit SubscriptionCreated(subId, msg.sender);
    }

    /// @notice Add BNB to a subscription (anyone may fund any subscription).
    function fund(uint256 subId) external payable {
        if (subscriptions[subId].owner == address(0)) revert NotSubscriptionOwner();
        subscriptions[subId].balance += msg.value;
        emit SubscriptionFunded(subId, msg.sender, msg.value);
    }

    function setConsumer(uint256 subId, address consumer, bool allowed) external {
        Subscription storage s = subscriptions[subId];
        if (s.owner != msg.sender) revert NotSubscriptionOwner();
        if (isConsumer[subId][consumer] == allowed) return;
        if (allowed && s.consumers >= MAX_CONSUMERS) revert TooManyConsumers();
        isConsumer[subId][consumer] = allowed;
        s.consumers = allowed ? s.consumers + 1 : s.consumers - 1;
        emit ConsumerSet(subId, consumer, allowed);
    }

    /// @notice Withdraw `amount` of a subscription's unspent balance (all of it with type(uint256).max).
    function withdrawSubscription(uint256 subId, uint256 amount, address to) external nonReentrant {
        Subscription storage s = subscriptions[subId];
        if (s.owner != msg.sender) revert NotSubscriptionOwner();
        if (to == address(0)) revert ZeroAddress();
        if (amount == type(uint256).max) amount = s.balance;
        if (amount > s.balance) revert InsufficientBalance();
        s.balance -= amount;
        emit SubscriptionClosed(subId, to, amount);
        _send(to, amount);
    }

    /// What one request costs with this callback gas limit.
    function feeFor(uint32 callbackGasLimit) public view returns (uint256) {
        return baseFee + uint256(callbackGasLimit) * callbackFeePerGas;
    }

    // ---------- Requests ----------

    /// @notice A consumer of `subId` asks for randomness. It comes from the next round (whose value
    /// nobody can know yet) and is delivered to `rawFulfillRandomness` once that round is fulfilled.
    /// Each request gets its own value: keccak256(round output, requestId).
    function requestRandomness(uint256 subId, uint32 callbackGasLimit) external returns (uint256 requestId, uint64 round) {
        if (callbackGasLimit > MAX_CALLBACK_GAS) revert CallbackGasTooHigh();
        if (!isConsumer[subId][msg.sender]) revert NotConsumer();
        Subscription storage s = subscriptions[subId];
        uint256 cbFee = uint256(callbackGasLimit) * callbackFeePerGas;
        uint256 fee = baseFee + cbFee;
        if (s.balance < fee) revert InsufficientBalance();
        s.balance -= fee;
        round = roundOf(block.timestamp) + 1;
        roundEscrow[round] += baseFee;
        if (!roundSplit[round].set) roundSplit[round] = Split({nodesBps: nodesBps, fulfillerBps: fulfillerBps, set: true});
        requestId = nextRequestId++;
        requests[requestId] = Request({
            consumer: msg.sender,
            round: round,
            callbackGasLimit: callbackGasLimit,
            subId: subId,
            baseFee: uint128(baseFee),
            callbackFee: uint128(cbFee),
            status: Status.Pending
        });
        _roundRequests[round].push(requestId);
        emit RandomnessRequested(requestId, subId, msg.sender, round, fee);
    }

    /// @notice Return an unfulfilled request's fee to its subscription, REFUND_DELAY after its round.
    function refund(uint256 requestId) external {
        Request storage r = requests[requestId];
        if (r.status != Status.Pending || randomness[r.round] != 0 || block.timestamp < roundClose(r.round) + REFUND_DELAY) revert NotRefundable();
        r.status = Status.Refunded;
        roundEscrow[r.round] -= r.baseFee;
        uint256 amount = uint256(r.baseFee) + r.callbackFee;
        subscriptions[r.subId].balance += amount;
        emit RequestRefunded(requestId, amount);
    }

    /// The value a request receives (also readable without a callback; 0 until its round is fulfilled).
    function randomnessFor(uint256 requestId) public view returns (bytes32) {
        bytes32 out = randomness[requests[requestId].round];
        return out == 0 ? bytes32(0) : keccak256(abi.encode(out, requestId));
    }

    function pendingRequests(uint64 round) external view returns (uint256) {
        return _roundRequests[round].length - deliveredUpTo[round];
    }

    // ---------- Committing and fulfilling ----------

    /// @notice The committer fixes a round's participants and aggregate signature, after the round
    /// closes and before its drand beacon is published.
    function commit(uint64 round, bytes32 value) external {
        if (msg.sender != committer) revert NotCommitter();
        if (block.timestamp < roundClose(round) || block.timestamp >= drandTime(drandRoundFor(round))) revert CommitOutsideWindow();
        if (commitment[round] != 0) revert AlreadyCommitted();
        commitment[round] = value;
        emit RoundCommitted(round, value);
    }

    /// The value `commit` takes for a set of node indices and their aggregate signature.
    function commitmentFor(uint64 round, uint32[] calldata indices, bytes calldata aggregateSignature) public pure returns (bytes32) {
        return keccak256(abi.encode(round, indices, aggregateSignature));
    }

    /// @notice Anyone fulfils a committed round once its drand beacon is out. `publicKeys` are the
    /// participants' registered keys, concatenated in `indices` order; signatures are EIP-2537 G1.
    function fulfill(
        uint64 round,
        uint32[] calldata indices,
        bytes calldata publicKeys,
        bytes calldata aggregateSignature,
        bytes calldata drandSignature
    ) external nonReentrant returns (bytes32 output) {
        if (randomness[round] != 0) revert AlreadyFulfilled();
        bytes32 c = commitment[round];
        if (c == 0) revert NotCommitted();
        if (commitmentFor(round, indices, aggregateSignature) != c) revert CommitmentMismatch();
        for (uint256 i; i < indices.length; ++i) {
            if (indices[i] >= nodes.length || !eligible(indices[i], round)) revert NodeNotActive();
        }
        _checkAggregate(round, indices, publicKeys, aggregateSignature);
        bytes32 drandRandomness = _drandRandomness(drandRoundFor(round), drandSignature);
        output = sha256(abi.encodePacked("orvyn-rng:v1", round, BLS12381.compressG1(aggregateSignature), drandRandomness));
        randomness[round] = output;
        uint256 paid = _payRound(round, indices);
        emit RoundFulfilled(round, output, indices.length, paid);
        _deliver(round, DELIVER_PER_FULFIL);
    }

    /// Split the round's base fees: nodes equally, the fulfiller, the treasury (with any dust).
    function _payRound(uint64 round, uint32[] calldata indices) private returns (uint256 toNodes) {
        uint256 pool = roundEscrow[round];
        roundEscrow[round] = 0;
        Split memory split = roundSplit[round];
        uint256 n = indices.length;
        uint256 each = (pool * split.nodesBps) / 10_000 / n;
        for (uint256 i; i < n; ++i) {
            Node storage node = nodes[indices[i]];
            node.roundsSigned += 1;
            if (each > 0) earnings[node.slashed ? treasury : node.payee] += each;
        }
        toNodes = each * n;
        uint256 toFulfiller = (pool * split.fulfillerBps) / 10_000;
        earnings[msg.sender] += toFulfiller;
        earnings[treasury] += pool - toNodes - toFulfiller;
        totalEarnings += pool;
    }

    /// The participants' aggregate signature of "orvyn-rng:v1:<round>" verifies against their keys.
    function _checkAggregate(uint64 round, uint32[] calldata indices, bytes calldata publicKeys, bytes calldata aggregateSignature) private view {
        bytes memory aggPk = _aggregateKeys(indices, publicKeys);
        bytes memory hm = BLS12381.hashToG1(bytes(string.concat("orvyn-rng:v1:", Strings.toString(round))), DST_SIG);
        if (!BLS12381.verify(aggregateSignature, hm, aggPk)) revert BadAggregateSignature();
    }

    function _aggregateKeys(uint32[] calldata indices, bytes calldata publicKeys) private view returns (bytes memory agg) {
        uint256 n = indices.length;
        if (n < minParticipants) revert TooFewParticipants();
        if (publicKeys.length != n * 256) revert BadLength();
        for (uint256 i; i < n; ++i) {
            if (i > 0 && indices[i] <= indices[i - 1]) revert IndicesNotIncreasing();
            if (indices[i] >= nodes.length) revert UnknownNode();
            bytes calldata pk = publicKeys[i * 256:(i + 1) * 256];
            if (keccak256(pk) != nodes[indices[i]].keyHash) revert UnknownNode();
            agg = i == 0 ? pk : BLS12381.g2Add(agg, pk);
        }
    }

    /// drand quicknet's randomness for round `d`, after checking its signature.
    function _drandRandomness(uint64 d, bytes calldata drandSignature) private view returns (bytes32) {
        if (block.timestamp < drandTime(d)) revert DrandNotYetPublished();
        bytes memory dm = BLS12381.hashToG1(abi.encodePacked(sha256(abi.encodePacked(d))), DST_DRAND);
        if (!BLS12381.verify(drandSignature, dm, DRAND_PUBLIC_KEY)) revert BadDrandSignature();
        return sha256(BLS12381.compressG1(drandSignature));
    }

    // ---------- Delivery ----------

    /// @notice Deliver pending callbacks for a fulfilled round (anyone; continues where it left off).
    /// The deliverer earns each delivered request's callback fee.
    function deliver(uint64 round, uint256 max) external nonReentrant {
        _deliver(round, max);
    }

    function _deliver(uint64 round, uint256 max) private {
        if (randomness[round] == 0) return;
        uint256[] storage ids = _roundRequests[round];
        uint256 i = deliveredUpTo[round];
        uint256 end = i + max < ids.length ? i + max : ids.length;
        for (; i < end; ++i) {
            Request storage r = requests[ids[i]];
            if (r.status != Status.Pending) continue;
            // Enough gas must be left for the promised limit (so a caller can't starve the callback).
            if (gasleft() < uint256(r.callbackGasLimit) + 40_000) break;
            r.status = Status.Delivered;
            earnings[msg.sender] += r.callbackFee;
            totalEarnings += r.callbackFee;
            bytes32 value = randomnessFor(ids[i]);
            bool ok;
            try IOrvynRNGConsumer(r.consumer).rawFulfillRandomness{gas: r.callbackGasLimit}(ids[i], value) {
                ok = true;
            } catch {}
            emit RandomnessDelivered(ids[i], value, ok);
        }
        deliveredUpTo[round] = i;
    }

    // ---------- Earnings ----------

    function withdraw() external nonReentrant {
        _withdrawFor(msg.sender);
    }

    /// @notice Pay an account's earnings to that account (anyone may trigger it; the destination is fixed).
    function withdrawFor(address account) external nonReentrant {
        _withdrawFor(account);
    }

    function _withdrawFor(address account) private {
        uint256 amount = earnings[account];
        if (amount == 0) revert NothingToWithdraw();
        earnings[account] = 0;
        emit Withdrawn(account, amount);
        _send(account, amount);
    }

    function _send(address to, uint256 amount) private {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
