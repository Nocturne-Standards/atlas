// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {AccountLib} from "./AccountLib.sol";
import {IEvmAtlas} from "./IEvmAtlas.sol";
import {LocatorLib} from "./LocatorLib.sol";

/// Delaying guardian in front of EvmAtlas. Service repoints wait here.
/// Replacing the directory guardian waits here too, then waits again inside
/// the directory. This contract does not answer resolve.
contract EvmWarden {
    /// Warden admin change. Not the directory's pending changeKind.
    /// 1 is a new delay. 2 is a new scheduler. 3 is the directory's next guardian.
    uint8 public constant ADMIN_DELAY = 1;
    uint8 public constant ADMIN_SCHEDULER = 2;
    uint8 public constant ADMIN_ATLAS_GUARDIAN = 3;
    /// EvmAtlas.CHANGE_TIMELOCK: the directory's pending change is a timelock.
    uint8 internal constant CHANGE_DIRECTORY_TIMELOCK = 2;

    /// 90 days of ~2-second DuskEVM blocks. Same cap as EvmAtlas.
    uint64 public constant MAX_TIMELOCK_BLOCKS = 3_888_000;

    error WrongChain(uint256 expected, uint256 actual);
    error ZeroAddress();
    error NotContract(address atlas);
    error NotScheduler(address caller);
    error NotDirectoryGuardian(address guardian);
    error DirectoryChangePending();
    error GuardianChangeQueued();
    error Unchanged();
    error PendingExists();
    error NoPending();
    error NotASchedulerChange();
    error NotIncomingScheduler(address caller);
    error NotAccepted();
    error TooEarly(uint64 executeAt, uint256 blockNumber);
    error TimelockOverflow();
    error TimelockTooLong(uint64 blocks, uint64 max);
    error TimelockBelowDelay(uint64 blocks, uint64 delay);
    error DelayAboveTimelock(uint64 blocks, uint64 timelock);

    event SchedulerSet(address scheduler);
    /// The incoming scheduler of the pending scheduler change called
    /// `acceptScheduler`. `SchedulerSet` follows when the change applies.
    event SchedulerAccepted(address scheduler);
    event DelaySet(uint64 blocks);
    event ServiceScheduled(bytes32 name, uint8 kind, bytes32 data, uint64 executeAt);
    event ServiceExecuted(bytes32 name, uint8 kind, bytes32 data);
    event ServiceCancelled(bytes32 name, uint8 kind, bytes32 data, uint64 executeAt);
    event AdminScheduled(uint8 changeKind, address nextScheduler, uint64 newDelay, uint64 executeAt);
    /// The queued directory guardian change reached the directory, which now
    /// waits its own timelock before `GuardianSet`.
    event AtlasGuardianForwarded(address nextGuardian);
    event AdminCancelled(uint8 changeKind, address nextScheduler, uint64 newDelay, uint64 executeAt);

    struct PendingService {
        bool exists;
        uint8 kind;
        bytes32 data;
        uint64 executeAt;
    }

    /// `nextScheduler` holds the next scheduler, or the directory's next
    /// guardian when `changeKind` is `ADMIN_ATLAS_GUARDIAN`.
    struct PendingAdmin {
        uint8 changeKind;
        address nextScheduler;
        uint64 newDelay;
        uint64 executeAt;
    }

    uint256 public immutable chainId;
    address public immutable atlas;

    address public scheduler;
    uint64 public delayBlocks;

    mapping(bytes32 => PendingService) private _pendingServices;
    PendingAdmin private _pendingAdmin;
    /// The incoming scheduler of the pending scheduler change has accepted it.
    bool public pendingAdminAccepted;

    constructor(uint256 expectedChainId, address atlas_, address scheduler_, uint64 delayBlocks_) {
        if (block.chainid != expectedChainId) revert WrongChain(expectedChainId, block.chainid);
        if (atlas_.code.length == 0) revert NotContract(atlas_);
        uint256 atlasChain = IEvmAtlas(atlas_).chainId();
        if (atlasChain != block.chainid) revert WrongChain(block.chainid, atlasChain);
        if (scheduler_ == address(0)) revert ZeroAddress();
        _checkAccount(scheduler_, atlas_);
        if (delayBlocks_ > MAX_TIMELOCK_BLOCKS) revert TimelockTooLong(delayBlocks_, MAX_TIMELOCK_BLOCKS);
        chainId = expectedChainId;
        atlas = atlas_;
        scheduler = scheduler_;
        delayBlocks = delayBlocks_;
        emit SchedulerSet(scheduler_);
        emit DelaySet(delayBlocks_);
    }

    function pendingService(bytes32 name)
        external
        view
        returns (bool exists, uint8 kind, bytes32 data, uint64 executeAt)
    {
        PendingService memory p = _pendingServices[name];
        return (p.exists, p.kind, p.data, p.executeAt);
    }

    function pendingAdmin()
        external
        view
        returns (uint8 changeKind, address nextScheduler, uint64 newDelay, uint64 executeAt)
    {
        PendingAdmin memory p = _pendingAdmin;
        return (p.changeKind, p.nextScheduler, p.newDelay, p.executeAt);
    }

    function scheduleService(bytes32 name, uint8 kind, bytes32 data) external {
        _onlyScheduler();
        // After a handover the directory refuses this warden, so an entry could
        // never execute. Do not queue one, or emit ServiceScheduled for it.
        address current = IEvmAtlas(atlas).guardian();
        if (current != address(this)) revert NotDirectoryGuardian(current);
        LocatorLib.check(name, kind, data);
        (uint8 currentKind, bytes32 currentData) = IEvmAtlas(atlas).resolve(name);
        if (currentKind == kind && currentData == data) revert Unchanged();
        if (_pendingServices[name].exists) revert PendingExists();
        uint64 executeAt = _executeAt(delayBlocks);
        _pendingServices[name] = PendingService({exists: true, kind: kind, data: data, executeAt: executeAt});
        emit ServiceScheduled(name, kind, data, executeAt);
        if (delayBlocks == 0) executeService(name);
    }

    /// Anyone may call. Clears the entry before the directory write, so a
    /// reentering directory sees no pending repoint. A reverting directory
    /// rolls the clear back with the transaction.
    function executeService(bytes32 name) public {
        PendingService memory p = _pendingServices[name];
        if (!p.exists) revert NoPending();
        if (block.number < p.executeAt) revert TooEarly(p.executeAt, block.number);
        delete _pendingServices[name];
        emit ServiceExecuted(name, p.kind, p.data);
        IEvmAtlas(atlas).setService(name, p.kind, p.data);
    }

    function cancelService(bytes32 name) external {
        _onlyScheduler();
        PendingService memory p = _pendingServices[name];
        if (!p.exists) revert NoPending();
        delete _pendingServices[name];
        emit ServiceCancelled(name, p.kind, p.data, p.executeAt);
    }

    /// While this warden is the directory's guardian, the new delay may not
    /// exceed the directory timelock (nor a timelock change the directory has
    /// pending): `T >= D` holds from both sides. Raise the timelock first.
    function setDelay(uint64 blocks) external {
        _onlyScheduler();
        if (blocks > MAX_TIMELOCK_BLOCKS) revert TimelockTooLong(blocks, MAX_TIMELOCK_BLOCKS);
        if (blocks == delayBlocks) revert Unchanged();
        if (IEvmAtlas(atlas).guardian() == address(this)) {
            uint64 timelock = _directoryTimelockFloor();
            if (blocks > timelock) revert DelayAboveTimelock(blocks, timelock);
        }
        _scheduleAdmin(ADMIN_DELAY, address(0), blocks);
    }

    function setScheduler(address next) external {
        _onlyScheduler();
        if (next == address(0)) revert ZeroAddress();
        _checkAccount(next, atlas);
        if (next == scheduler) revert Unchanged();
        _scheduleAdmin(ADMIN_SCHEDULER, next, 0);
    }

    /// Called by the incoming scheduler of a pending scheduler change. It proves
    /// the new address can act before it takes the role; a mistyped address
    /// cannot accept and is never applied. The current scheduler cancels the
    /// stuck change. If the delay has already passed the change applies in this
    /// call.
    function acceptScheduler() external {
        PendingAdmin memory p = _pendingAdmin;
        if (p.changeKind == 0) revert NoPending();
        if (p.changeKind != ADMIN_SCHEDULER) revert NotASchedulerChange();
        if (msg.sender != p.nextScheduler) revert NotIncomingScheduler(msg.sender);
        pendingAdminAccepted = true;
        emit SchedulerAccepted(msg.sender);
        if (block.number >= p.executeAt) executeAdmin();
    }

    /// Called by the scheduler when this warden is the incoming guardian of a
    /// directory guardian change: the warden calls the directory's
    /// `acceptGuardian`, so the directory sees the call from this contract.
    function acceptAtlasGuardian() external {
        _onlyScheduler();
        IEvmAtlas(atlas).acceptGuardian();
    }

    function executeAdmin() public {
        PendingAdmin memory p = _pendingAdmin;
        if (p.changeKind == 0) revert NoPending();
        if (block.number < p.executeAt) revert TooEarly(p.executeAt, block.number);
        if (p.changeKind == ADMIN_SCHEDULER && !pendingAdminAccepted) revert NotAccepted();
        delete _pendingAdmin;
        pendingAdminAccepted = false;
        if (p.changeKind == ADMIN_DELAY) {
            delayBlocks = p.newDelay;
            emit DelaySet(p.newDelay);
        } else if (p.changeKind == ADMIN_SCHEDULER) {
            scheduler = p.nextScheduler;
            emit SchedulerSet(p.nextScheduler);
        } else if (p.changeKind == ADMIN_ATLAS_GUARDIAN) {
            emit AtlasGuardianForwarded(p.nextScheduler);
            IEvmAtlas(atlas).setGuardian(p.nextScheduler);
        }
    }

    function cancelAdmin() external {
        _onlyScheduler();
        PendingAdmin memory p = _pendingAdmin;
        if (p.changeKind == 0) revert NoPending();
        delete _pendingAdmin;
        pendingAdminAccepted = false;
        emit AdminCancelled(p.changeKind, p.nextScheduler, p.newDelay, p.executeAt);
    }

    /// Queue a directory guardian change for `delayBlocks`. `executeAdmin`
    /// then calls the directory, which waits its own timelock on top.
    ///
    /// The forward in `executeAdmin` reverts, and so leaves the single admin
    /// slot occupied, if the warden is not the directory's guardian or the
    /// directory already holds a pending change. Both are checked here, and
    /// `setTimelock` cannot open a directory change while this one is queued,
    /// so the forward has no other way to fail.
    function setGuardian(address next) external {
        _onlyScheduler();
        if (next == address(0)) revert ZeroAddress();
        // The directory refuses its own address and the reserved range, so the
        // forward would fail on them. Refuse here instead.
        AccountLib.check(next, atlas);
        address current = IEvmAtlas(atlas).guardian();
        if (current != address(this)) revert NotDirectoryGuardian(current);
        if (next == current) revert Unchanged();
        (uint8 directoryKind,,,) = IEvmAtlas(atlas).pending();
        if (directoryKind != 0) revert DirectoryChangePending();
        _scheduleAdmin(ADMIN_ATLAS_GUARDIAN, next, 0);
    }

    /// The directory timelock may not drop below the warden delay, nor below
    /// a delay change queued here: `T >= D` holds from both sides.
    function setTimelock(uint64 blocks) external {
        _onlyScheduler();
        PendingAdmin memory p = _pendingAdmin;
        if (p.changeKind == ADMIN_ATLAS_GUARDIAN) revert GuardianChangeQueued();
        uint64 delay = delayBlocks;
        if (p.changeKind == ADMIN_DELAY && p.newDelay > delay) delay = p.newDelay;
        if (blocks < delay) revert TimelockBelowDelay(blocks, delay);
        IEvmAtlas(atlas).setTimelock(blocks);
    }

    function cancelAtlasPending() external {
        _onlyScheduler();
        IEvmAtlas(atlas).cancelPending();
    }

    /// The lowest directory timelock in force now or after its pending
    /// timelock change applies.
    function _directoryTimelockFloor() internal view returns (uint64 timelock) {
        timelock = IEvmAtlas(atlas).timelockBlocks();
        (uint8 kind,, uint64 newBlocks,) = IEvmAtlas(atlas).pending();
        if (kind == CHANGE_DIRECTORY_TIMELOCK && newBlocks < timelock) timelock = newBlocks;
    }

    /// A scheduler or guardian must be able to sign: not zero, not a precompile,
    /// not this warden, not the directory (which never calls the warden).
    function _checkAccount(address account, address atlas_) internal view {
        AccountLib.check(account, address(this));
        AccountLib.check(account, atlas_);
    }

    function _onlyScheduler() internal view {
        if (msg.sender != scheduler) revert NotScheduler(msg.sender);
    }

    function _scheduleAdmin(uint8 changeKind, address nextScheduler, uint64 newDelay) internal {
        if (_pendingAdmin.changeKind != 0) revert PendingExists();
        uint64 executeAt = _executeAt(delayBlocks);
        _pendingAdmin = PendingAdmin({
            changeKind: changeKind, nextScheduler: nextScheduler, newDelay: newDelay, executeAt: executeAt
        });
        pendingAdminAccepted = false;
        emit AdminScheduled(changeKind, nextScheduler, newDelay, executeAt);
        // Delay zero applies a delay change and the directory forward at once.
        // A scheduler change still waits for the incoming scheduler to accept.
        if (delayBlocks == 0 && changeKind != ADMIN_SCHEDULER) executeAdmin();
    }

    function _executeAt(uint64 delay) internal view returns (uint64) {
        uint256 at = block.number + uint256(delay);
        if (at > type(uint64).max) revert TimelockOverflow();
        return uint64(at);
    }
}
