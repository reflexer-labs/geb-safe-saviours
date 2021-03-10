pragma solidity ^0.6.7;

abstract contract LiquidationEngineLike {
    function connectSAFESaviour(address) virtual external;
    function disconnectSAFESaviour(address) virtual external;
}
abstract contract SAFESaviourRegistryLike {
    function toggleSaviour(address) virtual external;
}

contract NoAuthSaviourGateKeeper {
    LiquidationEngineLike   public liquidationEngine;
    SAFESaviourRegistryLike public registry;

    constructor(address liquidationEngine_, address registry_) public {
        require(liquidationEngine_ != address(0), "NoAuthSaviourGateKeeper/null-liquidation-engine");
        require(registry_ != address(0), "NoAuthSaviourGateKeeper/null-registry");
        liquidationEngine = LiquidationEngineLike(liquidationEngine_);
        registry          = SAFESaviourRegistryLike(registry_);
    }

    // --- Liquidation Engine Auth ---
    function connectSAFESaviour(address saviour) external {
        liquidationEngine.connectSAFESaviour(saviour);
    }
    function disconnectSAFESaviour(address saviour) external {
        liquidationEngine.disconnectSAFESaviour(saviour);
    }

    // --- Saviour Registry Auth ---
    function toggleSaviour(address saviour) external {
        registry.toggleSaviour(saviour);
    }
}
