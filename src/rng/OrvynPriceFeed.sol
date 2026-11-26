// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {BLS12381} from "./BLS12381.sol";

/// The parts of OrvynRNG this contract uses: the staked node registry.
interface IOrvynNodes {
    function nodes(uint256 index)
        external
        view
        returns (bytes32 keyHash, address payee, uint64 payeeNonce, uint64 roundsSigned, uint128 stake, uint64 exitAt, bool slashed);
    function eligible(uint256 index, uint64 round) external view returns (bool);
    function nodeCount() external view returns (uint256);
}

/// Chainlink's AggregatorV3Interface (the subset most consumers call), for the per-feed adapter.
interface AggregatorV3Like {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title Orvyn price feeds
/// @notice Prices reported by Orvyn's staked agent nodes (the same registry and stakes as Orvyn RNG).
///
/// Each minute is a round. Every node observes the price from many sources on its own; the report
/// is the median of their observations, and each node signs the report only if it's within its
/// tolerance of what it saw. A report lands here with the participating nodes and their aggregate
/// BLS signature over "orvyn-price:v1:" || feedId || round || price; it's accepted when enough
/// staked nodes signed it (the feed's quorum), it's newer than the last one, it's recent, and,
/// when the feed has a reference (e.g. Chainlink), it's within the feed's bound of that reference.
///
/// Reports are only taken when useful: the price moved by the feed's deviation threshold, or its
/// heartbeat passed. Sponsors fund a feed; each useful report pays its signers (to their payees)
/// and its submitter. A node that signs two different reports for one feed and round is slashed
/// in OrvynRNG (reportEquivocation), where its stake is.
contract OrvynPriceFeed is Ownable2Step, ReentrancyGuard {
    uint256 public constant PERIOD = 60;
    /// A report must be submitted within this long of its round.
    uint256 public constant MAX_REPORT_AGE = 10 minutes;
    uint8 public constant DECIMALS = 8;
    bytes private constant DST_SIG = "BLS_SIG_BLS12381G1_XMD:SHA-256_SSWU_RO_POP_";

    IOrvynNodes public immutable network;
    address public treasury;

    struct Feed {
        string description; // e.g. "BTC / USD"
        uint16 quorum; // signers needed
        uint16 deviationBps; // a move this big is worth a report
        uint32 heartbeat; // seconds; a report is due at least this often
        address referenceFeed; // optional AggregatorV3 to bound against (0: none)
        uint16 maxReferenceDeviationBps;
        uint256 rewardPerReport; // BNB per useful report
        uint16 signersBps; // share of the reward to signers (the rest to the submitter)
        uint256 balance; // sponsors' funds
        // Latest report.
        int256 price;
        uint64 round;
        uint64 updatedAt;
        uint16 signers;
        bool exists;
    }

    mapping(bytes32 feedId => Feed) internal feeds;
    bytes32[] public feedIds;
    mapping(address account => uint256) public earnings;

    event FeedConfigured(bytes32 indexed feedId, string description, uint16 quorum);
    event FeedFunded(bytes32 indexed feedId, address indexed from, uint256 amount);
    event PriceReported(bytes32 indexed feedId, uint64 indexed round, int256 price, uint256 signers, address submitter, uint256 reward);
    event Withdrawn(address indexed account, uint256 amount);

    error UnknownFeed();
    error BadConfig();
    error StaleOrFutureRound();
    error NotNewer();
    error NotNeeded();
    error BelowQuorum();
    error IndicesNotIncreasing();
    error UnknownNode();
    error NodeNotActive();
    error BadLength();
    error BadSignature();
    error OffReference();
    error NothingToWithdraw();
    error TransferFailed();

    constructor(address owner_, IOrvynNodes network_, address treasury_) Ownable(owner_) {
        network = network_;
        treasury = treasury_;
    }

    // ---------- Feeds ----------

    function feedIdOf(string memory pair) public pure returns (bytes32) {
        return keccak256(bytes(pair));
    }

    /// @notice Create or update a feed (owner). Fees and quorum apply to later reports.
    function configureFeed(
        string calldata pair,
        uint16 quorum,
        uint16 deviationBps,
        uint32 heartbeat,
        address referenceFeed,
        uint16 maxReferenceDeviationBps,
        uint256 rewardPerReport,
        uint16 signersBps
    ) external onlyOwner returns (bytes32 id) {
        if (quorum == 0 || signersBps > 10_000 || heartbeat == 0) revert BadConfig();
        id = feedIdOf(pair);
        Feed storage f = feeds[id];
        if (!f.exists) {
            f.exists = true;
            feedIds.push(id);
        }
        f.description = pair;
        f.quorum = quorum;
        f.deviationBps = deviationBps;
        f.heartbeat = heartbeat;
        f.referenceFeed = referenceFeed;
        f.maxReferenceDeviationBps = maxReferenceDeviationBps;
        f.rewardPerReport = rewardPerReport;
        f.signersBps = signersBps;
        emit FeedConfigured(id, pair, quorum);
    }

    function setTreasury(address treasury_) external onlyOwner {
        treasury = treasury_;
    }

    /// @notice Sponsor a feed: anyone can add BNB that pays for its reports.
    function fund(bytes32 feedId) external payable {
        if (!feeds[feedId].exists) revert UnknownFeed();
        feeds[feedId].balance += msg.value;
        emit FeedFunded(feedId, msg.sender, msg.value);
    }

    function feedCount() external view returns (uint256) {
        return feedIds.length;
    }

    /// A feed's full configuration and latest report.
    function feed(bytes32 feedId) external view returns (Feed memory) {
        return feeds[feedId];
    }

    function feedDescription(bytes32 feedId) external view returns (string memory) {
        return feeds[feedId].description;
    }

    /// The message nodes sign (same bytes as OrvynRNG.priceReportMessage).
    function reportMessage(bytes32 feedId, uint64 round, int256 price) public pure returns (bytes memory) {
        return abi.encodePacked("orvyn-price:v1:", feedId, round, price);
    }

    /// Whether a report with this price would be taken now (moved enough, or heartbeat due).
    function isUseful(bytes32 feedId, int256 price) public view returns (bool) {
        Feed storage f = feeds[feedId];
        if (f.updatedAt == 0) return true;
        if (block.timestamp >= uint256(f.updatedAt) + f.heartbeat) return true;
        uint256 diff = price > f.price ? uint256(price - f.price) : uint256(f.price - price);
        return diff * 10_000 >= uint256(f.price > 0 ? f.price : -f.price) * f.deviationBps;
    }

    // ---------- Reports ----------

    /// @notice Submit a signed report (anyone). `publicKeys` are the signers' registered keys,
    /// concatenated in `indices` order; `aggregateSignature` is EIP-2537 G1.
    function submit(bytes32 feedId, uint64 round, int256 price, uint32[] calldata indices, bytes calldata publicKeys, bytes calldata aggregateSignature)
        external
        nonReentrant
    {
        Feed storage f = feeds[feedId];
        if (!f.exists) revert UnknownFeed();
        uint256 t = uint256(round) * PERIOD;
        if (t > block.timestamp || block.timestamp > t + MAX_REPORT_AGE) revert StaleOrFutureRound();
        if (round <= f.round) revert NotNewer();
        if (!isUseful(feedId, price)) revert NotNeeded();
        if (indices.length < f.quorum) revert BelowQuorum();
        _checkReference(f, price);
        _verify(feedId, round, price, indices, publicKeys, aggregateSignature);

        f.price = price;
        f.round = round;
        f.updatedAt = uint64(block.timestamp);
        f.signers = uint16(indices.length);
        uint256 reward = f.balance >= f.rewardPerReport ? f.rewardPerReport : 0;
        if (reward > 0) _pay(f, indices, reward);
        emit PriceReported(feedId, round, price, indices.length, msg.sender, reward);
    }

    function _checkReference(Feed storage f, int256 price) private view {
        if (f.referenceFeed == address(0)) return;
        AggregatorV3Like ref = AggregatorV3Like(f.referenceFeed);
        (, int256 refAnswer,,,) = ref.latestRoundData();
        uint8 d = ref.decimals();
        // Bring the reference to 8 decimals.
        int256 r = d >= DECIMALS ? refAnswer / int256(10 ** (d - DECIMALS)) : refAnswer * int256(10 ** (DECIMALS - d));
        uint256 diff = price > r ? uint256(price - r) : uint256(r - price);
        if (diff * 10_000 > uint256(r > 0 ? r : -r) * f.maxReferenceDeviationBps) revert OffReference();
    }

    function _verify(bytes32 feedId, uint64 round, int256 price, uint32[] calldata indices, bytes calldata publicKeys, bytes calldata aggregateSignature) private view {
        bytes memory agg = _aggregateKeys(round, indices, publicKeys);
        bytes memory hm = BLS12381.hashToG1(reportMessage(feedId, round, price), DST_SIG);
        if (!BLS12381.verify(aggregateSignature, hm, agg)) revert BadSignature();
    }

    /// The signers' keys summed, after checking each is a registered node eligible in `round`.
    function _aggregateKeys(uint64 round, uint32[] calldata indices, bytes calldata publicKeys) private view returns (bytes memory agg) {
        uint256 n = indices.length;
        if (publicKeys.length != n * 256) revert BadLength();
        for (uint256 i; i < n; ++i) {
            if (i > 0 && indices[i] <= indices[i - 1]) revert IndicesNotIncreasing();
            bytes calldata pk = publicKeys[i * 256:(i + 1) * 256];
            _checkNode(indices[i], round, keccak256(pk));
            agg = i == 0 ? pk : BLS12381.g2Add(agg, pk);
        }
    }

    function _checkNode(uint32 index, uint64 round, bytes32 keyHash) private view {
        (bytes32 registered,,,,,,) = network.nodes(index);
        if (registered != keyHash) revert UnknownNode();
        if (!network.eligible(index, round)) revert NodeNotActive();
    }

    function _pay(Feed storage f, uint32[] calldata indices, uint256 reward) private {
        f.balance -= reward;
        uint256 n = indices.length;
        uint256 each = (reward * f.signersBps) / 10_000 / n;
        for (uint256 i; i < n; ++i) {
            (,address payee,,,,, bool slashed) = network.nodes(indices[i]);
            earnings[slashed ? treasury : payee] += each;
        }
        earnings[msg.sender] += reward - each * n;
    }

    // ---------- Reading ----------

    /// Chainlink-style read for one feed (see OrvynFeedAdapter for the per-feed interface).
    function latest(bytes32 feedId) external view returns (int256 price, uint64 round, uint64 updatedAt, uint16 signers) {
        Feed storage f = feeds[feedId];
        if (!f.exists) revert UnknownFeed();
        return (f.price, f.round, f.updatedAt, f.signers);
    }

    // ---------- Earnings ----------

    function withdraw() external nonReentrant {
        _withdrawFor(msg.sender);
    }

    function withdrawFor(address account) external nonReentrant {
        _withdrawFor(account);
    }

    function _withdrawFor(address account) private {
        uint256 amount = earnings[account];
        if (amount == 0) revert NothingToWithdraw();
        earnings[account] = 0;
        emit Withdrawn(account, amount);
        (bool ok,) = account.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}

/// @title One Orvyn price feed behind Chainlink's AggregatorV3Interface
/// @notice Point existing Chainlink consumers at this adapter to read an Orvyn feed unchanged.
contract OrvynFeedAdapter is AggregatorV3Like {
    OrvynPriceFeed public immutable hub;
    bytes32 public immutable feedId;

    constructor(OrvynPriceFeed hub_, bytes32 feedId_) {
        hub = hub_;
        feedId = feedId_;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function description() external view returns (string memory) {
        return hub.feedDescription(feedId);
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function latestRoundData() external view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) {
        (int256 price, uint64 round, uint64 at,) = hub.latest(feedId);
        uint256 start = uint256(round) * 60;
        return (uint80(round), price, start, at, uint80(round));
    }
}
