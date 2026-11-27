// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {OrvynIds} from "./OrvynIds.sol";

/// @notice Binance Agent ID (`name.ai`): an ERC-721 whose token id is uint256(keccak256(name)).
interface IAgentIdRegistry {
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @title OrvynID (BNB Smart Chain)
/// @notice Every Orvyn agent's identity as a non-transferable NFT (ERC-5192, soulbound): one per
/// agent, held by the agent's own wallet. It names the agent (its handle, so its token URI is the
/// agent's OrvynID document at https://<handle>.orvyn.cash/.well-known/orvyn-id.json), its
/// creator, its entry in the ERC-8004 identity registry, and its Binance Agent ID.
///
/// The Agent ID is tracked two ways:
/// - recorded: an issuer records it when the agent claims one (checked against the Agent ID
///   registry at that moment) and clears it when it's gone; each change is an event, so the
///   history is on chain;
/// - live: `agentIdOf` asks the Agent ID registry now whether the agent's wallet or its creator
///   still holds it.
///
/// Issuers (Orvyn's backend keys, appointed by the owner) issue, update and revoke. Nobody can
/// transfer or approve a token; an issuer can move one to a new wallet when an agent's key is
/// rotated. Upgradeable (UUPS) by the owner, keeping all state.
contract OrvynID is Initializable, UUPSUpgradeable, Ownable2StepUpgradeable, ERC721Upgradeable {
    struct Identity {
        bytes32 agentKey; // keccak256 of the Orvyn agent id
        address creator; // the person who created the agent
        uint64 issuedAt;
        uint256 erc8004Id; // its agentId in the ERC-8004 identity registry (0: none)
        string handle; // atlas → atlas.orvyn.cash
        string agentIdName; // "atlas" for atlas.ai ("" when none is recorded)
    }

    IAgentIdRegistry public agentIdRegistry;
    /// @notice Where OrvynID documents live: https://<handle>.<rootDomain>/.well-known/orvyn-id.json
    string public rootDomain;
    mapping(address => bool) public issuers;
    uint256 public nextTokenId;
    mapping(uint256 => Identity) private identities;
    mapping(bytes32 => uint256) public tokenOfAgent;
    mapping(address => uint256) public tokenOfWallet;
    bool private moving;

    /// ERC-5192: the token can never be transferred.
    event Locked(uint256 tokenId);
    /// ERC-4906: the token's metadata changed.
    event MetadataUpdate(uint256 tokenId);
    event IssuerSet(address indexed issuer, bool allowed);
    event Issued(uint256 indexed tokenId, bytes32 indexed agentKey, address indexed wallet, address creator, string handle);
    event HandleChanged(uint256 indexed tokenId, string handle);
    event CreatorChanged(uint256 indexed tokenId, address creator);
    event Erc8004Linked(uint256 indexed tokenId, uint256 erc8004Id);
    event AgentIdRecorded(uint256 indexed tokenId, string name, uint256 agentIdToken, address holder);
    event AgentIdCleared(uint256 indexed tokenId, string name);
    event WalletMoved(uint256 indexed tokenId, address from, address to);
    event Revoked(uint256 indexed tokenId);

    error Soulbound();
    error NotIssuer();
    error AlreadyIssued();
    error WalletTaken();
    error NoSuchToken();
    error InvalidHandle();
    error InvalidName();
    error AgentIdNotHeld();
    error ZeroAddress();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_, IAgentIdRegistry agentIdRegistry_, string calldata rootDomain_) external initializer {
        __Ownable_init(owner_);
        __ERC721_init("OrvynID", "ORVYNID");
        agentIdRegistry = agentIdRegistry_;
        rootDomain = rootDomain_;
        nextTokenId = 1;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    modifier onlyIssuer() {
        if (!issuers[msg.sender]) revert NotIssuer();
        _;
    }

    // ---------- Owner ----------

    function setIssuer(address issuer, bool allowed) external onlyOwner {
        issuers[issuer] = allowed;
        emit IssuerSet(issuer, allowed);
    }

    function setAgentIdRegistry(IAgentIdRegistry registry) external onlyOwner {
        agentIdRegistry = registry;
    }

    function setRootDomain(string calldata domain) external onlyOwner {
        rootDomain = domain;
        if (nextTokenId > 1) emit BatchMetadataUpdate(1, nextTokenId - 1);
    }

    /// ERC-4906, for root domain changes.
    event BatchMetadataUpdate(uint256 fromTokenId, uint256 toTokenId);

    // ---------- Issuers ----------

    /// @notice Issue an agent's OrvynID to its own wallet. One per agent and one per wallet.
    function issue(string calldata agentId, address wallet, address creator, string calldata handle) external onlyIssuer returns (uint256 tokenId) {
        bytes32 key = OrvynIds.check(agentId);
        if (wallet == address(0) || creator == address(0)) revert ZeroAddress();
        if (tokenOfAgent[key] != 0) revert AlreadyIssued();
        if (tokenOfWallet[wallet] != 0) revert WalletTaken();
        _checkHandle(handle);
        tokenId = nextTokenId++;
        identities[tokenId] = Identity({agentKey: key, creator: creator, issuedAt: uint64(block.timestamp), erc8004Id: 0, handle: handle, agentIdName: ""});
        tokenOfAgent[key] = tokenId;
        tokenOfWallet[wallet] = tokenId;
        _mint(wallet, tokenId);
        emit Locked(tokenId);
        emit Issued(tokenId, key, wallet, creator, handle);
    }

    function setHandle(uint256 tokenId, string calldata handle) external onlyIssuer {
        _exists(tokenId);
        _checkHandle(handle);
        identities[tokenId].handle = handle;
        emit HandleChanged(tokenId, handle);
        emit MetadataUpdate(tokenId);
    }

    function setCreator(uint256 tokenId, address creator) external onlyIssuer {
        _exists(tokenId);
        if (creator == address(0)) revert ZeroAddress();
        identities[tokenId].creator = creator;
        emit CreatorChanged(tokenId, creator);
    }

    function linkErc8004(uint256 tokenId, uint256 erc8004Id) external onlyIssuer {
        _exists(tokenId);
        identities[tokenId].erc8004Id = erc8004Id;
        emit Erc8004Linked(tokenId, erc8004Id);
        emit MetadataUpdate(tokenId);
    }

    /// @notice Record the agent's Agent ID (`name` without ".ai"). It must be held right now by
    /// the agent's wallet or its creator.
    function recordAgentId(uint256 tokenId, string calldata name) external onlyIssuer {
        _exists(tokenId);
        _checkName(name);
        uint256 agentIdToken = uint256(keccak256(bytes(name)));
        address holder = _holderOf(agentIdToken);
        if (holder == address(0) || (holder != _ownerOf(tokenId) && holder != identities[tokenId].creator)) revert AgentIdNotHeld();
        identities[tokenId].agentIdName = name;
        emit AgentIdRecorded(tokenId, name, agentIdToken, holder);
        emit MetadataUpdate(tokenId);
    }

    function clearAgentId(uint256 tokenId) external onlyIssuer {
        _exists(tokenId);
        string memory old = identities[tokenId].agentIdName;
        if (bytes(old).length == 0) return;
        identities[tokenId].agentIdName = "";
        emit AgentIdCleared(tokenId, old);
        emit MetadataUpdate(tokenId);
    }

    /// @notice The agent's key was rotated: its OrvynID follows it to the new wallet.
    function moveWallet(uint256 tokenId, address newWallet) external onlyIssuer {
        address from = _ownerOf(tokenId);
        if (from == address(0)) revert NoSuchToken();
        if (newWallet == address(0)) revert ZeroAddress();
        if (tokenOfWallet[newWallet] != 0) revert WalletTaken();
        delete tokenOfWallet[from];
        tokenOfWallet[newWallet] = tokenId;
        moving = true;
        _update(newWallet, tokenId, address(0));
        moving = false;
        emit WalletMoved(tokenId, from, newWallet);
    }

    /// @notice The agent is gone: its OrvynID is burned. The agent id can be issued again.
    function revoke(uint256 tokenId) external onlyIssuer {
        address wallet = _ownerOf(tokenId);
        if (wallet == address(0)) revert NoSuchToken();
        delete tokenOfAgent[identities[tokenId].agentKey];
        delete tokenOfWallet[wallet];
        delete identities[tokenId];
        _burn(tokenId);
        emit Revoked(tokenId);
    }

    // ---------- Reads ----------

    /// @notice An OrvynID: who it is, and its Agent ID as recorded and as it stands now.
    function identityOf(uint256 tokenId)
        external
        view
        returns (Identity memory identity, address wallet, bool agentIdHeldNow)
    {
        wallet = _ownerOf(tokenId);
        if (wallet == address(0)) revert NoSuchToken();
        identity = identities[tokenId];
        (,,, agentIdHeldNow) = agentIdOf(tokenId);
    }

    /// @notice The recorded Agent ID, checked live: who holds it now, and whether that's the
    /// agent's wallet or its creator.
    function agentIdOf(uint256 tokenId) public view returns (string memory name, uint256 agentIdToken, address holder, bool heldNow) {
        address wallet = _ownerOf(tokenId);
        if (wallet == address(0)) revert NoSuchToken();
        name = identities[tokenId].agentIdName;
        if (bytes(name).length == 0) return (name, 0, address(0), false);
        agentIdToken = uint256(keccak256(bytes(name)));
        holder = _holderOf(agentIdToken);
        heldNow = holder != address(0) && (holder == wallet || holder == identities[tokenId].creator);
    }

    function tokenOfAgentId(string calldata agentId) external view returns (uint256) {
        return tokenOfAgent[OrvynIds.key(agentId)];
    }

    /// @notice The agent's OrvynID document.
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        return string.concat("https://", identities[tokenId].handle, ".", rootDomain, "/.well-known/orvyn-id.json");
    }

