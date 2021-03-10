pragma solidity ^0.6.7;

import "ds-test/test.sol";

import "../SAFESaviourRegistry.sol";

abstract contract Hevm {
    function warp(uint256) virtual public;
}
contract Usr {
    function toggleSaviour(address registry, address saviour) external {
        SAFESaviourRegistry(registry).toggleSaviour(saviour);
    }
    function markSave(address registry, bytes32 collateralType, address safeHandler) external {
        SAFESaviourRegistry(registry).markSave(collateralType, safeHandler);
    }
}

contract SAFESaviourRegistryTest is DSTest {
    Hevm hevm;

    SAFESaviourRegistry registry;
    Usr alice;
    Usr bob;

    uint256 saveCooldown = 1 hours;

    uint constant HUNDRED = 10 ** 2;
    uint constant RAY     = 10 ** 27;

    function ray(uint wad) internal pure returns (uint) {
        return wad * 10 ** 9;
    }
    function rad(uint wad) internal pure returns (uint) {
        return wad * RAY;
    }

    function setUp() public {
        hevm = Hevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
        hevm.warp(604411200);

        alice = new Usr();
        bob   = new Usr();

        registry = new SAFESaviourRegistry(saveCooldown);
    }

    function test_setup() public {
        assertEq(registry.saveCooldown(), saveCooldown);
        assertEq(registry.authorizedAccounts(address(this)), 1);
    }
    function test_modify_save_cooldown() public {
        registry.modifyParameters("saveCooldown", 1 days);
        assertEq(registry.saveCooldown(), 1 days);
    }
    function test_toggle_saviour() public {
        assertEq(registry.saviours(address(alice)), 0);
        registry.toggleSaviour(address(alice));
        assertEq(registry.saviours(address(alice)), 1);
        registry.toggleSaviour(address(alice));
        assertEq(registry.saviours(address(alice)), 0);
    }
    function testFail_toggle_saviour_by_unauthed() public {
        alice.toggleSaviour(address(registry), address(bob));
    }
    function testFail_mark_save_not_saviour() public {
        alice.markSave(address(registry), "ETH-A", address(0x1));
    }
    function testFail_mark_save_as_saviour_without_waiting() public {
        registry.toggleSaviour(address(alice));
        alice.markSave(address(registry), "ETH-A", address(0x1));
        alice.markSave(address(registry), "ETH-A", address(0x1));
    }
    function test_mark_save_as_saviour() public {
        registry.toggleSaviour(address(alice));
        alice.markSave(address(registry), "ETH-A", address(0x1));
        assertEq(registry.lastSaveTime("ETH-A", address(0x1)), now);
    }
    function test_mark_save_as_saviour_after_waiting() public {
        registry.toggleSaviour(address(alice));
        alice.markSave(address(registry), "ETH-A", address(0x1));
        hevm.warp(now + registry.saveCooldown() + 1);
        alice.markSave(address(registry), "ETH-A", address(0x1));
        assertEq(registry.lastSaveTime("ETH-A", address(0x1)), now);
    }
    function test_mark_save_as_saviour_same_handlers_different_collaterals() public {
        registry.toggleSaviour(address(alice));
        alice.markSave(address(registry), "ETH-A", address(0x1));
        alice.markSave(address(registry), "ETH-B", address(0x1));
        assertEq(registry.lastSaveTime("ETH-B", address(0x1)), now);
        assertEq(registry.lastSaveTime("ETH-A", address(0x1)), now);
    }
}
