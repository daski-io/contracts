// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Shared pagination slicer. Every Daski registry/storage that
///         exposes a `getXxxPaginated(offset, limit)` view duplicated the
///         same `if (offset >= length) return empty / cap end / loop-copy`
///         shape. Solidity has no generics over array element types, so this
///         library provides one slicer per element type used in the codebase.
///         Internal functions are inlined by the compiler — no gas overhead
///         versus the prior in-contract copies.
library LibPagination {
    function paginate(bytes32[] storage all, uint256 offset, uint256 limit)
        internal
        view
        returns (bytes32[] memory page)
    {
        uint256 length = all.length;
        if (offset >= length) {
            return new bytes32[](0);
        }
        uint256 end = offset + limit;
        if (end > length) {
            end = length;
        }
        page = new bytes32[](end - offset);
        for (uint256 i = 0; i < page.length; i++) {
            page[i] = all[offset + i];
        }
    }

    function paginate(uint256[] storage all, uint256 offset, uint256 limit)
        internal
        view
        returns (uint256[] memory page)
    {
        uint256 length = all.length;
        if (offset >= length) {
            return new uint256[](0);
        }
        uint256 end = offset + limit;
        if (end > length) {
            end = length;
        }
        page = new uint256[](end - offset);
        for (uint256 i = 0; i < page.length; i++) {
            page[i] = all[offset + i];
        }
    }

    function paginate(address[] storage all, uint256 offset, uint256 limit)
        internal
        view
        returns (address[] memory page)
    {
        uint256 length = all.length;
        if (offset >= length) {
            return new address[](0);
        }
        uint256 end = offset + limit;
        if (end > length) {
            end = length;
        }
        page = new address[](end - offset);
        for (uint256 i = 0; i < page.length; i++) {
            page[i] = all[offset + i];
        }
    }
}