    /// ERC-5192: every OrvynID is locked.
    function locked(uint256 tokenId) external view returns (bool) {
        _requireOwned(tokenId);
        return true;
    }

    function supportsInterface(bytes4 id) public view override returns (bool) {
        return id == 0xb45a3c0e /* ERC-5192 */ || id == 0x49064906 /* ERC-4906 */ || super.supportsInterface(id);
    }

    // ---------- Soulbound ----------

    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0) && !moving) revert Soulbound();
        return super._update(to, tokenId, auth);
    }

    function approve(address, uint256) public pure override {
        revert Soulbound();
    }

    function setApprovalForAll(address, bool) public pure override {
        revert Soulbound();
    }

    // ---------- Internals ----------

    function _exists(uint256 tokenId) private view {
        if (_ownerOf(tokenId) == address(0)) revert NoSuchToken();
    }

    function _holderOf(uint256 agentIdToken) private view returns (address) {
        if (address(agentIdRegistry) == address(0)) return address(0);
        try agentIdRegistry.ownerOf(agentIdToken) returns (address h) {
            return h;
        } catch {
            return address(0); // not minted
        }
    }

    /// Handles: 3-32 of [a-z0-9-], no leading, trailing or double hyphen (a DNS label).
    function _checkHandle(string calldata handle) private pure {
        bytes calldata b = bytes(handle);
        if (b.length < 3 || b.length > 32 || b[0] == "-" || b[b.length - 1] == "-") revert InvalidHandle();
        for (uint256 i; i < b.length; ++i) {
            bytes1 c = b[i];
            bool ok = (c >= "0" && c <= "9") || (c >= "a" && c <= "z") || c == "-";
            if (!ok || (c == "-" && b[i - 1] == "-")) revert InvalidHandle();
        }
    }

    /// Agent ID names: 1-63 of [a-z0-9_-], starting with a letter or digit (as Orvyn reads them).
    function _checkName(string calldata name) private pure {
        bytes calldata b = bytes(name);
        if (b.length == 0 || b.length > 63 || b[0] == "-" || b[0] == "_") revert InvalidName();
        for (uint256 i; i < b.length; ++i) {
            bytes1 c = b[i];
            if (!((c >= "0" && c <= "9") || (c >= "a" && c <= "z") || c == "-" || c == "_")) revert InvalidName();
        }
    }

    uint256[43] private __gap;
}
