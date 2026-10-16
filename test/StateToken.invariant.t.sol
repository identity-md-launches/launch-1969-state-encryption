// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StateToken} from "../src/StateToken.sol";

/// @notice Deploys the token from a contract address so the supply lands where the launch puts it:
///         on the factory. The handler drives this stub when the factory is the chosen actor.
contract FactoryActor {
    StateToken public token;

    function deployToken() external returns (StateToken) {
        token = new StateToken();
        return token;
    }
}

/// @notice Drives the token with random, bounded call sequences from a fixed set of actors and
///         keeps ghost accounting of what every actor should hold and what every allowance should
///         be. Every function here either succeeds or proves the exact revert it expected; the
///         handler itself never reverts, so the invariant runner is configured to fail on revert.
contract StateTokenHandler is Test {
    uint256 constant SUPPLY = 1_000_000 * 1e18;

    StateToken public immutable token;
    address public immutable factory;

    /// @dev Everyone who can ever hold a balance: the factory (deployer), five ordinary actors and
    ///      three "strangers" who start with nothing and are the targets of the unclamped calls.
    address[] public actors;
    mapping(address => bool) public isActor;

    // ---------------------------------------------------------------------------------------------
    // Ghost state
    // ---------------------------------------------------------------------------------------------

    /// @dev Cumulative tokens received by / sent from each actor through successful transfers.
    mapping(address => uint256) public ghost_received;
    mapping(address => uint256) public ghost_sent;
    /// @dev What the allowance between two actors should be after the sequence so far.
    mapping(address => mapping(address => uint256)) public ghost_allowance;
    /// @dev Cumulative volume moved by successful transfers (both kinds).
    uint256 public ghost_volume;
    /// @dev Call counters, to see in the logs that every path was actually exercised.
    uint256 public calls_transfer;
    uint256 public calls_transferFrom;
    uint256 public calls_approve;
    uint256 public calls_increase;
    uint256 public calls_decrease;
    uint256 public calls_expectedReverts;
    uint256 public calls_unclamped;
    uint256 public calls_unclampedSucceeded;

    constructor(StateToken token_, address factory_) {
        token = token_;
        factory = factory_;
        _addActor(factory_);
        _addActor(makeAddr("alice"));
        _addActor(makeAddr("bob"));
        _addActor(makeAddr("carol"));
        _addActor(makeAddr("dave"));
        _addActor(makeAddr("erin"));
        _addActor(makeAddr("stranger0"));
        _addActor(makeAddr("stranger1"));
        _addActor(makeAddr("stranger2"));
    }

    function _addActor(address a) private {
        actors.push(a);
        isActor[a] = true;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }

    // ---------------------------------------------------------------------------------------------
    // Happy paths with bounded inputs: must never revert, must move exactly what was asked
    // ---------------------------------------------------------------------------------------------

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, token.balanceOf(from));

        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);

        vm.prank(from);
        bool ok = token.transfer(to, amount);
        assertTrue(ok, "transfer returned false");

        if (from == to) {
            assertEq(token.balanceOf(from), fromBefore, "self-transfer changed the balance");
        } else {
            assertEq(token.balanceOf(from), fromBefore - amount, "sender debited wrongly");
            assertEq(token.balanceOf(to), toBefore + amount, "recipient credited wrongly");
        }
        ghost_sent[from] += amount;
        ghost_received[to] += amount;
        ghost_volume += amount;
        ++calls_transfer;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        // Keep the unlimited sentinel reachable: one in eight approvals is uint256.max.
        if (amount % 8 == 0) amount = type(uint256).max;

        vm.prank(owner);
        assertTrue(token.approve(spender, amount), "approve returned false");
        assertEq(token.allowance(owner, spender), amount, "approve did not set the allowance");
        ghost_allowance[owner][spender] = amount;
        ++calls_approve;
    }

    function increaseAllowance(uint256 ownerSeed, uint256 spenderSeed, uint256 added) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 current = token.allowance(owner, spender);
        added = bound(added, 0, type(uint256).max - current);

        vm.prank(owner);
        assertTrue(token.increaseAllowance(spender, added), "increaseAllowance returned false");
        assertEq(token.allowance(owner, spender), current + added, "increase landed on the wrong value");
        ghost_allowance[owner][spender] = current + added;
        ++calls_increase;
    }

    function decreaseAllowance(uint256 ownerSeed, uint256 spenderSeed, uint256 subtracted) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 current = token.allowance(owner, spender);
        subtracted = bound(subtracted, 0, current);

        vm.prank(owner);
        assertTrue(token.decreaseAllowance(spender, subtracted), "decreaseAllowance returned false");
        assertEq(token.allowance(owner, spender), current - subtracted, "decrease landed on the wrong value");
        ghost_allowance[owner][spender] = current - subtracted;
        ++calls_decrease;
    }

    function transferFrom(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 amount) external {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);
        uint256 allowed = token.allowance(owner, spender);
        uint256 held = token.balanceOf(owner);
        amount = bound(amount, 0, held < allowed ? held : allowed);

        uint256 ownerBefore = token.balanceOf(owner);
        uint256 toBefore = token.balanceOf(to);
        uint256 spenderBefore = token.balanceOf(spender);

        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount), "transferFrom returned false");

        if (owner == to) {
            assertEq(token.balanceOf(owner), ownerBefore, "self transferFrom changed the balance");
        } else {
            assertEq(token.balanceOf(owner), ownerBefore - amount, "owner debited wrongly");
            assertEq(token.balanceOf(to), toBefore + amount, "recipient credited wrongly");
        }
        if (spender != owner && spender != to) {
            assertEq(token.balanceOf(spender), spenderBefore, "the spender's own balance moved");
        }
        if (allowed == type(uint256).max) {
            assertEq(token.allowance(owner, spender), type(uint256).max, "unlimited allowance was decremented");
        } else {
            assertEq(token.allowance(owner, spender), allowed - amount, "allowance not spent exactly");
            ghost_allowance[owner][spender] = allowed - amount;
        }
        ghost_sent[owner] += amount;
        ghost_received[to] += amount;
        ghost_volume += amount;
        ++calls_transferFrom;
    }

    // ---------------------------------------------------------------------------------------------
    // Failure paths: every one must revert with the exact error and leave state untouched
    // ---------------------------------------------------------------------------------------------

    function transferAboveBalanceReverts(uint256 fromSeed, uint256 toSeed, uint256 excess) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 held = token.balanceOf(from);
        excess = bound(excess, 1, type(uint256).max - held);
        uint256 toBefore = token.balanceOf(to);

        vm.prank(from);
        vm.expectRevert(abi.encodeWithSelector(StateToken.InsufficientBalance.selector, from, held, held + excess));
        token.transfer(to, held + excess);

        assertEq(token.balanceOf(from), held, "a failed transfer debited the sender");
        assertEq(token.balanceOf(to), toBefore, "a failed transfer credited the recipient");
        ++calls_expectedReverts;
    }

    function transferToZeroReverts(uint256 fromSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        uint256 held = token.balanceOf(from);
        // Any amount, including zero and more than held: the zero-address check comes first.
        vm.prank(from);
        vm.expectRevert(StateToken.ZeroAddress.selector);
        token.transfer(address(0), amount);
        assertEq(token.balanceOf(from), held);
        assertEq(token.balanceOf(address(0)), 0);
        ++calls_expectedReverts;
    }

    function approveZeroSpenderReverts(uint256 ownerSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        vm.startPrank(owner);
        vm.expectRevert(StateToken.ZeroAddress.selector);
        token.approve(address(0), amount);
        vm.expectRevert(StateToken.ZeroAddress.selector);
        token.increaseAllowance(address(0), amount);
        vm.stopPrank();
        assertEq(token.allowance(owner, address(0)), 0);
        ++calls_expectedReverts;
    }

    function increaseAllowanceOverflowReverts(uint256 ownerSeed, uint256 spenderSeed, uint256 added) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 current = token.allowance(owner, spender);
        if (current == 0) {
            // Nothing can overflow from zero; make the sentinel the starting point instead.
            vm.prank(owner);
            token.approve(spender, type(uint256).max);
            ghost_allowance[owner][spender] = type(uint256).max;
            current = type(uint256).max;
        }
        added = bound(added, type(uint256).max - current + 1, type(uint256).max);

        vm.prank(owner);
        vm.expectRevert(); // checked arithmetic panic 0x11
        token.increaseAllowance(spender, added);
        assertEq(token.allowance(owner, spender), current, "a failed increase changed the allowance");
        ++calls_expectedReverts;
    }

    function decreaseAllowanceBelowZeroReverts(uint256 ownerSeed, uint256 spenderSeed, uint256 excess) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 current = token.allowance(owner, spender);
        if (current == type(uint256).max) {
            // Nothing exceeds the sentinel; pin a finite allowance first.
            current = bound(excess, 0, SUPPLY);
            vm.prank(owner);
            token.approve(spender, current);
            ghost_allowance[owner][spender] = current;
        }
        excess = bound(excess, 1, type(uint256).max - current);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(StateToken.InsufficientAllowance.selector, spender, current, current + excess)
        );
        token.decreaseAllowance(spender, current + excess);
        assertEq(token.allowance(owner, spender), current, "a failed decrease changed the allowance");
        ++calls_expectedReverts;
    }

    function transferFromAboveAllowanceReverts(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 excess)
        external
    {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);
        uint256 allowed = token.allowance(owner, spender);
        if (allowed == type(uint256).max) {
            // Unlimited cannot be exceeded; pin it to a finite value first.
            allowed = bound(excess, 0, SUPPLY);
            vm.prank(owner);
            token.approve(spender, allowed);
            ghost_allowance[owner][spender] = allowed;
        }
        excess = bound(excess, 1, type(uint256).max - allowed);
        uint256 ownerBefore = token.balanceOf(owner);
        uint256 toBefore = token.balanceOf(to);

        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(StateToken.InsufficientAllowance.selector, spender, allowed, allowed + excess)
        );
        token.transferFrom(owner, to, allowed + excess);

        assertEq(token.allowance(owner, spender), allowed, "a failed transferFrom spent allowance");
        assertEq(token.balanceOf(owner), ownerBefore);
        assertEq(token.balanceOf(to), toBefore);
        ++calls_expectedReverts;
    }

    function transferFromAboveBalanceReverts(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 excess)
        external
    {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);
        uint256 held = token.balanceOf(owner);
        excess = bound(excess, 1, type(uint256).max - held);
        uint256 amount = held + excess;
        // Allowance covers it, so the only thing in the way is the balance.
        vm.prank(owner);
        token.approve(spender, type(uint256).max);
        ghost_allowance[owner][spender] = type(uint256).max;
        uint256 toBefore = token.balanceOf(to);

        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(StateToken.InsufficientBalance.selector, owner, held, amount));
        token.transferFrom(owner, to, amount);

        assertEq(token.balanceOf(owner), held);
        assertEq(token.balanceOf(to), toBefore);
        assertEq(token.allowance(owner, spender), type(uint256).max);
        ++calls_expectedReverts;
    }

    /// @dev The deployer is the address a token would most plausibly trust. With no allowance it
    ///      must be just another caller: it cannot pull from a holder.
    function factoryCannotPullWithoutAllowance(uint256 ownerSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        if (owner == factory) return;
        amount = bound(amount, 1, type(uint256).max);
        uint256 allowed = token.allowance(owner, factory);
        if (allowed == type(uint256).max || allowed >= amount) {
            vm.prank(owner);
            token.approve(factory, 0);
            ghost_allowance[owner][factory] = 0;
            allowed = 0;
        }
        uint256 held = token.balanceOf(owner);
        vm.prank(factory);
        vm.expectRevert(abi.encodeWithSelector(StateToken.InsufficientAllowance.selector, factory, allowed, amount));
        token.transferFrom(owner, factory, amount);
        assertEq(token.balanceOf(owner), held);
        ++calls_expectedReverts;
    }

    // ---------------------------------------------------------------------------------------------
    // Unclamped: raw arguments, the outcome is observed rather than assumed. Whatever happens, the
    // ghost model is updated only on success, so the invariants still have to hold afterwards.
    // ---------------------------------------------------------------------------------------------

    function transferUnclamped(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 held = token.balanceOf(from);
        // Raw amounts are almost always above the balance; fold a third of them into range so the
        // success branch is reached too. The outcome is still observed, never assumed.
        if (amount % 3 == 0) amount = amount % (held + 1);
        vm.prank(from);
        try token.transfer(to, amount) returns (bool ok) {
            assertTrue(ok);
            assertLe(amount, held, "a transfer above the balance succeeded");
            ghost_sent[from] += amount;
            ghost_received[to] += amount;
            ghost_volume += amount;
            ++calls_unclampedSucceeded;
        } catch (bytes memory reason) {
            assertGt(amount, held, "a transfer within the balance reverted");
            assertEq(
                reason,
                abi.encodeWithSelector(StateToken.InsufficientBalance.selector, from, held, amount),
                "wrong error"
            );
        }
        ++calls_unclamped;
    }

    function transferFromUnclamped(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 amount) external {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);
        uint256 allowed = token.allowance(owner, spender);
        uint256 held = token.balanceOf(owner);
        if (amount % 3 == 0) amount = amount % ((held < allowed ? held : allowed) + 1);
        vm.prank(spender);
        try token.transferFrom(owner, to, amount) returns (bool ok) {
            assertTrue(ok);
            assertTrue(allowed == type(uint256).max || amount <= allowed, "spent more than allowed");
            assertLe(amount, held, "pulled more than held");
            if (allowed != type(uint256).max) ghost_allowance[owner][spender] = allowed - amount;
            ghost_sent[owner] += amount;
            ghost_received[to] += amount;
            ghost_volume += amount;
            ++calls_unclampedSucceeded;
        } catch (bytes memory reason) {
            if (allowed != type(uint256).max && amount > allowed) {
                assertEq(
                    reason,
                    abi.encodeWithSelector(StateToken.InsufficientAllowance.selector, spender, allowed, amount),
                    "wrong error for excess allowance"
                );
            } else {
                assertGt(amount, held, "a covered transferFrom reverted");
                assertEq(
                    reason,
                    abi.encodeWithSelector(StateToken.InsufficientBalance.selector, owner, held, amount),
                    "wrong error for excess balance"
                );
            }
            assertEq(token.allowance(owner, spender), allowed, "a failed transferFrom touched the allowance");
        }
        ++calls_unclamped;
    }

    /// @dev Calls that must not exist. If any of them ever answers, the invariants over supply and
    ///      balances are what catch the consequence.
    function privilegedCallsDoNothing(uint256 callerSeed, uint256 targetSeed, uint256 which) external {
        address caller = _actor(callerSeed);
        address target = _actor(targetSeed);
        string[8] memory signatures = [
            "mint(address,uint256)",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "pause()",
            "freeze(address)",
            "blacklist(address)",
            "seize(address)",
            "setOwner(address)"
        ];
        bytes memory data = abi.encodeWithSignature(signatures[which % signatures.length], target, SUPPLY);
        vm.prank(caller);
        (bool ok,) = address(token).call(data);
        assertFalse(ok, "a privileged selector answered");
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract StateTokenInvariantTest is Test {
    uint256 constant SUPPLY = 1_000_000 * 1e18;

    FactoryActor factory;
    StateToken token;
    StateTokenHandler handler;

    function setUp() public {
        factory = new FactoryActor();
        token = factory.deployToken();
        handler = new StateTokenHandler(token, address(factory));
        targetContract(address(handler));
    }

    /// @dev The fixed supply never changes: nothing mints, nothing burns.
    function invariant_supplyIsConstant() public view {
        assertEq(token.totalSupply(), SUPPLY, "supply changed");
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
    }

    /// @dev Conservation: every token is held by exactly one of the actors, and nowhere else.
    function invariant_balancesSumToSupply() public view {
        uint256 sum;
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            uint256 bal = token.balanceOf(handler.actors(i));
            assertLe(bal, SUPPLY, "an actor holds more than the supply");
            sum += bal;
        }
        assertEq(sum, SUPPLY, "balances do not sum to the supply");
    }

    /// @dev Nothing leaks to the zero address or to the token itself, which cannot send it back.
    function invariant_noTokensStrandedAtSpecialAddresses() public view {
        assertEq(token.balanceOf(address(0)), 0, "tokens at the zero address");
        assertEq(token.balanceOf(address(token)), 0, "tokens at the token contract");
        assertEq(token.balanceOf(address(handler)), 0, "tokens at the handler");
        assertEq(address(token).balance, 0, "the token holds ether");
    }

    /// @dev Every actor's balance is exactly what it started with plus what flowed in minus what
    ///      flowed out through successful calls. Nobody gained or lost anything else.
    function invariant_ghostFlowsExplainEveryBalance() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            address a = handler.actors(i);
            uint256 initial = a == address(factory) ? SUPPLY : 0;
            assertEq(
                token.balanceOf(a),
                initial + handler.ghost_received(a) - handler.ghost_sent(a),
                "balance not explained by the recorded flows"
            );
        }
    }

    /// @dev Allowances are exactly what the model says: set by approve, moved by increase and
    ///      decrease, spent by transferFrom unless unlimited, and never changed by anything else.
    function invariant_allowancesMatchModel() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            address owner = handler.actors(i);
            for (uint256 j; j < n; ++j) {
                address spender = handler.actors(j);
                assertEq(token.allowance(owner, spender), handler.ghost_allowance(owner, spender), "allowance drifted");
            }
            assertEq(token.allowance(owner, address(0)), 0, "allowance granted to the zero address");
        }
    }

    /// @dev Transfers only ever shuffle: total volume moved can exceed the supply (tokens circulate)
    ///      but no single actor can have received more than it was ever possible to send.
    function invariant_receivedNeverExceedsVolume() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            address a = handler.actors(i);
            assertLe(handler.ghost_received(a), handler.ghost_volume(), "received more than ever moved");
            assertLe(handler.ghost_sent(a), handler.ghost_volume(), "sent more than ever moved");
        }
    }

    /// @dev Metadata is pure and cannot drift under any sequence.
    function invariant_metadataIsFixed() public view {
        assertEq(token.name(), "State Encryption");
        assertEq(token.symbol(), "STATE");
        assertEq(token.decimals(), 18);
    }

    function afterInvariant() public {
        // Visible with -vv: proves the handler's paths were actually driven, not just declared.
        emit log_named_uint("transfer", handler.calls_transfer());
        emit log_named_uint("transferFrom", handler.calls_transferFrom());
        emit log_named_uint("approve", handler.calls_approve());
        emit log_named_uint("increaseAllowance", handler.calls_increase());
        emit log_named_uint("decreaseAllowance", handler.calls_decrease());
        emit log_named_uint("expected reverts", handler.calls_expectedReverts());
        emit log_named_uint("unclamped", handler.calls_unclamped());
        emit log_named_uint("unclamped succeeded", handler.calls_unclampedSucceeded());
    }
}
