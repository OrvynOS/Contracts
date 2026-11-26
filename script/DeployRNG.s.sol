// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {OrvynRNG} from "../src/rng/OrvynRNG.sol";
import {OrvynPriceFeed, IOrvynNodes} from "../src/rng/OrvynPriceFeed.sol";

/// Deploys Orvyn RNG and Orvyn price feeds on BSC (they need the EIP-2537 BLS12-381 precompiles,
/// live on BSC).
///
///   forge script script/DeployRNG.s.sol --rpc-url bsc_testnet --broadcast --verify
///
/// Env: DEPLOYER_PRIVATE_KEY, ORVYN_OWNER (a multisig), ORVYN_RNG_COMMITTER (the relayer's address:
/// ORVYN_RNG_RELAYER_KEY's account), ORVYN_TREASURY, and optionally ORVYN_RNG_BASE_FEE (wei per
/// request, default 0.0005 BNB), ORVYN_RNG_FEE_PER_GAS (wei per callback gas, default 0.1 gwei),
/// ORVYN_RNG_NODES_BPS (default 7000), ORVYN_RNG_FULFILLER_BPS (default 2000),
/// ORVYN_RNG_MIN_STAKE (default 0.1 BNB), ORVYN_RNG_SLASH_REPORTER_BPS (default 5000).
/// Price feeds: ORVYN_PRICE_QUORUM (signers per report, default 3), ORVYN_PRICE_REWARD (BNB per useful
/// report, default 0.0002). Feeds BTC, ETH, BNB, CAKE and SOL / USD report on a 0.5% move or hourly,
/// bounded within 3% of Chainlink's feed on BSC (addresses checked on chain).
/// Then set ORVYN_RNG_CONTRACT and ORVYN_PRICE_FEED_CONTRACT for the API and orchestrator.
/// Both contracts are deployed owned by the deployer (to configure them), then handed to ORVYN_OWNER,
/// who must call acceptOwnership() on each (Ownable2Step).
contract DeployRNG is Script {
    function run() external {
        uint256 key = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address owner = vm.envAddress("ORVYN_OWNER");
        address treasury = vm.envAddress("ORVYN_TREASURY");
        vm.startBroadcast(key);
        OrvynRNG rng = _deployRng(vm.addr(key), treasury);
        OrvynPriceFeed feeds = _deployFeeds(rng, vm.addr(key), treasury);
        if (owner != vm.addr(key)) {
            rng.transferOwnership(owner);
            feeds.transferOwnership(owner);
        }
        vm.stopBroadcast();
        console.log("OrvynRNG", address(rng));
        console.log("OrvynPriceFeed", address(feeds));
        if (owner != vm.addr(key)) console.log("Owner must call acceptOwnership() on both:", owner);
    }

    function _deployRng(address deployer, address treasury) private returns (OrvynRNG rng) {
        rng = new OrvynRNG(
            deployer,
            vm.envAddress("ORVYN_RNG_COMMITTER"),
            treasury,
            1,
            vm.envOr("ORVYN_RNG_BASE_FEE", uint256(0.0005 ether)),
            vm.envOr("ORVYN_RNG_FEE_PER_GAS", uint256(0.1 gwei)),
            uint16(vm.envOr("ORVYN_RNG_NODES_BPS", uint256(7000))),
            uint16(vm.envOr("ORVYN_RNG_FULFILLER_BPS", uint256(2000)))
        );
        rng.setStaking(vm.envOr("ORVYN_RNG_MIN_STAKE", uint256(0.1 ether)), uint16(vm.envOr("ORVYN_RNG_SLASH_REPORTER_BPS", uint256(5000))));
    }

    function _deployFeeds(OrvynRNG rng, address deployer, address treasury) private returns (OrvynPriceFeed feeds) {
        feeds = new OrvynPriceFeed(deployer, IOrvynNodes(address(rng)), treasury);
        uint16 quorum = uint16(vm.envOr("ORVYN_PRICE_QUORUM", uint256(3)));
        uint256 reward = vm.envOr("ORVYN_PRICE_REWARD", uint256(0.0002 ether));
        string[5] memory pairs = ["BTC / USD", "ETH / USD", "BNB / USD", "CAKE / USD", "SOL / USD"];
        // Chainlink's BSC feeds for the same pairs (description() checked on chain): the reference bound.
        address[5] memory chainlink = [
            0x264990fbd0A4796A3E3d8E37C4d5F87a3aCa5Ebf,
            0x9ef1B8c0E4F7dc8bF5719Ea496883DC6401d5b2e,
            0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE,
            0xB6064eD41d4f67e353768aA239cA86f4F73665a1,
            0x0E8a53DD9c13589df6382F13dA6B3Ec8F919B323
        ];
        for (uint256 i; i < 5; ++i) {
            feeds.configureFeed(pairs[i], quorum, 50, 3600, chainlink[i], 300, reward, 8000);
        }
    }
}
