// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StateToken} from "../src/StateToken.sol";
import {DeployStateToken} from "../script/DeployStateToken.s.sol";

/// @notice Stands in for the launch factory: deploys the token so the supply lands on a contract
///         address, exactly as ProjectFactory.launchCustom does, and forwards transfers on request.
contract FactoryStub {
    StateToken public token;

    function deployToken() external returns (StateToken) {
        token = new StateToken();
        return token;
    }

    function move(address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

contract StateTokenTest is Test {
    uint256 constant SUPPLY = 1_000_000 * 1e18;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    FactoryStub factory;
    StateToken token;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    function setUp() public {
        factory = new FactoryStub();
        token = factory.deployToken();
    }

    // ---------------------------------------------------------------------------------------------
    // Constructor and metadata
    // ---------------------------------------------------------------------------------------------

    function test_metadata() public view {
        assertEq(token.name(), "State Encryption");
        assertEq(token.symbol(), "STATE");
        assertEq(token.decimals(), 18);
        assertEq(token.DECIMALS(), 18);
    }

    function test_constructorMintsWholeSupplyToDeployer() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
        assertEq(token.SUPPLY_WHOLE_TOKENS(), 1_000_000);
        assertEq(token.balanceOf(address(factory)), SUPPLY, "deployer does not hold the whole supply");
        assertEq(token.balanceOf(address(this)), 0, "the test contract received tokens");
    }

    function test_constructorEmitsMintTransfer() public {
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(0), alice, SUPPLY);
        vm.prank(alice);
        StateToken fresh = new StateToken();
        assertEq(fresh.balanceOf(alice), SUPPLY);
    }

    function test_deployScriptMintsToTheBroadcaster() public {
        DeployStateToken deployer = new DeployStateToken();
        StateToken deployed = deployer.deploy();
        // `new` inside deploy() is sent by the script contract, so the script holds the supply.
        assertEq(deployed.totalSupply(), SUPPLY);
        assertEq(deployed.balanceOf(address(deployer)), SUPPLY);
        assertEq(deployed.name(), "State Encryption");
        assertEq(deployed.symbol(), "STATE");
    }

    function test_deploymentDoesNotDependOnChainState() public {
        // Nothing is read from another contract: deploys identically on a bare chain id.
        vm.chainId(1);
        StateToken fresh = new StateToken();
        assertEq(fresh.totalSupply(), SUPPLY);
        assertEq(fresh.balanceOf(address(this)), SUPPLY);
    }

    // ---------------------------------------------------------------------------------------------
    // transfer
    // ---------------------------------------------------------------------------------------------

    function test_transferMovesExactAmount() public {
        assertTrue(factory.move(alice, 100e18));
        assertEq(token.balanceOf(alice), 100e18);
        assertEq(token.balanceOf(address(factory)), SUPPLY - 100e18);

        vm.expectEmit(true, true, true, true);
        emit Transfer(alice, bob, 40e18);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 40e18));

        assertEq(token.balanceOf(alice), 60e18);
        assertEq(token.balanceOf(bob), 40e18);
        assertEq(token.totalSupply(), SUPPLY, "transfers changed the supply");
    }

    function test_transferZeroAmountSucceeds() public {
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferToSelfKeepsBalance() public {
        factory.move(alice, 10e18);
        vm.prank(alice);
        token.transfer(alice, 10e18);
        assertEq(token.balanceOf(alice), 10e18);
    }

    function test_transferWholeBalance() public {
        factory.move(alice, 10e18);
        vm.prank(alice);
        token.transfer(bob, 10e18);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 10e18);
    }

    function test_RevertWhen_transferExceedsBalance() public {
        factory.move(alice, 10e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StateToken.InsufficientBalance.selector, alice, 10e18, 10e18 + 1));
        token.transfer(bob, 10e18 + 1);
    }

    function test_RevertWhen_transferFromEmptyAccount() public {
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(StateToken.InsufficientBalance.selector, carol, 0, 1));
        token.transfer(bob, 1);
    }

    function test_RevertWhen_transferToZeroAddress() public {
        factory.move(alice, 10e18);
        vm.prank(alice);
        vm.expectRevert(StateToken.ZeroAddress.selector);
        token.transfer(address(0), 1e18);
    }

    // ---------------------------------------------------------------------------------------------
    // approve / allowance
    // ---------------------------------------------------------------------------------------------

    function test_approveSetsAllowanceAndEmits() public {
        vm.expectEmit(true, true, true, true);
        emit Approval(alice, bob, 5e18);
        vm.prank(alice);
        assertTrue(token.approve(bob, 5e18));
        assertEq(token.allowance(alice, bob), 5e18);

        // approve overwrites rather than adds
        vm.prank(alice);
        token.approve(bob, 2e18);
        assertEq(token.allowance(alice, bob), 2e18);
    }

    function test_approveDoesNotRequireBalance() public {
        assertEq(token.balanceOf(alice), 0);
        vm.prank(alice);
        token.approve(bob, type(uint256).max);
        assertEq(token.allowance(alice, bob), type(uint256).max);
    }

    function test_RevertWhen_approveZeroAddress() public {
        vm.prank(alice);
        vm.expectRevert(StateToken.ZeroAddress.selector);
        token.approve(address(0), 1);
    }

    function test_increaseAndDecreaseAllowance() public {
        vm.startPrank(alice);
        assertTrue(token.increaseAllowance(bob, 3e18));
        assertEq(token.allowance(alice, bob), 3e18);
        assertTrue(token.increaseAllowance(bob, 2e18));
        assertEq(token.allowance(alice, bob), 5e18);
        assertTrue(token.decreaseAllowance(bob, 4e18));
        assertEq(token.allowance(alice, bob), 1e18);
        assertTrue(token.decreaseAllowance(bob, 1e18));
        assertEq(token.allowance(alice, bob), 0);
        vm.stopPrank();
    }

    function test_RevertWhen_decreaseAllowanceBelowZero() public {
        vm.startPrank(alice);
        token.approve(bob, 1e18);
        vm.expectRevert(abi.encodeWithSelector(StateToken.InsufficientAllowance.selector, bob, 1e18, 2e18));
        token.decreaseAllowance(bob, 2e18);
        vm.stopPrank();
    }

    function test_RevertWhen_increaseAllowanceOverflows() public {
        vm.startPrank(alice);
        token.approve(bob, type(uint256).max);
        vm.expectRevert(); // checked arithmetic panic
        token.increaseAllowance(bob, 1);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------------------------------
    // transferFrom
    // ---------------------------------------------------------------------------------------------

    function test_transferFromSpendsAllowance() public {
        factory.move(alice, 10e18);
        vm.prank(alice);
        token.approve(bob, 6e18);

        vm.expectEmit(true, true, true, true);
        emit Approval(alice, bob, 2e18);
        vm.expectEmit(true, true, true, true);
        emit Transfer(alice, carol, 4e18);
        vm.prank(bob);
        assertTrue(token.transferFrom(alice, carol, 4e18));

        assertEq(token.balanceOf(alice), 6e18);
        assertEq(token.balanceOf(carol), 4e18);
        assertEq(token.balanceOf(bob), 0, "the spender received tokens");
        assertEq(token.allowance(alice, bob), 2e18);
    }

    function test_transferFromWithUnlimitedAllowanceKeepsIt() public {
        factory.move(alice, 10e18);
        vm.prank(alice);
        token.approve(bob, type(uint256).max);
        vm.prank(bob);
        token.transferFrom(alice, carol, 7e18);
        assertEq(token.allowance(alice, bob), type(uint256).max);
        assertEq(token.balanceOf(carol), 7e18);
    }

    function test_RevertWhen_transferFromExceedsAllowance() public {
        factory.move(alice, 10e18);
        vm.prank(alice);
        token.approve(bob, 1e18);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(StateToken.InsufficientAllowance.selector, bob, 1e18, 2e18));
        token.transferFrom(alice, carol, 2e18);
    }

    function test_RevertWhen_transferFromWithoutAllowance() public {
        factory.move(alice, 10e18);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(StateToken.InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(alice, carol, 1);
    }

    function test_RevertWhen_transferFromExceedsBalanceDespiteAllowance() public {
        factory.move(alice, 1e18);
        vm.prank(alice);
        token.approve(bob, 5e18);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(StateToken.InsufficientBalance.selector, alice, 1e18, 2e18));
        token.transferFrom(alice, carol, 2e18);
        assertEq(token.allowance(alice, bob), 5e18, "a failed transferFrom spent allowance");
    }

    function test_RevertWhen_transferFromToZeroAddress() public {
        factory.move(alice, 1e18);
        vm.prank(alice);
        token.approve(bob, 1e18);
        vm.prank(bob);
        vm.expectRevert(StateToken.ZeroAddress.selector);
        token.transferFrom(alice, address(0), 1e18);
    }

    // ---------------------------------------------------------------------------------------------
    // Launch flows: the factory, distributor and pool manager move exact amounts, untaxed
    // ---------------------------------------------------------------------------------------------

    function test_launchFlowsArriveWhole() public {
        address distributor = makeAddr("distributor");
        address claimant = makeAddr("claimant");
        address poolManager = makeAddr("poolManager");
        address remainder = makeAddr("remainder");

        uint256 swarm = SUPPLY * 1_000 / 10_000;
        uint256 pool = SUPPLY * 8_800 / 10_000;
        uint256 rest = SUPPLY - swarm - pool;

        assertTrue(factory.move(distributor, swarm));
        assertTrue(factory.move(poolManager, pool));
        assertTrue(factory.move(remainder, rest));
        assertEq(token.balanceOf(distributor), swarm);
        assertEq(token.balanceOf(poolManager), pool);
        assertEq(token.balanceOf(remainder), rest);
        assertEq(token.balanceOf(address(factory)), 0);

        vm.prank(distributor);
        assertTrue(token.transfer(claimant, swarm));
        assertEq(token.balanceOf(claimant), swarm);
        assertEq(token.balanceOf(distributor), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    // ---------------------------------------------------------------------------------------------
    // No privileged surface: nothing mints, pauses, freezes or seizes
    // ---------------------------------------------------------------------------------------------

    function test_noCallIncreasesSupplyOrMintsToCaller() public {
        string[10] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)"
        ];
        address attacker = makeAddr("attacker");
        address[2] memory callers = [attacker, address(factory)];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], attacker, type(uint128).max);
            for (uint256 c; c < callers.length; ++c) {
                vm.prank(callers[c]);
                (bool ok,) = address(token).call(data);
                assertFalse(ok, string.concat("unexpected function answered: ", signatures[i]));
            }
            assertEq(token.totalSupply(), SUPPLY, signatures[i]);
            assertEq(token.balanceOf(attacker), 0, signatures[i]);
        }
    }

    function test_noPrivilegedCallMovesOrFreezesAHolder() public {
        address holder = makeAddr("holder");
        factory.move(holder, SUPPLY / 1_000);
        uint256 held = token.balanceOf(holder);

        string[12] memory signatures = [
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "seize(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            vm.prank(address(factory));
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], holder, true));
            assertFalse(ok, string.concat("unexpected function answered: ", signatures[i]));
        }

        // The deployer has no allowance and so cannot pull from the holder.
        vm.prank(address(factory));
        vm.expectRevert(abi.encodeWithSelector(StateToken.InsufficientAllowance.selector, address(factory), 0, 1));
        token.transferFrom(holder, address(factory), 1);

        assertEq(token.balanceOf(holder), held);
        vm.prank(holder);
        assertTrue(token.transfer(bob, held / 2));
        assertEq(token.balanceOf(bob), held / 2);
    }

    function test_unknownSelectorAndPlainEtherAreRejected() public {
        (bool ok,) = address(token).call(abi.encodeWithSignature("doesNotExist()"));
        assertFalse(ok, "fallback accepted an unknown call");
        (ok,) = address(token).call{value: 1 ether}("");
        assertFalse(ok, "the token accepted ether");
        assertEq(address(token).balance, 0);
    }

    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576, "runtime exceeds EIP-170");
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4, "DELEGATECALL in runtime");
            assertTrue(op != 0xF2, "CALLCODE in runtime");
            assertTrue(op != 0xFF, "SELFDESTRUCT in runtime");
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Fuzz: conservation and exactness
    // ---------------------------------------------------------------------------------------------

    function testFuzz_transferConservesSupply(address to, uint256 seed, uint256 amount) public {
        vm.assume(to != address(0) && to != address(factory));
        seed = bound(seed, 1, SUPPLY);
        amount = bound(amount, 0, seed);
        factory.move(alice, seed);
        vm.assume(to != alice);

        vm.prank(alice);
        assertTrue(token.transfer(to, amount));
        assertEq(token.balanceOf(alice), seed - amount);
        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(alice) + token.balanceOf(to) + token.balanceOf(address(factory)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferAboveBalanceReverts(uint256 seed, uint256 excess) public {
        seed = bound(seed, 0, SUPPLY);
        excess = bound(excess, 1, type(uint256).max - seed);
        factory.move(alice, seed);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StateToken.InsufficientBalance.selector, alice, seed, seed + excess));
        token.transfer(bob, seed + excess);
    }

    function testFuzz_transferFromSpendsExactly(uint256 held, uint256 allowed, uint256 amount) public {
        held = bound(held, 1, SUPPLY);
        allowed = bound(allowed, 1, type(uint256).max - 1); // never the unlimited sentinel
        amount = bound(amount, 1, held < allowed ? held : allowed);
        factory.move(alice, held);
        vm.prank(alice);
        token.approve(bob, allowed);

        vm.prank(bob);
        assertTrue(token.transferFrom(alice, carol, amount));
        assertEq(token.allowance(alice, bob), allowed - amount);
        assertEq(token.balanceOf(carol), amount);
        assertEq(token.balanceOf(alice), held - amount);
    }

    function testFuzz_approveThenAllowanceRoundTrips(address spender, uint256 amount) public {
        vm.assume(spender != address(0));
        vm.prank(alice);
        token.approve(spender, amount);
        assertEq(token.allowance(alice, spender), amount);
    }
}
