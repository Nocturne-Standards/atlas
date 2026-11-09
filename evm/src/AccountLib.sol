// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

/// Shared checks for an address that is about to become a guardian or a
/// scheduler. EvmAtlas and EvmWarden both use it, so the warden refuses at
/// queue time exactly what the directory would refuse when the change is
/// forwarded, and a forward cannot fail.
library AccountLib {
    /// Zero and the precompile range (0x01..0xff) have no key that can sign.
    uint160 internal constant RESERVED_BELOW = 0x100;

    error ReservedAddress(address account);

    /// @param account the address to vet
    /// @param self    the contract that must not name itself (it never calls
    ///                its own guardian or scheduler functions)
    function check(address account, address self) internal pure {
        if (uint160(account) < RESERVED_BELOW || account == self) revert ReservedAddress(account);
    }
}
