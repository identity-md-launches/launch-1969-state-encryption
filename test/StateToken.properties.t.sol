// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {StateToken} from "../src/StateToken.sol";

/// @notice Stateless property and edge-case tests. These complement `StateToken.t.sol` (unit) and
///         `StateToken.invariant.t.sol` (random sequences) with algebraic properties the token must
///         keep and with the exact boundaries of its arithmetic: the unlimited-allowance sentinel,
///         a spender who is also the owner, a recipient who is also the sender, revocation, and the
///         shape of the events emitted on every path.
/// forge-config: default.fuzz.runs = 1000
contract StateTokenPropertiesTest is Test {
    uint256 constant SUPPLY = 1_000_000 * 1e18;
    uint256 constant MAX = type(uint256).max;

    bytes32 constant TRANSFER_SIG = keccak256("Transfer(address,address,uint256)");
    bytes32 constant APPROVAL_SIG = keccak256("Approval(address,address,uint256)");

    StateToken token;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    function setUp() public {
        // The test contract is the deployer and holds the supply; it hands some to alice.
        token = new StateToken();
    }

    function _fund(address who, uint256 amount) private {
        token.transfer(who, amount);
    }

    // ---------------------------------------------------------------------------------------------
    // Algebraic properties of transfer
    // ---------------------------------------------------------------------------------------------

    /// @dev Two transfers from the same sender land on the same final state in either order.
    function testFuzz_transfersCommute(uint256 held, uint256 a, uint256 b) public {
        held = bound(held, 0, SUPPLY);
        a = bound(a, 0, held);
        b = bound(b, 0, held - a);
        _fund(alice, held);

        uint256 snap = vm.snapshotState();
        vm.startPrank(alice);
        token.transfer(bob, a);
        token.transfer(carol, b);
        vm.stopPrank();
        uint256 aliceAB = token.balanceOf(alice);
        uint256 bobAB = token.balanceOf(bob);
        uint256 carolAB = token.balanceOf(carol);

        assertTrue(vm.revertToState(snap));
        vm.startPrank(alice);
        token.transfer(carol, b);
        token.transfer(bob, a);
        vm.stopPrank();

        assertEq(token.balanceOf(alice), aliceAB, "order changed the sender's balance");
        assertEq(token.balanceOf(bob), bobAB, "order changed bob's balance");
        assertEq(token.balanceOf(carol), carolAB, "order changed carol's balance");
    }

    /// @dev Splitting an amount into two transfers is the same as one transfer of the sum.
    function testFuzz_transferIsAdditive(uint256 held, uint256 a, uint256 b) public {
        held = bound(held, 0, SUPPLY);
        a = bound(a, 0, held);
        b = bound(b, 0, held - a);
        _fund(alice, held);

        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        token.transfer(bob, a + b);
        uint256 single = token.balanceOf(bob);
        uint256 singleAlice = token.balanceOf(alice);

        assertTrue(vm.revertToState(snap));
        vm.startPrank(alice);
        token.transfer(bob, a);
        token.transfer(bob, b);
        vm.stopPrank();
        assertEq(token.balanceOf(bob), single, "split differs from the sum");
        assertEq(token.balanceOf(alice), singleAlice);
    }

    /// @dev A round trip returns both parties to where they started.
    function testFuzz_transferRoundTrip(uint256 held, uint256 amount) public {
        held = bound(held, 0, SUPPLY);
        amount = bound(amount, 0, held);
        _fund(alice, held);
        vm.prank(alice);
        token.transfer(bob, amount);
        vm.prank(bob);
        token.transfer(alice, amount);
        assertEq(token.balanceOf(alice), held);
        assertEq(token.balanceOf(bob), 0);
    }

    /// @dev Tokens passed through a chain of fresh addresses arrive whole at the end.
    function testFuzz_chainOfHopsConserves(uint256 amount, uint8 hops) public {
        amount = bound(amount, 0, SUPPLY);
        hops = uint8(bound(hops, 1, 32));
        address prev = address(this);
        for (uint256 i; i < hops; ++i) {
            address next = address(uint160(uint256(keccak256(abi.encode("hop", i)))));
            vm.prank(prev);
            assertTrue(token.transfer(next, amount));
            assertEq(token.balanceOf(prev), prev == address(this) ? SUPPLY - amount : 0);
            prev = next;
        }
        assertEq(token.balanceOf(prev), amount, "the chain lost or gained tokens");
        assertEq(token.balanceOf(address(this)) + token.balanceOf(prev), SUPPLY);
    }

    /// @dev Self-transfer is a no-op for any amount up to the balance, and reverts above it: the
    ///      balance check is not skipped for the sender's own address.
    function testFuzz_selfTransfer(uint256 held, uint256 amount) public {
        held = bound(held, 0, SUPPLY);
        _fund(alice, held);
        vm.prank(alice);
        if (amount <= held) {
            assertTrue(token.transfer(alice, amount));
            assertEq(token.balanceOf(alice), held);
        } else {
            vm.expectRevert(abi.encodeWithSelector(StateToken.InsufficientBalance.selector, alice, held, amount));
            token.transfer(alice, amount);
        }
    }

    function test_transferOfMaxUintRevertsEvenForTheWholeSupplyHolder() public {
        vm.expectRevert(abi.encodeWithSelector(StateToken.InsufficientBalance.selector, address(this), SUPPLY, MAX));
        token.transfer(bob, MAX);
        vm.expectRevert(
            abi.encodeWithSelector(StateToken.InsufficientBalance.selector, address(this), SUPPLY, SUPPLY + 1)
        );
        token.transfer(bob, SUPPLY + 1);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_transferOfOneWei() public {
        assertTrue(token.transfer(bob, 1));
        assertEq(token.balanceOf(bob), 1);
        assertEq(token.balanceOf(address(this)), SUPPLY - 1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(StateToken.InsufficientBalance.selector, bob, 1, 2));
        token.transfer(carol, 2);
    }

    /// @dev Zero-address checks come before balance checks: an empty sender still sees ZeroAddress.
    function testFuzz_zeroAddressBeatsBalanceCheck(uint256 amount) public {
        assertEq(token.balanceOf(carol), 0);
        vm.prank(carol);
        vm.expectRevert(StateToken.ZeroAddress.selector);
        token.transfer(address(0), amount);
    }

    // ---------------------------------------------------------------------------------------------
    // Allowance algebra
    // ---------------------------------------------------------------------------------------------

    function testFuzz_approveIsIdempotentAndOverwrites(uint256 a, uint256 b) public {
        vm.startPrank(alice);
        token.approve(bob, a);
        token.approve(bob, a);
        assertEq(token.allowance(alice, bob), a, "re-approving the same value changed it");
        token.approve(bob, b);
        assertEq(token.allowance(alice, bob), b, "approve did not overwrite");
        vm.stopPrank();
        // Approvals are per (owner, spender): nothing leaked to other pairs.
        assertEq(token.allowance(bob, alice), 0);
        assertEq(token.allowance(alice, carol), 0);
        assertEq(token.allowance(carol, bob), 0);
    }

    function testFuzz_increaseThenDecreaseRoundTrips(uint256 start, uint256 delta) public {
        start = bound(start, 0, MAX - 1);
        delta = bound(delta, 0, MAX - start);
        vm.startPrank(alice);
        token.approve(bob, start);
        token.increaseAllowance(bob, delta);
        assertEq(token.allowance(alice, bob), start + delta);
        token.decreaseAllowance(bob, delta);
        assertEq(token.allowance(alice, bob), start, "round trip did not return to the start");
        vm.stopPrank();
    }

    function testFuzz_decreaseAllowanceToExactlyZero(uint256 current) public {
        vm.startPrank(alice);
        token.approve(bob, current);
        assertTrue(token.decreaseAllowance(bob, current));
        assertEq(token.allowance(alice, bob), 0);
        // One more wei below zero is refused.
        vm.expectRevert(abi.encodeWithSelector(StateToken.InsufficientAllowance.selector, bob, 0, 1));
        token.decreaseAllowance(bob, 1);
        vm.stopPrank();
    }

    function testFuzz_increaseAllowanceToExactlyMax(uint256 current) public {
        vm.startPrank(alice);
        token.approve(bob, current);
        assertTrue(token.increaseAllowance(bob, MAX - current));
        assertEq(token.allowance(alice, bob), MAX);
        // One more overflows.
        vm.expectRevert();
        token.increaseAllowance(bob, 1);
        vm.stopPrank();
        assertEq(token.allowance(alice, bob), MAX);
    }

    function testFuzz_increaseFromMaxByZeroIsAllowed(uint256 added) public {
        vm.startPrank(alice);
        token.approve(bob, MAX);
        assertTrue(token.increaseAllowance(bob, 0));
        assertEq(token.allowance(alice, bob), MAX);
        added = bound(added, 1, MAX);
        vm.expectRevert();
        token.increaseAllowance(bob, added);
        vm.stopPrank();
    }

    function test_decreaseAllowanceIsRefusedForUnapprovedPair() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StateToken.InsufficientAllowance.selector, bob, 0, 1));
        token.decreaseAllowance(bob, 1);
        // Decreasing by zero from zero is fine, and emits an Approval of zero.
        vm.prank(alice);
        assertTrue(token.decreaseAllowance(bob, 0));
        assertEq(token.allowance(alice, bob), 0);
    }

    function test_decreaseAllowanceZeroSpenderReverts() public {
        vm.prank(alice);
        vm.expectRevert(StateToken.ZeroAddress.selector);
        token.decreaseAllowance(address(0), 0);
    }

    function testFuzz_allowanceOfUntouchedPairIsZero(address owner, address spender) public view {
        assertEq(token.allowance(owner, spender), 0);
    }

    function testFuzz_balanceOfUntouchedAddressIsZero(address who) public view {
        vm.assume(who != address(this));
        assertEq(token.balanceOf(who), 0);
    }

    // ---------------------------------------------------------------------------------------------
    // The unlimited-allowance sentinel and its boundary
    // ---------------------------------------------------------------------------------------------

    /// @dev MAX is never decremented; MAX - 1 is decremented like any finite value. The sentinel is
    ///      exactly one value wide.
    function testFuzz_sentinelBoundary(uint256 held, uint256 amount) public {
        held = bound(held, 1, SUPPLY);
        amount = bound(amount, 1, held);
        _fund(alice, held);

        vm.prank(alice);
        token.approve(bob, MAX - 1);
        vm.prank(bob);
        token.transferFrom(alice, carol, amount);
        assertEq(token.allowance(alice, bob), MAX - 1 - amount, "MAX - 1 was treated as unlimited");

        vm.prank(alice);
        token.approve(bob, MAX);
        vm.prank(bob);
        token.transferFrom(alice, carol, held - amount);
        assertEq(token.allowance(alice, bob), MAX, "MAX was decremented");
        assertEq(token.balanceOf(carol), held);
        assertEq(token.balanceOf(alice), 0);
    }

    /// @dev Lowering an unlimited allowance by one wei makes it finite, after which it is spent.
    function test_decreaseFromUnlimitedMakesItFinite() public {
        _fund(alice, 10e18);
        vm.startPrank(alice);
        token.approve(bob, MAX);
        token.decreaseAllowance(bob, 1);
        vm.stopPrank();
        assertEq(token.allowance(alice, bob), MAX - 1);
        vm.prank(bob);
        token.transferFrom(alice, carol, 3e18);
        assertEq(token.allowance(alice, bob), MAX - 1 - 3e18);
    }

    /// @dev Unlimited allowance does not bypass the balance check.
    function testFuzz_unlimitedAllowanceStillNeedsBalance(uint256 held, uint256 excess) public {
        held = bound(held, 0, SUPPLY);
        excess = bound(excess, 1, MAX - held);
        _fund(alice, held);
        vm.prank(alice);
        token.approve(bob, MAX);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(StateToken.InsufficientBalance.selector, alice, held, held + excess));
        token.transferFrom(alice, carol, held + excess);
        assertEq(token.allowance(alice, bob), MAX);
        assertEq(token.balanceOf(alice), held);
    }

    /// @dev Allowance is checked before balance: with both short, the allowance error is reported.
    function testFuzz_allowanceCheckedBeforeBalance(uint256 held, uint256 allowed, uint256 amount) public {
        held = bound(held, 0, SUPPLY);
        allowed = bound(allowed, 0, MAX - 1);
        uint256 floor = held > allowed ? held : allowed;
        amount = bound(amount, floor + 1, MAX);
        _fund(alice, held);
        vm.prank(alice);
        token.approve(bob, allowed);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(StateToken.InsufficientAllowance.selector, bob, allowed, amount));
        token.transferFrom(alice, carol, amount);
    }

    // ---------------------------------------------------------------------------------------------
    // transferFrom corner identities: spender == owner, from == to, revocation
    // ---------------------------------------------------------------------------------------------

    /// @dev An owner calling transferFrom on itself still needs a self-allowance: holding the
    ///      tokens is not enough, which keeps the two paths cleanly separated.
    function testFuzz_ownerAsSpenderNeedsSelfAllowance(uint256 held, uint256 amount) public {
        held = bound(held, 1, SUPPLY);
        amount = bound(amount, 1, held);
        _fund(alice, held);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StateToken.InsufficientAllowance.selector, alice, 0, amount));
        token.transferFrom(alice, bob, amount);

        vm.startPrank(alice);
        token.approve(alice, amount);
        assertTrue(token.transferFrom(alice, bob, amount));
        vm.stopPrank();
        assertEq(token.allowance(alice, alice), 0);
        assertEq(token.balanceOf(bob), amount);
        assertEq(token.balanceOf(alice), held - amount);
    }

    /// @dev from == to through transferFrom: the balance is untouched but the allowance is spent,
    ///      so a spender cannot use a self-destination to probe or drain anything for free.
    function testFuzz_transferFromToSameAccountSpendsAllowanceOnly(uint256 held, uint256 amount) public {
        held = bound(held, 0, SUPPLY);
        amount = bound(amount, 0, held);
        _fund(alice, held);
        vm.prank(alice);
        token.approve(bob, held);
        vm.prank(bob);
        assertTrue(token.transferFrom(alice, alice, amount));
        assertEq(token.balanceOf(alice), held, "self-destination changed the balance");
        assertEq(token.allowance(alice, bob), held - amount, "self-destination did not spend allowance");
    }

    /// @dev The spender may route to itself; the allowance still bounds it.
    function testFuzz_spenderCanPullToItselfWithinAllowance(uint256 held, uint256 allowed, uint256 amount) public {
        held = bound(held, 1, SUPPLY);
        allowed = bound(allowed, 1, held);
        amount = bound(amount, 1, allowed);
        _fund(alice, held);
        vm.prank(alice);
        token.approve(bob, allowed);
        vm.startPrank(bob);
        assertTrue(token.transferFrom(alice, bob, amount));
        assertEq(token.balanceOf(bob), amount);
        if (allowed - amount < held - amount) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    StateToken.InsufficientAllowance.selector, bob, allowed - amount, allowed - amount + 1
                )
            );
            token.transferFrom(alice, bob, allowed - amount + 1);
        }
        vm.stopPrank();
    }

    /// @dev approve(spender, 0) revokes: nothing can be pulled afterwards, not even one wei.
    function testFuzz_revocationIsImmediate(uint256 allowed) public {
        allowed = bound(allowed, 1, MAX);
        _fund(alice, 10e18);
        vm.startPrank(alice);
        token.approve(bob, allowed);
        token.approve(bob, 0);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(StateToken.InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(alice, carol, 1);
        assertEq(token.balanceOf(alice), 10e18);
    }

    /// @dev Allowance is fully consumable in repeated small pulls and then exactly exhausted.
    function testFuzz_allowanceExhaustsExactly(uint256 allowed, uint8 parts) public {
        allowed = bound(allowed, 1, SUPPLY);
        parts = uint8(bound(parts, 1, 16));
        _fund(alice, allowed);
        vm.prank(alice);
        token.approve(bob, allowed);
        uint256 each = allowed / parts;
        uint256 spent;
        vm.startPrank(bob);
        for (uint256 i; i < parts; ++i) {
            token.transferFrom(alice, carol, each);
            spent += each;
        }
        token.transferFrom(alice, carol, allowed - spent);
        assertEq(token.allowance(alice, bob), 0);
        assertEq(token.balanceOf(carol), allowed);
        vm.expectRevert(abi.encodeWithSelector(StateToken.InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(alice, carol, 1);
        vm.stopPrank();
    }

    /// @dev EIP-20: a zero-value transfer is a normal transfer and fires the event. The contract
    ///      applies this literally: `transferFrom(anyone, to, 0)` succeeds without an allowance and
    ///      even with `from == address(0)`, emitting `Transfer(0x0, to, 0)`. Nothing moves and the
    ///      supply is unaffected; indexers that treat a Transfer from the zero address as a mint
    ///      will see a zero-value one. Recorded here as observed behaviour, not as a guarantee.
    function testFuzz_zeroValueTransferFromNeedsNoAllowance(address from, address to) public {
        vm.assume(to != address(0));
        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);
        vm.recordLogs();
        vm.prank(carol);
        assertTrue(token.transferFrom(from, to, 0));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 2, "expected an Approval(0) and a Transfer(0)");
        assertEq(logs[1].topics[0], TRANSFER_SIG);
        assertEq(abi.decode(logs[1].data, (uint256)), 0);
        assertEq(token.balanceOf(from), fromBefore);
        assertEq(token.balanceOf(to), toBefore);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.allowance(from, carol), 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Event shape
    // ---------------------------------------------------------------------------------------------

    /// @dev A finite allowance spend emits Approval(new allowance) and then Transfer; an unlimited
    ///      one emits only Transfer. Integrators relying on the Approval log to track allowances
    ///      need to know the unlimited case stays silent.
    function testFuzz_transferFromEventShape(uint256 held, uint256 amount, bool unlimited) public {
        held = bound(held, 1, SUPPLY);
        amount = bound(amount, 1, held);
        _fund(alice, held);
        vm.prank(alice);
        token.approve(bob, unlimited ? MAX : held);

        vm.recordLogs();
        vm.prank(bob);
        token.transferFrom(alice, carol, amount);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        if (unlimited) {
            assertEq(logs.length, 1, "unlimited spend should emit only Transfer");
            assertEq(logs[0].topics[0], TRANSFER_SIG);
        } else {
            assertEq(logs.length, 2, "finite spend should emit Approval then Transfer");
            assertEq(logs[0].topics[0], APPROVAL_SIG);
            assertEq(address(uint160(uint256(logs[0].topics[1]))), alice);
            assertEq(address(uint160(uint256(logs[0].topics[2]))), bob);
            assertEq(abi.decode(logs[0].data, (uint256)), held - amount);
            assertEq(logs[1].topics[0], TRANSFER_SIG);
        }
        assertEq(address(uint160(uint256(logs[logs.length - 1].topics[1]))), alice);
        assertEq(address(uint160(uint256(logs[logs.length - 1].topics[2]))), carol);
        assertEq(abi.decode(logs[logs.length - 1].data, (uint256)), amount);
    }

    function testFuzz_transferEmitsExactlyOneEvent(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.recordLogs();
        token.transfer(bob, amount);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], TRANSFER_SIG);
        assertEq(logs[0].emitter, address(token));
        assertEq(address(uint160(uint256(logs[0].topics[1]))), address(this));
        assertEq(address(uint160(uint256(logs[0].topics[2]))), bob);
        assertEq(abi.decode(logs[0].data, (uint256)), amount);
    }

    function testFuzz_allowanceChangesEmitExactlyOneApproval(uint256 start, uint256 delta) public {
        start = bound(start, 0, MAX - 1);
        delta = bound(delta, 0, MAX - start);
        vm.startPrank(alice);
        token.approve(bob, start);

        vm.recordLogs();
        token.increaseAllowance(bob, delta);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], APPROVAL_SIG);
        assertEq(abi.decode(logs[0].data, (uint256)), start + delta);

        vm.recordLogs();
        token.decreaseAllowance(bob, delta);
        logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], APPROVAL_SIG);
        assertEq(abi.decode(logs[0].data, (uint256)), start);
        vm.stopPrank();
    }

    /// @dev A reverted call leaves no event behind (state and logs roll back together).
    function test_failedCallsEmitNothing() public {
        vm.recordLogs();
        vm.prank(carol);
        (bool ok,) = address(token).call(abi.encodeCall(StateToken.transfer, (bob, 1)));
        assertFalse(ok);
        vm.prank(carol);
        (ok,) = address(token).call(abi.encodeCall(StateToken.transferFrom, (alice, bob, 1)));
        assertFalse(ok);
        assertEq(vm.getRecordedLogs().length, 0, "a reverted call left a log");
    }

    // ---------------------------------------------------------------------------------------------
    // Deployments are independent and deterministic
    // ---------------------------------------------------------------------------------------------

    function test_twoDeploymentsDoNotShareState() public {
        vm.prank(alice);
        StateToken other = new StateToken();
        assertEq(other.balanceOf(alice), SUPPLY);
        assertEq(other.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(alice), 0);

        token.transfer(bob, 5e18);
        assertEq(other.balanceOf(bob), 0, "a transfer on one token touched the other");
        vm.prank(alice);
        other.approve(bob, 1);
        assertEq(token.allowance(alice, bob), 0, "an approval on one token touched the other");
        assertEq(other.totalSupply(), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_anyDeployerGetsTheWholeSupply(address deployer) public {
        vm.assume(deployer != address(0) && deployer.code.length == 0);
        vm.assume(uint160(deployer) > 0xff); // not a precompile
        vm.prank(deployer);
        StateToken fresh = new StateToken();
        assertEq(fresh.balanceOf(deployer), SUPPLY);
        assertEq(fresh.totalSupply(), SUPPLY);
        assertEq(address(fresh).code, address(token).code, "runtime differs between deployments");
    }

    function test_creationCodeTakesNoArguments() public {
        // Deploying with trailing bytes would still succeed (the constructor ignores them); what
        // matters is that the plain creation code, with nothing appended, deploys the same runtime.
        bytes memory code = type(StateToken).creationCode;
        address deployed;
        assembly ("memory-safe") {
            deployed := create(0, add(code, 32), mload(code))
        }
        assertTrue(deployed != address(0), "bare creation code failed");
        assertEq(deployed.code, address(token).code);
        assertEq(StateToken(deployed).balanceOf(address(this)), SUPPLY);
    }
}
