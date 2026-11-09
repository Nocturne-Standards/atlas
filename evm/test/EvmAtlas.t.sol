// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {AccountLib} from "../src/AccountLib.sol";
import {EvmAtlas} from "../src/EvmAtlas.sol";
import {LocatorLib} from "../src/LocatorLib.sol";

contract EvmAtlasTest is Test {
    uint256 internal constant CHAIN = 745;
    bytes32 internal constant ORACLE = bytes32("evm.sound.oracle");
    bytes32 internal constant NAV = bytes32("native.attested-nav");
    bytes32 internal constant LINK_ID = 0x09e12d5d0af3935ea0c93f4b4eef3a88a24b0de28cd89fd54114c9fb85ef7fdb;
    // keccak256(LINK_ID)[12:], the formula in dusk-network/duskevm-sdk
    // `duskContractIdToEvmAddress`.
    address internal constant LINK_SENDER = 0xb8c7d103E7f68028cD232bf5a30e2B95c6e89b61;

    EvmAtlas internal atlas;
    address internal deployer = makeAddr("deployer");
    address internal guardian = makeAddr("guardian");
    address internal next = makeAddr("next");

    function setUp() public {
        vm.chainId(CHAIN);
        vm.prank(deployer);
        atlas = new EvmAtlas(CHAIN);
    }

    function test_constructor_rejectsWrongChain() public {
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(EvmAtlas.WrongChain.selector, CHAIN, 1));
        new EvmAtlas(CHAIN);
    }

    function test_constructor_recordsChainAndDeployer() public view {
        assertEq(atlas.chainId(), CHAIN);
        assertEq(atlas.deployer(), deployer);
    }

    function test_initGuardian_onlyDeployerOnce_rejectsZero() public {
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(EvmAtlas.NotDeployer.selector, guardian));
        atlas.initGuardian(guardian, 10);

        vm.prank(deployer);
        vm.expectRevert(EvmAtlas.ZeroAddress.selector);
        atlas.initGuardian(address(0), 10);

        vm.expectEmit(address(atlas));
        emit EvmAtlas.GuardianSet(guardian);
        vm.expectEmit(address(atlas));
        emit EvmAtlas.TimelockSet(10);
        vm.prank(deployer);
        atlas.initGuardian(guardian, 10);

        vm.prank(deployer);
        vm.expectRevert(EvmAtlas.AlreadyInitialized.selector);
        atlas.initGuardian(next, 10);

        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(EvmAtlas.NotGuardian.selector, deployer));
        atlas.setService(ORACLE, 1, _addr(makeAddr("oracle")));
    }

    function test_setService_immediate_andTypedReads() public {
        _init(10);
        address oracle = makeAddr("oracle");
        vm.prank(guardian);
        atlas.setService(ORACLE, 1, _addr(oracle));

        (uint8 kind, bytes32 data) = atlas.resolve(ORACLE);
        assertEq(kind, atlas.KIND_EVM_ADDRESS());
        assertEq(data, _addr(oracle));
        assertEq(atlas.resolveAddress(ORACLE), oracle);

        vm.prank(guardian);
        atlas.setService(NAV, 2, LINK_ID);
        assertEq(atlas.resolveNativeId(NAV), LINK_ID);
        assertEq(atlas.unaliasedSender(NAV), LINK_SENDER);
    }

    function test_setService_rejectsBadLocators() public {
        _init(10);
        vm.startPrank(guardian);
        vm.expectRevert(LocatorLib.EmptyName.selector);
        atlas.setService(bytes32(0), 1, _addr(guardian));

        vm.expectRevert(abi.encodeWithSelector(LocatorLib.BadKind.selector, uint8(9)));
        atlas.setService(ORACLE, 9, _addr(guardian));

        vm.expectRevert(LocatorLib.ZeroLocator.selector);
        atlas.setService(ORACLE, 1, bytes32(0));

        vm.expectRevert(LocatorLib.ZeroLocator.selector);
        atlas.setService(NAV, 2, bytes32(0));

        bytes32 dirty = _addr(guardian) | bytes32(uint256(1) << 160);
        vm.expectRevert(abi.encodeWithSelector(LocatorLib.DirtyAddress.selector, dirty));
        atlas.setService(ORACLE, 1, dirty);
        vm.stopPrank();

        (uint8 kind, bytes32 data) = atlas.resolve(ORACLE);
        assertEq(kind, 0);
        assertEq(data, bytes32(0));
    }

    function test_setService_rejectsUnchangedLocator() public {
        _init(10);
        bytes32 data = _addr(makeAddr("oracle"));
        vm.startPrank(guardian);
        atlas.setService(ORACLE, 1, data);

        vm.expectRevert(EvmAtlas.Unchanged.selector);
        atlas.setService(ORACLE, 1, data);

        atlas.setService(ORACLE, 1, _addr(makeAddr("other")));
        atlas.setService(ORACLE, 2, LINK_ID);
        vm.stopPrank();

        assertEq(atlas.resolveNativeId(ORACLE), LINK_ID);
    }

    function test_setService_rejectsNonGuardian() public {
        _init(10);
        vm.prank(next);
        vm.expectRevert(abi.encodeWithSelector(EvmAtlas.NotGuardian.selector, next));
        atlas.setService(ORACLE, 1, _addr(next));
    }

    function test_setService_strangerBadKindIsNotGuardian() public {
        _init(10);
        vm.prank(next);
        vm.expectRevert(abi.encodeWithSelector(EvmAtlas.NotGuardian.selector, next));
        atlas.setService(ORACLE, 9, _addr(next));
    }

    function test_timelockCap_initAndSchedule() public {
        uint64 cap = atlas.MAX_TIMELOCK_BLOCKS();
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(EvmAtlas.TimelockTooLong.selector, cap + 1, cap));
        atlas.initGuardian(guardian, cap + 1);

        vm.prank(deployer);
        atlas.initGuardian(guardian, cap);
        assertEq(atlas.timelockBlocks(), cap);

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(EvmAtlas.TimelockTooLong.selector, cap + 1, cap));
        atlas.setTimelock(cap + 1);
        (uint8 changeKind,,,) = atlas.pending();
        assertEq(changeKind, 0);
    }

    function test_typedReads_missingAndKindMismatch() public {
        _init(10);
        vm.expectRevert(abi.encodeWithSelector(EvmAtlas.NotFound.selector, ORACLE));
        atlas.resolveAddress(ORACLE);
        vm.expectRevert(abi.encodeWithSelector(EvmAtlas.NotFound.selector, NAV));
        atlas.unaliasedSender(NAV);

        vm.prank(guardian);
        atlas.setService(NAV, 2, LINK_ID);
        vm.expectRevert(abi.encodeWithSelector(EvmAtlas.KindMismatch.selector, atlas.KIND_NATIVE_ID()));
        atlas.resolveAddress(NAV);

        vm.prank(guardian);
        atlas.setService(ORACLE, 1, _addr(guardian));
        vm.expectRevert(abi.encodeWithSelector(EvmAtlas.KindMismatch.selector, atlas.KIND_EVM_ADDRESS()));
        atlas.resolveNativeId(ORACLE);
        vm.expectRevert(abi.encodeWithSelector(EvmAtlas.KindMismatch.selector, atlas.KIND_EVM_ADDRESS()));
        atlas.unaliasedSender(ORACLE);
    }

    function test_repoint_mayChangeKind() public {
        _init(10);
        vm.startPrank(guardian);
        atlas.setService(ORACLE, 1, _addr(guardian));
        atlas.setService(ORACLE, 2, LINK_ID);
        vm.stopPrank();
        assertEq(atlas.resolveNativeId(ORACLE), LINK_ID);
        vm.expectRevert(abi.encodeWithSelector(EvmAtlas.KindMismatch.selector, atlas.KIND_NATIVE_ID()));
        atlas.resolveAddress(ORACLE);
    }

    function test_setGuardian_waits_serviceWriteStillLands() public {
        _init(10);
        uint64 at = uint64(block.number + 10);
        vm.expectEmit(address(atlas));
        emit EvmAtlas.PendingScheduled(atlas.CHANGE_GUARDIAN(), next, 0, at);
        vm.prank(guardian);
        atlas.setGuardian(next);

        vm.prank(guardian);
        atlas.setService(ORACLE, 1, _addr(makeAddr("oracle")));
        assertEq(atlas.resolveAddress(ORACLE), makeAddr("oracle"));

        (uint8 changeKind, address scheduled,, uint64 executeAt) = atlas.pending();
        assertEq(changeKind, atlas.CHANGE_GUARDIAN());
        assertEq(scheduled, next);
        assertEq(executeAt, at);
        assertEq(atlas.guardian(), guardian);

        vm.prank(next);
        vm.expectRevert(abi.encodeWithSelector(EvmAtlas.NotGuardian.selector, next));
        atlas.setService(NAV, 2, LINK_ID);

        vm.roll(block.number + 9);
        vm.expectRevert(abi.encodeWithSelector(EvmAtlas.TooEarly.selector, at, block.number));
        atlas.executePending();

        // The delay alone is not enough: the incoming guardian has to accept.
        vm.roll(at);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(EvmAtlas.NotAccepted.selector);
        atlas.executePending();
        vm.prank(next);
        atlas.acceptGuardian();
        assertEq(atlas.guardian(), next);
        (changeKind,,,) = atlas.pending();
        assertEq(changeKind, 0);

        vm.prank(next);
        atlas.setService(NAV, 2, LINK_ID);
        assertEq(atlas.resolveNativeId(NAV), LINK_ID);
    }

    function test_secondSchedule_revertsAndUnchangedWritesNothing() public {
        _init(10);
        vm.startPrank(guardian);
        vm.expectRevert(EvmAtlas.Unchanged.selector);
        atlas.setGuardian(guardian);
        vm.expectRevert(EvmAtlas.ZeroAddress.selector);
        atlas.setGuardian(address(0));
        atlas.setGuardian(next);
        vm.expectRevert(EvmAtlas.PendingExists.selector);
        atlas.setTimelock(3);
        vm.stopPrank();
        assertEq(atlas.timelockBlocks(), 10);
    }

    function test_cancelPending_guardianOnly_carriesTheValue() public {
        _init(10);
        uint64 at = uint64(block.number + 10);
        vm.prank(guardian);
        atlas.setGuardian(next);

        vm.prank(next);
        vm.expectRevert(abi.encodeWithSelector(EvmAtlas.NotGuardian.selector, next));
        atlas.cancelPending();

        vm.expectEmit(address(atlas));
        emit EvmAtlas.PendingCancelled(atlas.CHANGE_GUARDIAN(), next, 0, at);
        vm.prank(guardian);
        atlas.cancelPending();

        vm.prank(guardian);
        vm.expectRevert(EvmAtlas.NoPending.selector);
        atlas.cancelPending();
        vm.expectRevert(EvmAtlas.NoPending.selector);
        atlas.executePending();
    }

    function test_delayZero_guardianChangeWaitsForAcceptanceThenApplies() public {
        vm.prank(deployer);
        atlas.initGuardian(guardian, 0);
        uint64 at = uint64(block.number);
        vm.expectEmit(address(atlas));
        emit EvmAtlas.PendingScheduled(atlas.CHANGE_GUARDIAN(), next, 0, at);
        vm.prank(guardian);
        atlas.setGuardian(next);
        // Even at delay zero the change waits for the incoming guardian.
        assertEq(atlas.guardian(), guardian);
        assertFalse(atlas.pendingAccepted());
        vm.expectRevert(EvmAtlas.NotAccepted.selector);
        atlas.executePending();

        vm.expectEmit(address(atlas));
        emit EvmAtlas.GuardianAccepted(next, at);
        vm.expectEmit(address(atlas));
        emit EvmAtlas.GuardianSet(next);
        vm.prank(next);
        atlas.acceptGuardian();
        assertEq(atlas.guardian(), next);
        assertFalse(atlas.pendingAccepted());
        (uint8 changeKind,,,) = atlas.pending();
        assertEq(changeKind, 0);
    }

    function test_delayZero_timelockChangeStillAppliesAtOnce() public {
        vm.prank(deployer);
        atlas.initGuardian(guardian, 0);
        vm.expectEmit(address(atlas));
        emit EvmAtlas.TimelockSet(7);
        vm.prank(guardian);
        atlas.setTimelock(7);
        assertEq(atlas.timelockBlocks(), 7);
    }

    function test_setTimelock_raiseAndLowerBothWait() public {
        _init(10);
        uint64 at = uint64(block.number + 10);
        vm.prank(guardian);
        atlas.setTimelock(1);
        vm.roll(at - 1);
        vm.expectRevert(abi.encodeWithSelector(EvmAtlas.TooEarly.selector, at, block.number));
        atlas.executePending();
        vm.roll(at);
        atlas.executePending();
        assertEq(atlas.timelockBlocks(), 1);

        uint64 raisedAt = uint64(block.number + 1);
        vm.prank(guardian);
        atlas.setTimelock(8);
        vm.roll(raisedAt);
        atlas.executePending();
        assertEq(atlas.timelockBlocks(), 8);
    }

    function test_setTimelockZero_waitsCurrentDelay_thenGuardianNeedsOnlyAcceptance() public {
        _init(10);
        uint64 at = uint64(block.number + 10);
        vm.prank(guardian);
        atlas.setTimelock(0);
        vm.roll(at);
        atlas.executePending();
        assertEq(atlas.timelockBlocks(), 0);

        vm.expectEmit(address(atlas));
        emit EvmAtlas.PendingScheduled(atlas.CHANGE_GUARDIAN(), next, 0, uint64(block.number));
        vm.prank(guardian);
        atlas.setGuardian(next);
        assertEq(atlas.guardian(), guardian);
        vm.prank(next);
        atlas.acceptGuardian();
        assertEq(atlas.guardian(), next);
    }

    function test_acceptGuardian_onlyTheIncomingGuardian_onlyForGuardianChanges() public {
        _init(10);
        vm.prank(next);
        vm.expectRevert(EvmAtlas.NoPending.selector);
        atlas.acceptGuardian();

        vm.prank(guardian);
        atlas.setTimelock(20);
        vm.prank(next);
        vm.expectRevert(EvmAtlas.NotAGuardianChange.selector);
        atlas.acceptGuardian();
        vm.prank(guardian);
        atlas.cancelPending();

        address typo = makeAddr("typo");
        vm.prank(guardian);
        atlas.setGuardian(typo);
        // Neither the outgoing guardian nor a stranger can accept for it.
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(EvmAtlas.NotIncomingGuardian.selector, guardian));
        atlas.acceptGuardian();
        vm.prank(next);
        vm.expectRevert(abi.encodeWithSelector(EvmAtlas.NotIncomingGuardian.selector, next));
        atlas.acceptGuardian();

        // A change nobody can accept never applies, at any height, and the
        // current guardian still acts and cancels it.
        vm.roll(block.number + 1000);
        vm.expectRevert(EvmAtlas.NotAccepted.selector);
        atlas.executePending();
        assertEq(atlas.guardian(), guardian);
        vm.prank(guardian);
        atlas.setService(ORACLE, 1, _addr(makeAddr("oracle")));
        vm.prank(guardian);
        atlas.cancelPending();
        assertFalse(atlas.pendingAccepted());
        vm.prank(typo);
        vm.expectRevert(EvmAtlas.NoPending.selector);
        atlas.acceptGuardian();
    }

    function test_acceptEarly_thenExecuteAfterTheDelay() public {
        _init(10);
        uint64 at = uint64(block.number + 10);
        vm.prank(guardian);
        atlas.setGuardian(next);
        vm.prank(next);
        atlas.acceptGuardian();
        assertTrue(atlas.pendingAccepted());
        assertEq(atlas.guardian(), guardian);
        vm.roll(at - 1);
        vm.expectRevert(abi.encodeWithSelector(EvmAtlas.TooEarly.selector, at, block.number));
        atlas.executePending();
        vm.roll(at);
        vm.prank(makeAddr("stranger"));
        atlas.executePending();
        assertEq(atlas.guardian(), next);
    }

    function test_firstRaiseFromZero_appliesInTheSameCall() public {
        vm.prank(deployer);
        atlas.initGuardian(guardian, 0);
        vm.expectEmit(address(atlas));
        emit EvmAtlas.PendingScheduled(atlas.CHANGE_TIMELOCK(), address(0), 5, uint64(block.number));
        vm.expectEmit(address(atlas));
        emit EvmAtlas.TimelockSet(5);
        vm.prank(guardian);
        atlas.setTimelock(5);
        assertEq(atlas.timelockBlocks(), 5);
    }

    function _init(uint64 blocks) internal {
        vm.prank(deployer);
        atlas.initGuardian(guardian, blocks);
    }

    function _addr(address account) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(account)));
    }

    function test_guardianCannotBeReservedOrTheDirectoryItself() public {
        address[3] memory bad = [address(0x1), address(0xff), address(atlas)];
        for (uint256 i = 0; i < bad.length; i++) {
            vm.prank(deployer);
            vm.expectRevert(abi.encodeWithSelector(AccountLib.ReservedAddress.selector, bad[i]));
            atlas.initGuardian(bad[i], 10);
        }
        vm.prank(deployer);
        atlas.initGuardian(guardian, 10);
        for (uint256 i = 0; i < bad.length; i++) {
            vm.prank(guardian);
            vm.expectRevert(abi.encodeWithSelector(AccountLib.ReservedAddress.selector, bad[i]));
            atlas.setGuardian(bad[i]);
        }
        assertEq(atlas.guardian(), guardian);
    }

    function test_setTimelock_unchangedAndOverflowAreRefused() public {
        vm.prank(deployer);
        atlas.initGuardian(guardian, 10);
        vm.prank(guardian);
        vm.expectRevert(EvmAtlas.Unchanged.selector);
        atlas.setTimelock(10);
        vm.roll(uint256(type(uint64).max) - 5);
        vm.prank(guardian);
        vm.expectRevert(EvmAtlas.TimelockOverflow.selector);
        atlas.setTimelock(20);
    }
}
