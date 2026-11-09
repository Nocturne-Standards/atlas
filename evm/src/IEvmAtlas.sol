// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

/// The directory surface EvmWarden calls. Reads are open. Writes require
/// the directory's guardian, which in production is the warden itself.
interface IEvmAtlas {
    function chainId() external view returns (uint256);

    function guardian() external view returns (address);

    function timelockBlocks() external view returns (uint64);

    function pending()
        external
        view
        returns (uint8 changeKind, address nextGuardian, uint64 newBlocks, uint64 executeAt);

    function resolve(bytes32 name) external view returns (uint8 kind, bytes32 data);

    function setService(bytes32 name, uint8 kind, bytes32 data) external;

    function setGuardian(address next) external;

    function setTimelock(uint64 blocks) external;

    function cancelPending() external;

    function acceptGuardian() external;
}
