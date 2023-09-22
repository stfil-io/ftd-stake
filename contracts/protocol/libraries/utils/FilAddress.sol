// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/**
 * @author fevmate (https://github.com/wadealexc/fevmate)
 * @notice Utility functions for converting between id and
 * eth addresses. Helps implement address normalization.
 *
 * See README for more details about how to use this when
 * developing for the FEVM.
 */
library FilAddress {
    // Builtin Actor addresses (singletons)
    address constant SYSTEM_ACTOR = 0xfF00000000000000000000000000000000000000;

    // FEVM precompile addresses
    address constant LOOKUP_DELEGATED_ADDRESS = 0xfE00000000000000000000000000000000000002;

    // An ID address with id == 0. It's also equivalent to the system actor address
    // This is useful for bitwise operations
    address constant ZERO_ID_ADDRESS = SYSTEM_ACTOR;
    
    /**
     * @notice Convert ID to Eth address. Returns input if conversion fails.
     *
     * Attempt to convert address _a from an ID address to an Eth address
     * If _a is NOT an ID address, this returns _a
     * If _a does NOT have a corresponding Eth address, this returns _a
     * 
     * NOTE: It is possible this returns an ID address! If you want a method
     *       that will NEVER return an ID address, see mustNormalize below.
     */
    function normalize(address _a) internal view returns (address) {
        // First, check if we have an ID address. If we don't, return as-is
        (bool isID, uint64 id) = isIDAddress(_a);
        if (!isID) {
            return _a;
        }

        // We have an ID address -- attempt the conversion
        // If there is no corresponding Eth address, return _a
        (bool success, address eth) = getEthAddress(id);
        if (!success) {
            return _a;
        } else {
            return eth;
        }
    }

    // Used to clear the last 8 bytes of an address    (addr & U64_MASK)
    address constant U64_MASK = 0xFffFfFffffFfFFffffFFFffF0000000000000000;
    // Used to retrieve the last 8 bytes of an address (addr & MAX_U64)
    address constant MAX_U64 = 0x000000000000000000000000fFFFFFffFFFFfffF;

    /**
     * @notice Checks whether _a matches the ID address format.
     * If it does, returns true and the id
     * 
     * The ID address format is:
     * 0xFF | bytes11(0) | uint64(id)
     */
    function isIDAddress(address _a) internal pure returns (bool isID, uint64 id) {
        /// @solidity memory-safe-assembly
        assembly {
            // Zeroes out the last 8 bytes of _a
            let a_mask := and(_a, U64_MASK)

            // If the result is equal to the ZERO_ID_ADDRESS,
            // _a is an ID address.
            if eq(a_mask, ZERO_ID_ADDRESS) {
                isID := true
                id := and(_a, MAX_U64)
            }
        }
    }

    // An address with all bits set. Used to clean higher-order bits
    address constant ADDRESS_MASK = 0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF;

    /**
     * @notice Convert ID to Eth address by querying the lookup_delegated_address
     * precompile.
     *
     * If the actor ID corresponds to an Eth address, this will return (true, addr)
     * If the actor ID does NOT correspond to an Eth address, this will return (false, 0)
     * 
     * --- About ---
     * 
     * The lookup_delegated_address precompile retrieves the actor state corresponding
     * to the id. If the actor has a delegated address, it is returned using fil
     * address encoding (see below).
     *
     * f4, or delegated addresses, have a namespace as well as a subaddress that can
     * be up to 54 bytes long. This is to support future address formats. Currently,
     * though, the f4 format is only used to support Eth addresses.
     *
     * Consequently, the only addresses lookup_delegated_address should return have:
     * - Prefix:     "f4" address      - 1 byte   - (0x04)
     * - Namespace:  EAM actor id 10   - 1 byte   - (0x0A)
     * - Subaddress: EVM-style address - 20 bytes - (EVM address)
     * 
     * This method checks that the precompile output exactly matches this format:
     * 22 bytes, starting with 0x040A.
     * 
     * If we get anything else, we return (false, 0x00).
     */
    function getEthAddress(uint64 _id) internal view returns (bool success, address eth) {
        /// @solidity memory-safe-assembly
        assembly {
            // Call LOOKUP_DELEGATED_ADDRESS precompile
            //
            // Input: uint64 id, in standard EVM format (left-padded to 32 bytes)
            //
            // Output: LOOKUP_DELEGATED_ADDRESS returns an f4-encoded address. 
            // For Eth addresses, the format is a 20-byte address, prefixed with
            // 0x040A. So, we expect exactly 22 bytes of returndata.
            // 
            // Since we want to read an address from the returndata, we place the
            // output at memory offset 10, which means the address is already
            // word-aligned (10 + 22 == 32)
            //
            // NOTE: success and returndatasize checked at the end of the function
            mstore(0, _id)
            success := staticcall(gas(), LOOKUP_DELEGATED_ADDRESS, 0, 32, 10, 22)

            // Read result. LOOKUP_DELEGATED_ADDRESS returns raw, unpadded
            // bytes. Assuming we succeeded, we can extract the eth address
            // by reading from offset 0 and cleaning any higher-order bits:
            let result := mload(0)
            eth := and(ADDRESS_MASK, result)

            // Check that the returned address has the expected prefix. The
            // prefix is the first 2 bytes of returndata, located at memory 
            // offset 10. 
            // 
            // To isolate it, shift right by the # of bits in an address (160),
            // and clean all but the last 2 bytes.
            let prefix := and(0xFFFF, shr(160, result))
            if iszero(eq(prefix, 0x040A)) {
                success := false
                eth := 0
            }
        }
        // Checking these here because internal functions don't have
        // a good way to return from inline assembly.
        //
        // But, it's very important we do check these. If the output
        // wasn't exactly what we expected, we assume there's no eth
        // address and return (false, 0).
        if (!success || returnDataSize() != 22) {
            return (false, address(0));
        }
    }


    function returnDataSize() private pure returns (uint size) {
        /// @solidity memory-safe-assembly
        assembly { size := returndatasize() }
    }
}
