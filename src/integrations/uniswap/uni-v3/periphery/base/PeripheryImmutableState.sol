// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.6.7;

import '../interfaces/IPeripheryImmutableState.sol';

/// @title Immutable state
/// @notice Immutable state used by periphery contracts
abstract contract PeripheryImmutableState is IPeripheryImmutableState {
    address public immutable override factory;
    address public immutable override WETH9;

    constructor(address _factory, address _WETH9) public {
        factory = _factory;
        WETH9 = _WETH9;
    }
}
