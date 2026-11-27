// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OrvynRegistry} from "../src/OrvynRegistry.sol";
import {OrvynJobs} from "../src/OrvynJobs.sol";
import {OrvynID, IAgentIdRegistry} from "../src/OrvynID.sol";
import {OrvynPay} from "../src/pay/OrvynPay.sol";
import {OrvynShieldedPool, IVerifier} from "../src/pay/OrvynShieldedPool.sol";
import {IAgentId} from "../src/pay/AgentIdGated.sol";

/// Deploys the Orvyn contracts on BSC.
///
///   forge script script/Deploy.s.sol --rpc-url bsc --broadcast --verify
///
/// Env: DEPLOYER_PRIVATE_KEY, ORVYN_OWNER (use a multisig), ORVYN_OPERATOR (backend hot wallet), and optionally
/// ORVYN_BINANCE_PAY_CREDITOR (backend key that credits Binance Pay subscriptions), and
/// ORVYN_DEPLOY_POOL=true once circuits/build.sh has produced src/pay/Groth16Verifier.sol from
/// a real trusted-setup ceremony.
contract Deploy is Script {
    // BNB Smart Chain mainnet (both 18 decimals).
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
    // Binance Agent ID (.ai) registry, per community docs: verify on BscScan before deploying.
    address constant AGENT_ID = 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F;

    address internal owner;
    address internal operator;
    address internal deployer;
    address internal usdt;
    address internal usdc;
    address internal agentId;

    function run() external {
        owner = vm.envAddress("ORVYN_OWNER");
        operator = vm.envAddress("ORVYN_OPERATOR");
        usdt = vm.envOr("ORVYN_USDT", USDT);
        usdc = vm.envOr("ORVYN_USDC", USDC);
        agentId = vm.envOr("ORVYN_AGENT_ID", AGENT_ID);
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);
        console.log("OrvynRegistry", address(deployRegistry()));
        console.log("OrvynJobs    ", address(deployJobs()));
        console.log("OrvynPay     ", address(deployPay()));
        console.log("OrvynID      ", address(deployOrvynId()));
        if (vm.envOr("ORVYN_DEPLOY_POOL", false)) deployPool();
        vm.stopBroadcast();
    }

    /// The deployer configures each contract, then hands ownership to `owner` (2-step: the owner
    /// must call acceptOwnership). When the deployer is the owner, it simply keeps it.
    function deployRegistry() internal returns (OrvynRegistry registry) {
        uint256 monthlyUsd = vm.envOr("ORVYN_MONTHLY_PRICE", uint256(20e18));
        registry = OrvynRegistry(
            address(new ERC1967Proxy(address(new OrvynRegistry()), abi.encodeCall(OrvynRegistry.initialize, (deployer))))
        );
        registry.setPrice(usdt, monthlyUsd);
        registry.setPrice(usdc, monthlyUsd);
        registry.setPrice(address(0), vm.envOr("ORVYN_MONTHLY_PRICE_BNB", uint256(0.03 ether)));
        // Hosting tiers as multiples of the Basic price: Pro 3x ($60), Studio 7.5x ($150).
        registry.setTierPrice(1, uint32(vm.envOr("ORVYN_TIER_PRO_BPS", uint256(30000))));
        registry.setTierPrice(2, uint32(vm.envOr("ORVYN_TIER_STUDIO_BPS", uint256(75000))));
        registry.addOperator(operator);
        address creditor = vm.envOr("ORVYN_BINANCE_PAY_CREDITOR", address(0));
        if (creditor != address(0)) registry.addCreditor(creditor);
        if (owner != deployer) registry.transferOwnership(owner);
    }

    function deployJobs() internal returns (OrvynJobs jobs) {
        uint16 jobFeeBps = uint16(vm.envOr("ORVYN_JOB_FEE_BPS", uint256(1_000)));
        uint32 reviewHours = uint32(vm.envOr("ORVYN_REVIEW_HOURS", uint256(72)));
        jobs = OrvynJobs(
            address(new ERC1967Proxy(address(new OrvynJobs()), abi.encodeCall(OrvynJobs.initialize, (deployer, jobFeeBps, reviewHours))))
        );
        jobs.setToken(usdt, 1e18);
        jobs.setToken(usdc, 1e18);
        jobs.setToken(address(0), 0.002 ether);
        jobs.addOperator(operator);
        if (owner != deployer) jobs.transferOwnership(owner);
    }

    /// OrvynID: each agent's non-transferable identity NFT. The operator issues and updates them.
    function deployOrvynId() internal returns (OrvynID orvynId) {
        string memory rootDomain = vm.envOr("ORVYN_ROOT_DOMAIN", string("orvyn.cash"));
        orvynId = OrvynID(
            address(new ERC1967Proxy(address(new OrvynID()), abi.encodeCall(OrvynID.initialize, (deployer, IAgentIdRegistry(agentId), rootDomain))))
        );
        orvynId.setIssuer(operator, true);
        if (owner != deployer) orvynId.transferOwnership(owner);
    }

    function deployPay() internal returns (OrvynPay pay) {
        address[] memory tokens = new address[](2);
        tokens[0] = usdt;
        tokens[1] = usdc;
        pay = new OrvynPay(IAgentId(agentId), owner, tokens);
    }

    function deployPool() internal {
        // Loaded from the build artifact so this script compiles before the circuit is built.
        address verifier = deployCode("Groth16Verifier.sol:Groth16Verifier");
        OrvynShieldedPool pool = new OrvynShieldedPool(IVerifier(verifier), IAgentId(agentId), 20, 16, deployer);
        // Start capped while unaudited: 1,000 USDT/USDC and 2 BNB per deposit.
        pool.setAsset(usdt, true, 1_000e18);
        pool.setAsset(usdc, true, 1_000e18);
        pool.setAsset(address(0), true, 2 ether);
        if (owner != deployer) pool.transferOwnership(owner);
        console.log("Groth16Verifier  ", verifier);
        console.log("OrvynShieldedPool", address(pool));
    }
}
