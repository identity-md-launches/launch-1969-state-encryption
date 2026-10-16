// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {StateToken} from "../src/StateToken.sol";

/// @title Deployment script for State Encryption (STATE)
/// @notice The token takes no constructor arguments, so there is nothing to configure. Whoever
///         sends the deployment transaction receives the whole supply. On the IdentityMD launch
///         that sender is the ProjectFactory, which then pays the supply out.
/// @dev `deploy()` is the unit the tests call directly. `run()` only wraps it in a broadcast; it
///      reads nothing from the environment and never signs anything itself.
contract DeployStateToken is Script {
    /// @notice Deploys the token. Reusable from tests and from `run()`.
    function deploy() public returns (StateToken token) {
        token = new StateToken();
    }

    /// @notice Entry point for `forge script`. The broadcasting account is chosen by the forge
    ///         invocation (`--sender`/`--private-key`/`--account`), never by this file.
    function run() external returns (StateToken token) {
        vm.startBroadcast();
        token = deploy();
        vm.stopBroadcast();
    }
}
