// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {AccountLib} from "../src/AccountLib.sol";
import {EvmAtlas} from "../src/EvmAtlas.sol";
import {EvmWarden} from "../src/EvmWarden.sol";
import {IEvmAtlas} from "../src/IEvmAtlas.sol";
import {LocatorLib} from "../src/LocatorLib.sol";

contract ReenterAtlas is IEvmAtlas {
    EvmWarden public warden;
    bytes public inner;

    function setWarden(EvmWarden warden_) external {
        warden = warden_;
    }

    function chainId() external view returns (uint256) {
        return block.chainid;
    }

    function guardian() external view returns (address) {
        return address(warden);
    }

    function timelockBlocks() external pure returns (uint64) {
        return 0;
    }

    function resolve(bytes32) external pure returns (uint8, bytes32) {
        return (0, bytes32(0));
    }

    function setService(bytes32 name, uint8, bytes32) external {
        try warden.executeService(name) {
            inner = hex"01";
        } catch (bytes memory err) {
            inner = err;
        }
    }

    function pending() external pure returns (uint8, address, uint64, uint64) {
        return (0, address(0), 0, 0);
    }

    function setGuardian(address) external pure {}

    function setTimelock(uint64) external pure {}

    function cancelPending() external pure {}

    function acceptGuardian() external pure {}
}

/// A directory that names the warden as guardian at queue time and then
/// refuses the write.
contract RefusingAtlas is IEvmAtlas {
    error Refused();

    address public guardianAddr;

    function setGuardianAddr(address g) external {
        guardianAddr = g;
    }

    function chainId() external view returns (uint256) {
        return block.chainid;
    }

    function guardian() external view returns (address) {
        return guardianAddr;
    }

    function timelockBlocks() external pure returns (uint64) {
        return type(uint64).max;
    }

    function pending() external pure returns (uint8, address, uint64, uint64) {
        return (0, address(0), 0, 0);
    }

    function resolve(bytes32) external pure returns (uint8, bytes32) {
        return (0, bytes32(0));
    }

    function setService(bytes32, uint8, bytes32) external pure {
        revert Refused();
    }

    function setGuardian(address) external pure {}

    function setTimelock(uint64) external pure {}

    function cancelPending() external pure {}

    function acceptGuardian() external pure {}
}

