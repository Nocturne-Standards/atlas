// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

/// Shared locator checks for the directory and for EvmWarden.
/// Both contracts store the same `{kind, data}` pair. This library is the
/// one place those checks live, so the two contracts cannot drift.
library LocatorLib {
    uint8 internal constant KIND_EVM_ADDRESS = 1;
    uint8 internal constant KIND_NATIVE_ID = 2;

    error EmptyName();
    error BadKind(uint8 kind);
    error ZeroLocator();
    error DirtyAddress(bytes32 data);

    function check(bytes32 name, uint8 kind, bytes32 data) internal pure {
        if (name == bytes32(0)) revert EmptyName();
        if (kind == KIND_EVM_ADDRESS) {
            if (uint256(data) >> 160 != 0) revert DirtyAddress(data);
            if (uint160(uint256(data)) == 0) revert ZeroLocator();
            return;
        }
        if (kind == KIND_NATIVE_ID) {
            if (data == bytes32(0)) revert ZeroLocator();
            return;
        }
        revert BadKind(kind);
    }
}
