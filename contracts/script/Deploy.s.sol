// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {LucidTypes} from "../src/types/LucidTypes.sol";
import {LucidDesk} from "../src/LucidDesk.sol";
import {LucidBrain} from "../src/LucidBrain.sol";
import {LucidRouter} from "../src/LucidRouter.sol";
import {LucidFactory} from "../src/LucidFactory.sol";
import {LucidKeeper} from "../src/LucidKeeper.sol";
import {LucidRelay} from "../src/LucidRelay.sol";

/// @notice Deploys the protocol and wires it together.
/// @dev The router is funded before `armVenue` on purpose: the reactivity precompile checks the
/// 32 SOMI floor against the contract that calls `subscribe`, and it re-checks it on every
/// subscription, including the one-shot the router creates for each settlement. That balance is a
/// floor to stay above for as long as the protocol runs, not a one-time deposit.
contract Deploy is Script {
    /// @dev Somnia's native agent platform on Shannon.
    address constant AGENT_PLATFORM = 0x037Bb9C718F3f7fe5eCBDB0b600D607b52706776;

    /// @dev The venue the live 60-second BTC and ETH windows are rolled on.
    bytes32 constant VENUE_ID = 0x1a1e6821cde7d0159c0d293177871e09677b4e42307c7db3ba94f8648a5a050f;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        uint256 routerFunding = vm.envOr("ROUTER_FUNDING_WEI", uint256(33 ether));
        uint256 brainFunding = vm.envOr("BRAIN_FUNDING_WEI", uint256(2 ether));

        console.log("deployer", deployer);
        console.log("balance ", deployer.balance);
        require(deployer.balance >= routerFunding + brainFunding + 1 ether, "fund the deployer first");

        vm.startBroadcast(pk);

        LucidDesk deskImpl = new LucidDesk();
        LucidBrain brain = new LucidBrain(deployer, AGENT_PLATFORM);
        LucidRouter router = new LucidRouter(deployer, address(brain));
        LucidFactory factory = new LucidFactory(address(deskImpl), address(router), address(brain));
        LucidKeeper keeper = new LucidKeeper(deployer, address(router));
        LucidRelay relay = new LucidRelay();

        brain.setRouter(address(router));
        router.setFactory(address(factory));
        router.setKeeper(address(keeper));
        router.setRelay(address(relay));

        (bool okRouter,) = payable(address(router)).call{value: routerFunding}("");
        require(okRouter, "router funding failed");
        (bool okBrain,) = payable(address(brain)).call{value: brainFunding}("");
        require(okBrain, "brain funding failed");

        router.armVenue(LucidTypes.MODULE, VENUE_ID);

        vm.stopBroadcast();

        console.log("LucidDesk (implementation)", address(deskImpl));
        console.log("LucidBrain               ", address(brain));
        console.log("LucidRouter              ", address(router));
        console.log("LucidFactory             ", address(factory));
        console.log("LucidKeeper              ", address(keeper));
        console.log("LucidRelay               ", address(relay));
    }
}