contract EvmWardenTest is Test {
    uint256 internal constant CHAIN = 745;
    bytes32 internal constant ORACLE = bytes32("evm.sound.oracle");
    bytes32 internal constant NAV = bytes32("native.attested-nav");

    EvmAtlas internal atlas;
    EvmWarden internal warden;
    address internal deployer = makeAddr("deployer");
    address internal scheduler = makeAddr("scheduler");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        vm.chainId(CHAIN);
        vm.startPrank(deployer);
        atlas = new EvmAtlas(CHAIN);
        warden = new EvmWarden(CHAIN, address(atlas), scheduler, 10);
        atlas.initGuardian(address(warden), 10);
        vm.stopPrank();
    }

    function test_constructor_rejectsWrongChainEoaForeignAndCap() public {
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(EvmWarden.WrongChain.selector, CHAIN, 1));
        new EvmWarden(CHAIN, address(atlas), scheduler, 1);

        vm.chainId(CHAIN);
        vm.expectRevert(abi.encodeWithSelector(EvmWarden.NotContract.selector, stranger));
        new EvmWarden(CHAIN, stranger, scheduler, 1);

        ForeignDirectory foreign = new ForeignDirectory();
        vm.expectRevert(abi.encodeWithSelector(EvmWarden.WrongChain.selector, CHAIN, 1));
        new EvmWarden(CHAIN, address(foreign), scheduler, 1);

        vm.expectRevert(EvmWarden.ZeroAddress.selector);
        new EvmWarden(CHAIN, address(atlas), address(0), 1);

        uint64 cap = warden.MAX_TIMELOCK_BLOCKS();
        vm.expectRevert(abi.encodeWithSelector(EvmWarden.TimelockTooLong.selector, cap + 1, cap));
        new EvmWarden(CHAIN, address(atlas), scheduler, cap + 1);

        EvmWarden atCap = new EvmWarden(CHAIN, address(atlas), scheduler, cap);
        assertEq(atCap.delayBlocks(), cap);
    }

    function test_scheduleService_rejectsBadLocatorsAndUnchanged() public {
        bytes32 data = _addr(makeAddr("oracle"));
        _land(ORACLE, 1, data);

        vm.startPrank(scheduler);
        vm.expectRevert(EvmWarden.Unchanged.selector);
        warden.scheduleService(ORACLE, 1, data);
        vm.expectRevert(LocatorLib.EmptyName.selector);
        warden.scheduleService(bytes32(0), 1, data);
        vm.expectRevert(abi.encodeWithSelector(LocatorLib.BadKind.selector, uint8(7)));
        warden.scheduleService(NAV, 7, data);
        vm.expectRevert(LocatorLib.ZeroLocator.selector);
        warden.scheduleService(NAV, 2, bytes32(0));
        bytes32 dirty = data | bytes32(uint256(1) << 160);
        vm.expectRevert(abi.encodeWithSelector(LocatorLib.DirtyAddress.selector, dirty));
        warden.scheduleService(NAV, 1, dirty);
        vm.stopPrank();

        (bool exists,,,) = warden.pendingService(ORACLE);
        assertFalse(exists);
        (exists,,,) = warden.pendingService(NAV);
        assertFalse(exists);
    }

    function test_kindFlip_isAChange_andNamesDoNotBlockEachOther() public {
        bytes32 data = _addr(makeAddr("oracle"));
        _land(ORACLE, 1, data);

        vm.startPrank(scheduler);
        warden.scheduleService(ORACLE, 2, data);
        warden.scheduleService(NAV, 2, data);
        vm.expectRevert(EvmWarden.PendingExists.selector);
        warden.scheduleService(ORACLE, 2, bytes32(uint256(1)));
        vm.stopPrank();

        (bool oracleExists, uint8 oracleKind,,) = warden.pendingService(ORACLE);
        (bool navExists,,,) = warden.pendingService(NAV);
        assertTrue(oracleExists);
        assertEq(oracleKind, 2);
        assertTrue(navExists);
    }

    function test_executeService_waitsThenAnyoneApplies() public {
        bytes32 data = _addr(makeAddr("oracle"));
        uint64 at = uint64(block.number + 10);
        vm.prank(scheduler);
        warden.scheduleService(ORACLE, 1, data);

        vm.expectRevert(EvmWarden.NoPending.selector);
        warden.executeService(NAV);
        vm.expectRevert(abi.encodeWithSelector(EvmWarden.TooEarly.selector, at, block.number));
        warden.executeService(ORACLE);

        vm.roll(at);
        vm.prank(stranger);
        warden.executeService(ORACLE);
        assertEq(atlas.resolveAddress(ORACLE), makeAddr("oracle"));
        (bool exists,,,) = warden.pendingService(ORACLE);
        assertFalse(exists);
    }

    function test_delayZero_emitsThenApplies() public {
        (EvmAtlas a, EvmWarden w) = _pair(0);
        bytes32 data = _addr(makeAddr("oracle"));
        vm.expectEmit(address(w));
        emit EvmWarden.ServiceScheduled(ORACLE, 1, data, uint64(block.number));
        vm.expectEmit(address(w));
        emit EvmWarden.ServiceExecuted(ORACLE, 1, data);
        vm.expectEmit(address(a));
        emit EvmAtlas.ServiceSet(ORACLE, 1, data);
        vm.prank(scheduler);
        w.scheduleService(ORACLE, 1, data);
        assertEq(a.resolveAddress(ORACLE), makeAddr("oracle"));
    }

    function test_cancelService_carriesTheDroppedLocator() public {
        bytes32 data = _addr(makeAddr("oracle"));
        uint64 at = uint64(block.number + 10);
        vm.prank(scheduler);
        warden.scheduleService(ORACLE, 1, data);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(EvmWarden.NotScheduler.selector, stranger));
        warden.cancelService(ORACLE);

        vm.expectEmit(address(warden));
        emit EvmWarden.ServiceCancelled(ORACLE, 1, data, at);
        vm.prank(scheduler);
        warden.cancelService(ORACLE);

        vm.prank(scheduler);
        vm.expectRevert(EvmWarden.NoPending.selector);
        warden.cancelService(ORACLE);
    }

    function test_setDelay_unchangedSkipsSlot_pendingServiceKeepsOldDelay() public {
        vm.prank(scheduler);
        vm.expectRevert(EvmWarden.Unchanged.selector);
        warden.setDelay(10);
        (uint8 changeKind,,,) = warden.pendingAdmin();
        assertEq(changeKind, 0);

        uint256 start = block.number;
        vm.prank(scheduler);
        warden.setDelay(5);
        vm.prank(scheduler);
        warden.scheduleService(ORACLE, 1, _addr(makeAddr("oracle")));

        (,,, uint64 serviceAt) = warden.pendingService(ORACLE);
        assertEq(serviceAt, uint64(start + 10));

        vm.roll(start + 10);
        warden.executeAdmin();
        assertEq(warden.delayBlocks(), 5);
        warden.executeService(ORACLE);
        assertEq(atlas.resolveAddress(ORACLE), makeAddr("oracle"));
    }

    function test_setDelayZero_waitsCurrentDelay() public {
        uint64 at = uint64(block.number + 10);
        vm.prank(scheduler);
        warden.setDelay(0);
        vm.roll(at - 1);
        vm.expectRevert(abi.encodeWithSelector(EvmWarden.TooEarly.selector, at, block.number));
        warden.executeAdmin();
        vm.roll(at);
        warden.executeAdmin();
        assertEq(warden.delayBlocks(), 0);
    }

    function test_setScheduler_sameSlotAsDelay() public {
        address next = makeAddr("next-scheduler");
        vm.prank(scheduler);
        vm.expectRevert(EvmWarden.Unchanged.selector);
        warden.setScheduler(scheduler);
        vm.prank(scheduler);
        vm.expectRevert(EvmWarden.ZeroAddress.selector);
        warden.setScheduler(address(0));

        vm.prank(scheduler);
        warden.setDelay(4);
        vm.prank(scheduler);
        vm.expectRevert(EvmWarden.PendingExists.selector);
        warden.setScheduler(next);

        vm.prank(scheduler);
        warden.cancelAdmin();
        uint64 at = uint64(block.number + 10);
        vm.expectEmit(address(warden));
        emit EvmWarden.AdminScheduled(warden.ADMIN_SCHEDULER(), next, 0, at);
        vm.prank(scheduler);
        warden.setScheduler(next);
        // The delay alone is not enough: the incoming scheduler has to accept.
        vm.roll(at);
        vm.prank(stranger);
        vm.expectRevert(EvmWarden.NotAccepted.selector);
        warden.executeAdmin();
        vm.expectEmit(address(warden));
        emit EvmWarden.SchedulerAccepted(next);
        vm.prank(next);
        warden.acceptScheduler();
        assertEq(warden.scheduler(), next);
        assertFalse(warden.pendingAdminAccepted());

        vm.prank(scheduler);
        vm.expectRevert(abi.encodeWithSelector(EvmWarden.NotScheduler.selector, scheduler));
        warden.setDelay(1);
    }

    function test_acceptScheduler_onlyTheIncomingScheduler_onlyForSchedulerChanges() public {
        address typo = makeAddr("typo-scheduler");
        address next = makeAddr("someone-else");
        vm.prank(next);
        vm.expectRevert(EvmWarden.NoPending.selector);
        warden.acceptScheduler();

        vm.prank(scheduler);
        warden.setDelay(5);
        vm.prank(next);
        vm.expectRevert(EvmWarden.NotASchedulerChange.selector);
        warden.acceptScheduler();
        vm.prank(scheduler);
        warden.cancelAdmin();

        vm.prank(scheduler);
        warden.setScheduler(typo);
        vm.prank(scheduler);
        vm.expectRevert(abi.encodeWithSelector(EvmWarden.NotIncomingScheduler.selector, scheduler));
        warden.acceptScheduler();
        vm.prank(next);
        vm.expectRevert(abi.encodeWithSelector(EvmWarden.NotIncomingScheduler.selector, next));
        warden.acceptScheduler();

        // A scheduler nobody can accept for never takes the role; the current
        // scheduler keeps acting and cancels the stuck change.
        vm.roll(block.number + 1000);
        vm.expectRevert(EvmWarden.NotAccepted.selector);
        warden.executeAdmin();
        assertEq(warden.scheduler(), scheduler);
        vm.prank(scheduler);
        warden.scheduleService(ORACLE, 1, _addr(makeAddr("oracle")));
        vm.prank(scheduler);
        warden.cancelAdmin();
        assertFalse(warden.pendingAdminAccepted());
    }

    function test_delayZero_schedulerChangeWaitsForAcceptance() public {
        vm.startPrank(deployer);
        EvmAtlas a = new EvmAtlas(CHAIN);
        EvmWarden w = new EvmWarden(CHAIN, address(a), scheduler, 0);
        a.initGuardian(address(w), 1);
        vm.stopPrank();
        address incoming = makeAddr("incoming-scheduler");

        vm.prank(scheduler);
        w.setScheduler(incoming);
        assertEq(w.scheduler(), scheduler);
        vm.prank(incoming);
        w.acceptScheduler();
        assertEq(w.scheduler(), incoming);
    }

    /// The warden is the incoming guardian of a directory whose guardian is a key.
    function test_acceptAtlasGuardian_wardenAcceptsAsTheIncomingGuardian() public {
        vm.startPrank(deployer);
        EvmAtlas a = new EvmAtlas(CHAIN);
        EvmWarden w = new EvmWarden(CHAIN, address(a), scheduler, 5);
        a.initGuardian(makeAddr("old-guardian"), 3);
        vm.stopPrank();

        vm.prank(makeAddr("old-guardian"));
        a.setGuardian(address(w));
        // Only the scheduler can make the warden accept; the warden itself is the
        // `msg.sender` the directory sees.
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(EvmWarden.NotScheduler.selector, stranger));
        w.acceptAtlasGuardian();
        vm.prank(scheduler);
        w.acceptAtlasGuardian();
        assertTrue(a.pendingAccepted());
        (,,, uint64 at) = a.pending();
        vm.roll(at);
        a.executePending();
        assertEq(a.guardian(), address(w));
    }

    function test_cancelAdmin_carriesTheDroppedChange() public {
        uint64 at = uint64(block.number + 10);
        vm.prank(scheduler);
        warden.setDelay(4);
        vm.expectEmit(address(warden));
        emit EvmWarden.AdminCancelled(warden.ADMIN_DELAY(), address(0), 4, at);
        vm.prank(scheduler);
        warden.cancelAdmin();
        (uint8 changeKind,,,) = warden.pendingAdmin();
        assertEq(changeKind, 0);
    }

    function test_setGuardian_waitsWardenDelayThenDirectoryTimelock() public {
        address next = makeAddr("next-guardian");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(EvmWarden.NotScheduler.selector, stranger));
        warden.setGuardian(next);

        uint64 wardenAt = uint64(block.number + 10);
        vm.expectEmit(address(warden));
        emit EvmWarden.AdminScheduled(warden.ADMIN_ATLAS_GUARDIAN(), next, 0, wardenAt);
        vm.prank(scheduler);
        warden.setGuardian(next);

        (uint8 adminKind, address queued,,) = warden.pendingAdmin();
        assertEq(adminKind, warden.ADMIN_ATLAS_GUARDIAN());
        assertEq(queued, next);
        (uint8 atlasKind,,,) = atlas.pending();
        assertEq(atlasKind, 0);
        assertEq(atlas.guardian(), address(warden));

        vm.prank(scheduler);
        vm.expectRevert(EvmWarden.GuardianChangeQueued.selector);
        warden.setTimelock(20);
        assertEq(atlas.timelockBlocks(), 10);

        vm.roll(wardenAt);
        vm.expectEmit(address(warden));
        emit EvmWarden.AtlasGuardianForwarded(next);
        warden.executeAdmin();
        (uint8 changeKind, address scheduled,, uint64 atlasAt) = atlas.pending();
        assertEq(changeKind, atlas.CHANGE_GUARDIAN());
        assertEq(scheduled, next);
        assertEq(atlas.guardian(), address(warden));

        // After the directory timelock the incoming guardian must still accept.
        vm.roll(atlasAt);
        vm.expectRevert(EvmAtlas.NotAccepted.selector);
        atlas.executePending();
        vm.prank(next);
        atlas.acceptGuardian();
        assertEq(atlas.guardian(), next);
    }

    function test_setGuardian_rejectsWhenWardenIsNotTheDirectoryGuardian() public {
        vm.startPrank(deployer);
        EvmAtlas other = new EvmAtlas(CHAIN);
        EvmWarden w = new EvmWarden(CHAIN, address(other), scheduler, 5);
        other.initGuardian(stranger, 1);
        vm.stopPrank();

        vm.prank(scheduler);
        vm.expectRevert(abi.encodeWithSelector(EvmWarden.NotDirectoryGuardian.selector, stranger));
        w.setGuardian(makeAddr("next-guardian"));
        (uint8 changeKind,,,) = w.pendingAdmin();
        assertEq(changeKind, 0);
    }

    function test_setGuardian_rejectsWhileTheDirectoryHasAPendingChange() public {
        vm.prank(scheduler);
        warden.setTimelock(20);
        (uint8 directoryKind,,,) = atlas.pending();
        assertEq(directoryKind, atlas.CHANGE_TIMELOCK());

        vm.prank(scheduler);
        vm.expectRevert(EvmWarden.DirectoryChangePending.selector);
        warden.setGuardian(makeAddr("next-guardian"));
        (uint8 changeKind,,,) = warden.pendingAdmin();
        assertEq(changeKind, 0);

        vm.prank(scheduler);
        warden.cancelAtlasPending();
        vm.prank(scheduler);
        warden.setGuardian(makeAddr("next-guardian"));
        (changeKind,,,) = warden.pendingAdmin();
        assertEq(changeKind, warden.ADMIN_ATLAS_GUARDIAN());
    }

    function test_setTimelock_isBlockedOnlyWhileAGuardianChangeIsQueued() public {
        address next = makeAddr("next-guardian");
        vm.prank(scheduler);
        warden.setGuardian(next);

        vm.prank(scheduler);
        vm.expectRevert(EvmWarden.GuardianChangeQueued.selector);
        warden.setTimelock(20);

        vm.prank(scheduler);
        warden.cancelAdmin();
        vm.prank(scheduler);
        warden.setTimelock(20);
        (uint8 directoryKind,,,) = atlas.pending();
        assertEq(directoryKind, atlas.CHANGE_TIMELOCK());
    }

    function test_executeAdmin_guardianForwardCannotRevertAfterTheGuards() public {
        address next = makeAddr("next-guardian");
        uint256 start = block.number;
        vm.prank(scheduler);
        warden.setGuardian(next);
        // Another admin change cannot open a directory change in the window.
        vm.prank(scheduler);
        vm.expectRevert(EvmWarden.GuardianChangeQueued.selector);
        warden.setTimelock(30);

        vm.roll(start + 10);
        warden.executeAdmin();
        (uint8 adminKind,,,) = warden.pendingAdmin();
        assertEq(adminKind, 0);
        (uint8 directoryKind, address queued,,) = atlas.pending();
        assertEq(directoryKind, atlas.CHANGE_GUARDIAN());
        assertEq(queued, next);
    }

    function test_timelockNeverBelowDelay_setTimelockSide() public {
        // setUp: delay 10, directory timelock 10.
        vm.prank(scheduler);
        vm.expectRevert(abi.encodeWithSelector(EvmWarden.TimelockBelowDelay.selector, uint64(9), uint64(10)));
        warden.setTimelock(9);
        vm.prank(scheduler);
        vm.expectRevert(abi.encodeWithSelector(EvmWarden.TimelockBelowDelay.selector, uint64(0), uint64(10)));
        warden.setTimelock(0);
        (uint8 kind,,,) = atlas.pending();
        assertEq(kind, 0);

        // A queued raise of the delay counts too.
        vm.prank(scheduler);
        warden.setTimelock(40);
        uint256 start = block.number;
        vm.roll(start + 10);
        atlas.executePending();
        assertEq(atlas.timelockBlocks(), 40);
        vm.prank(scheduler);
        warden.setDelay(30);
        vm.prank(scheduler);
        vm.expectRevert(abi.encodeWithSelector(EvmWarden.TimelockBelowDelay.selector, uint64(20), uint64(30)));
        warden.setTimelock(20);

        // Equal is fine.
        vm.prank(scheduler);
        warden.setTimelock(30);
        (kind,,,) = atlas.pending();
        assertEq(kind, atlas.CHANGE_TIMELOCK());
    }

    function test_timelockNeverBelowDelay_setDelaySide() public {
        // setUp: delay 10, directory timelock 10. Raising the delay needs a
        // higher timelock first.
        vm.prank(scheduler);
        vm.expectRevert(abi.encodeWithSelector(EvmWarden.DelayAboveTimelock.selector, uint64(11), uint64(10)));
        warden.setDelay(11);

        // A pending timelock change counts at its lower value.
        vm.prank(scheduler);
        warden.setTimelock(50);
        vm.prank(scheduler);
        vm.expectRevert(abi.encodeWithSelector(EvmWarden.DelayAboveTimelock.selector, uint64(20), uint64(10)));
        warden.setDelay(20);
        vm.roll(block.number + 10);
        atlas.executePending();
        vm.prank(scheduler);
        warden.setDelay(50);
        (uint8 kind,, uint64 newDelay,) = warden.pendingAdmin();
        assertEq(kind, warden.ADMIN_DELAY());
        assertEq(newDelay, 50);
        vm.prank(scheduler);
        warden.cancelAdmin();

        // A pending lowering of the timelock bounds the delay at the new value.
        vm.prank(scheduler);
        warden.setTimelock(12);
        vm.prank(scheduler);
        vm.expectRevert(abi.encodeWithSelector(EvmWarden.DelayAboveTimelock.selector, uint64(13), uint64(12)));
        warden.setDelay(13);
        vm.prank(scheduler);
        warden.setDelay(12);
    }

    function test_setDelay_unboundedOnceNotTheDirectoryGuardian() public {
        EvmAtlas a = new EvmAtlas(CHAIN);
        EvmWarden w = new EvmWarden(CHAIN, address(a), scheduler, 5);
        a.initGuardian(makeAddr("other-guardian"), 1);
        vm.prank(scheduler);
        w.setDelay(100);
        (uint8 kind,, uint64 newDelay,) = w.pendingAdmin();
        assertEq(kind, w.ADMIN_DELAY());
        assertEq(newDelay, 100);
    }

    function test_setDelay_rejectsAboveCap() public {
        uint64 cap = warden.MAX_TIMELOCK_BLOCKS();
        vm.prank(scheduler);
        vm.expectRevert(abi.encodeWithSelector(EvmWarden.TimelockTooLong.selector, cap + 1, cap));
        warden.setDelay(cap + 1);
        (uint8 changeKind,,,) = warden.pendingAdmin();
        assertEq(changeKind, 0);
    }

    function test_revertingDirectory_keepsThePendingEntry() public {
        RefusingAtlas refusing = new RefusingAtlas();
        EvmWarden w = new EvmWarden(CHAIN, address(refusing), scheduler, 5);
        refusing.setGuardianAddr(address(w));

        uint256 start = block.number;
        vm.prank(scheduler);
        w.scheduleService(ORACLE, 1, _addr(makeAddr("oracle")));
        vm.roll(start + 5);
        vm.expectRevert(RefusingAtlas.Refused.selector);
        w.executeService(ORACLE);
        (bool exists,,,) = w.pendingService(ORACLE);
        assertTrue(exists);
    }

    function test_scheduleService_rejectsAfterTheWardenIsNoLongerTheGuardian() public {
        address next = makeAddr("next-guardian");
        uint256 start = block.number;
        vm.prank(scheduler);
        warden.setGuardian(next);
        vm.roll(start + 10);
        warden.executeAdmin();
        (,,, uint64 atlasAt) = atlas.pending();
        vm.roll(atlasAt);
        vm.prank(next);
        atlas.acceptGuardian();
        assertEq(atlas.guardian(), next);

        // Queued repoints could never execute now, and ServiceScheduled would
        // mislead a monitor.
        vm.prank(scheduler);
        vm.expectRevert(abi.encodeWithSelector(EvmWarden.NotDirectoryGuardian.selector, next));
        warden.scheduleService(ORACLE, 1, _addr(makeAddr("oracle")));
    }

    function test_unusableAccountsAreRefused() public {
        address[3] memory bad = [address(0x1), address(0xff), address(warden)];
        for (uint256 i = 0; i < bad.length; i++) {
            vm.prank(scheduler);
            vm.expectRevert(abi.encodeWithSelector(AccountLib.ReservedAddress.selector, bad[i]));
            warden.setScheduler(bad[i]);
        }
        // The directory refuses itself as guardian, so the warden must too.
        vm.prank(scheduler);
        vm.expectRevert(abi.encodeWithSelector(AccountLib.ReservedAddress.selector, address(atlas)));
        warden.setScheduler(address(atlas));
        vm.prank(scheduler);
        vm.expectRevert(abi.encodeWithSelector(AccountLib.ReservedAddress.selector, address(atlas)));
        warden.setGuardian(address(atlas));
        vm.prank(scheduler);
        vm.expectRevert(abi.encodeWithSelector(AccountLib.ReservedAddress.selector, address(0x2)));
        warden.setGuardian(address(0x2));

        vm.startPrank(deployer);
        EvmAtlas other = new EvmAtlas(CHAIN);
        vm.expectRevert(abi.encodeWithSelector(AccountLib.ReservedAddress.selector, address(0x9)));
        new EvmWarden(CHAIN, address(other), address(0x9), 5);
        vm.stopPrank();
        (uint8 changeKind,,,) = warden.pendingAdmin();
        assertEq(changeKind, 0);
    }

    function test_adminCalls_requireTheSchedulerAndAPendingEntry() public {
        vm.startPrank(stranger);
        bytes4 notScheduler = EvmWarden.NotScheduler.selector;
        vm.expectRevert(abi.encodeWithSelector(notScheduler, stranger));
        warden.setTimelock(20);
        vm.expectRevert(abi.encodeWithSelector(notScheduler, stranger));
        warden.cancelAtlasPending();
        vm.expectRevert(abi.encodeWithSelector(notScheduler, stranger));
        warden.cancelAdmin();
        vm.expectRevert(abi.encodeWithSelector(notScheduler, stranger));
        warden.setScheduler(makeAddr("x"));
        vm.expectRevert(EvmWarden.NoPending.selector);
        warden.executeAdmin();
        vm.stopPrank();
    }

    function test_executeAdmin_tooEarlyForEveryKind() public {
        vm.startPrank(scheduler);
        warden.setDelay(5);
        vm.expectRevert(abi.encodeWithSelector(EvmWarden.TooEarly.selector, uint64(block.number + 10), block.number));
        warden.executeAdmin();
        warden.cancelAdmin();
        warden.setScheduler(makeAddr("next-scheduler"));
        vm.expectRevert(abi.encodeWithSelector(EvmWarden.TooEarly.selector, uint64(block.number + 10), block.number));
        warden.executeAdmin();
        vm.stopPrank();
    }

    function test_timelockOverflowIsRefused() public {
        vm.roll(uint256(type(uint64).max) - 5);
        vm.prank(scheduler);
        vm.expectRevert(EvmWarden.TimelockOverflow.selector);
        warden.scheduleService(ORACLE, 1, _addr(makeAddr("oracle")));
    }

    function test_executeService_reenterSeesNoPending() public {
        ReenterAtlas mock = new ReenterAtlas();
        EvmWarden w = new EvmWarden(CHAIN, address(mock), scheduler, 0);
        mock.setWarden(w);

        vm.prank(scheduler);
        w.scheduleService(ORACLE, 1, _addr(makeAddr("oracle")));
        assertEq(mock.inner(), abi.encodeWithSelector(EvmWarden.NoPending.selector));
        (bool exists,,,) = w.pendingService(ORACLE);
        assertFalse(exists);
    }

    function test_changeKindNumbers_belongToDifferentEvents() public view {
        assertEq(atlas.CHANGE_GUARDIAN(), 1);
        assertEq(warden.ADMIN_DELAY(), 1);
        assertEq(atlas.CHANGE_TIMELOCK(), 2);
        assertEq(warden.ADMIN_SCHEDULER(), 2);
        assertEq(warden.ADMIN_ATLAS_GUARDIAN(), 3);
        assertTrue(EvmAtlas.PendingScheduled.selector != EvmWarden.AdminScheduled.selector);
        assertTrue(EvmAtlas.PendingCancelled.selector != EvmWarden.AdminCancelled.selector);
        assertTrue(EvmAtlas.PendingCancelled.selector != EvmWarden.ServiceCancelled.selector);
    }

    function _land(bytes32 name, uint8 kind, bytes32 data) internal {
        uint256 at = block.number + warden.delayBlocks();
        vm.prank(scheduler);
        warden.scheduleService(name, kind, data);
        if (warden.delayBlocks() > 0) {
            vm.roll(at);
            warden.executeService(name);
        }
    }

    function _pair(uint64 delay) internal returns (EvmAtlas a, EvmWarden w) {
        vm.startPrank(deployer);
        a = new EvmAtlas(CHAIN);
        w = new EvmWarden(CHAIN, address(a), scheduler, delay);
        a.initGuardian(address(w), 1);
        vm.stopPrank();
    }

    function _addr(address account) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(account)));
    }
}

contract ForeignDirectory {
    function chainId() external pure returns (uint256) {
        return 1;
    }
}
