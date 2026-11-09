// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {AccountLib} from "./AccountLib.sol";
import {LocatorLib} from "./LocatorLib.sol";

/// Per-chain directory. One guardian. Service writes are immediate.
/// Replacing the guardian, and changing the delay, share one slot and wait.
/// This contract never calls its guardian.
contract EvmAtlas {
    uint8 public constant KIND_EVM_ADDRESS = LocatorLib.KIND_EVM_ADDRESS;
    uint8 public constant KIND_NATIVE_ID = LocatorLib.KIND_NATIVE_ID;

    /// Directory pending change. Not EvmWarden's admin changeKind.
    /// 1 is a new guardian. 2 is a new timelock.
    uint8 public constant CHANGE_GUARDIAN = 1;
    uint8 public constant CHANGE_TIMELOCK = 2;

    /// 90 days of ~2-second DuskEVM blocks. A larger delay freezes later schedules.
    uint64 public constant MAX_TIMELOCK_BLOCKS = 3_888_000;

    error WrongChain(uint256 expected, uint256 actual);
    error NotDeployer(address caller);
    error AlreadyInitialized();
    error ZeroAddress();
    error NotGuardian(address caller);
    error Unchanged();
    error PendingExists();
    error NoPending();
    error NotAGuardianChange();
    error NotIncomingGuardian(address caller);
    error NotAccepted();
    error TooEarly(uint64 executeAt, uint256 blockNumber);
    error TimelockOverflow();
    error TimelockTooLong(uint64 blocks, uint64 max);
    error KindMismatch(uint8 kind);
    error NotFound(bytes32 name);

    event GuardianSet(address guardian);
    /// The incoming guardian of the pending guardian change called
    /// `acceptGuardian`. `executeAt` is the block from which the change can
    /// apply. `GuardianSet` follows when the change applies.
    event GuardianAccepted(address guardian, uint64 executeAt);
    event TimelockSet(uint64 blocks);
    event ServiceSet(bytes32 name, uint8 kind, bytes32 data);
    event PendingScheduled(uint8 changeKind, address nextGuardian, uint64 newBlocks, uint64 executeAt);
    event PendingCancelled(uint8 changeKind, address nextGuardian, uint64 newBlocks, uint64 executeAt);

    struct Pending {
        uint8 changeKind;
        address nextGuardian;
        uint64 newBlocks;
        uint64 executeAt;
    }

    uint256 public immutable chainId;
    address public immutable deployer;

    mapping(bytes32 => bytes32) private _data;
    mapping(bytes32 => uint8) private _kind;

    address public guardian;
    uint64 public timelockBlocks;
    Pending private _pending;
    /// The incoming guardian of the pending guardian change has accepted it.
    bool public pendingAccepted;

    constructor(uint256 expectedChainId) {
        if (block.chainid != expectedChainId) revert WrongChain(expectedChainId, block.chainid);
        chainId = expectedChainId;
        deployer = msg.sender;
    }

    function initGuardian(address next, uint64 blocks) external {
        if (msg.sender != deployer) revert NotDeployer(msg.sender);
        if (guardian != address(0)) revert AlreadyInitialized();
        if (next == address(0)) revert ZeroAddress();
        AccountLib.check(next, address(this));
        if (blocks > MAX_TIMELOCK_BLOCKS) revert TimelockTooLong(blocks, MAX_TIMELOCK_BLOCKS);
        guardian = next;
        timelockBlocks = blocks;
        emit GuardianSet(next);
        emit TimelockSet(blocks);
    }

    function resolve(bytes32 name) external view returns (uint8 kind, bytes32 data) {
        return (_kind[name], _data[name]);
    }

    function resolveAddress(bytes32 name) external view returns (address) {
        (uint8 kind, bytes32 data) = _load(name);
        if (kind != KIND_EVM_ADDRESS) revert KindMismatch(kind);
        return address(uint160(uint256(data)));
    }

    function resolveNativeId(bytes32 name) external view returns (bytes32) {
        (uint8 kind, bytes32 data) = _load(name);
        if (kind != KIND_NATIVE_ID) revert KindMismatch(kind);
        return data;
    }

    /// Last 20 bytes of keccak256 of the raw 32-byte id: the EVM address Dusk's
    /// SDK (`duskContractIdToEvmAddress`) gives a native contract.
    function unaliasedSender(bytes32 name) external view returns (address) {
        (uint8 kind, bytes32 data) = _load(name);
        if (kind != KIND_NATIVE_ID) revert KindMismatch(kind);
        return address(uint160(uint256(keccak256(abi.encodePacked(data)))));
    }

    function pending()
        external
        view
        returns (uint8 changeKind, address nextGuardian, uint64 newBlocks, uint64 executeAt)
    {
        Pending memory p = _pending;
        return (p.changeKind, p.nextGuardian, p.newBlocks, p.executeAt);
    }

    function setService(bytes32 name, uint8 kind, bytes32 data) external {
        _onlyGuardian();
        LocatorLib.check(name, kind, data);
        if (_kind[name] == kind && _data[name] == data) revert Unchanged();
        _kind[name] = kind;
        _data[name] = data;
        emit ServiceSet(name, kind, data);
    }

    function setGuardian(address next) external {
        _onlyGuardian();
        if (next == address(0)) revert ZeroAddress();
        AccountLib.check(next, address(this));
        if (next == guardian) revert Unchanged();
        _schedule(CHANGE_GUARDIAN, next, 0);
    }

    function setTimelock(uint64 blocks) external {
        _onlyGuardian();
        if (blocks > MAX_TIMELOCK_BLOCKS) revert TimelockTooLong(blocks, MAX_TIMELOCK_BLOCKS);
        if (blocks == timelockBlocks) revert Unchanged();
        _schedule(CHANGE_TIMELOCK, address(0), blocks);
    }

    /// Called by the incoming guardian of a pending guardian change. It proves
    /// the new address can act before it takes the slot: a mistyped address, or
    /// a contract that never calls this directory, cannot accept and so can
    /// never be applied. The current guardian cancels the stuck change. If the
    /// delay has already passed the change is applied in this call.
    function acceptGuardian() external {
        Pending memory p = _pending;
        if (p.changeKind == 0) revert NoPending();
        if (p.changeKind != CHANGE_GUARDIAN) revert NotAGuardianChange();
        if (msg.sender != p.nextGuardian) revert NotIncomingGuardian(msg.sender);
        pendingAccepted = true;
        emit GuardianAccepted(msg.sender, p.executeAt);
        if (block.number >= p.executeAt) executePending();
    }

    function cancelPending() external {
        _onlyGuardian();
        Pending memory p = _pending;
        if (p.changeKind == 0) revert NoPending();
        delete _pending;
        pendingAccepted = false;
        emit PendingCancelled(p.changeKind, p.nextGuardian, p.newBlocks, p.executeAt);
    }

    /// Anyone may call. Clears the slot before applying it. A guardian change
    /// also needs the incoming guardian's acceptance.
    function executePending() public {
        Pending memory p = _pending;
        if (p.changeKind == 0) revert NoPending();
        if (block.number < p.executeAt) revert TooEarly(p.executeAt, block.number);
        if (p.changeKind == CHANGE_GUARDIAN && !pendingAccepted) revert NotAccepted();
        delete _pending;
        pendingAccepted = false;
        if (p.changeKind == CHANGE_GUARDIAN) {
            guardian = p.nextGuardian;
            emit GuardianSet(p.nextGuardian);
        } else {
            timelockBlocks = p.newBlocks;
            emit TimelockSet(p.newBlocks);
        }
    }

    function _onlyGuardian() internal view {
        if (msg.sender != guardian) revert NotGuardian(msg.sender);
    }

    function _load(bytes32 name) internal view returns (uint8 kind, bytes32 data) {
        kind = _kind[name];
        if (kind == 0) revert NotFound(name);
        data = _data[name];
    }

    function _schedule(uint8 changeKind, address nextGuardian, uint64 newBlocks) internal {
        if (_pending.changeKind != 0) revert PendingExists();
        uint64 executeAt = _executeAt(timelockBlocks);
        _pending =
            Pending({changeKind: changeKind, nextGuardian: nextGuardian, newBlocks: newBlocks, executeAt: executeAt});
        pendingAccepted = false;
        emit PendingScheduled(changeKind, nextGuardian, newBlocks, executeAt);
        // Delay zero: a delay change applies at once. A guardian change still
        // waits for the incoming guardian to accept.
        if (timelockBlocks == 0 && changeKind == CHANGE_TIMELOCK) executePending();
    }

    function _executeAt(uint64 delay) internal view returns (uint64) {
        uint256 at = block.number + uint256(delay);
        if (at > type(uint64).max) revert TimelockOverflow();
        return uint64(at);
    }
}
