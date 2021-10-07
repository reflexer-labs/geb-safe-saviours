pragma solidity 0.6.7;

import "ds-test/test.sol";

import {SAFEEngine} from 'geb/SAFEEngine.sol';
import {OracleRelayer} from 'geb/OracleRelayer.sol';
import {GebSafeManager} from "geb-safe-manager/GebSafeManager.sol";

import "../SaviourCRatioSetter.sol";

abstract contract Hevm {
    function warp(uint256) virtual public;
}

contract User {
    function modifyParameters(SaviourCRatioSetter setter, bytes32 parameter, address data) external {
        setter.modifyParameters(parameter, data);
    }
    function setDefaultCRatio(SaviourCRatioSetter setter, bytes32 collateralType, uint256 cRatio) external {
        setter.setDefaultCRatio(collateralType, cRatio);
    }
    function setMinDesiredCollateralizationRatio(SaviourCRatioSetter setter, bytes32 collateralType, uint256 cRatio) external {
        setter.setMinDesiredCollateralizationRatio(collateralType, cRatio);
    }
}

contract SaviourCRatioSetterTest is DSTest {
    Hevm hevm;

    User user;

    SAFEEngine safeEngine;
    OracleRelayer oracleRelayer;
    GebSafeManager safeManager;
    SaviourCRatioSetter setter;

    function setUp() public {
        hevm = Hevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
        hevm.warp(604411200);

        user = new User();

        safeEngine = new SAFEEngine();
        oracleRelayer = new OracleRelayer(address(safeEngine));
        safeManager = new GebSafeManager(address(safeEngine));

        oracleRelayer.modifyParameters("gold", "safetyCRatio", ray(1.5 ether));
        oracleRelayer.modifyParameters("gold", "liquidationCRatio", ray(1.5 ether));

        setter = new SaviourCRatioSetter(address(oracleRelayer), address(safeManager));
    }

    function ray(uint wad) internal pure returns (uint) {
        return wad * 10 ** 9;
    }

    function test_setup() public {
        assertEq(setter.authorizedAccounts(address(this)), 1);
        assertEq(address(setter.oracleRelayer()), address(oracleRelayer));
        assertEq(address(setter.safeManager()), address(safeManager));
    }
    function test_modifyParameters() public {
        oracleRelayer = new OracleRelayer(address(safeEngine));
        setter.modifyParameters("oracleRelayer", address(oracleRelayer));
        assertEq(address(setter.oracleRelayer()), address(oracleRelayer));
    }
    function testFail_modifyParameters_unauthorized() public {
        oracleRelayer = new OracleRelayer(address(safeEngine));
        user.modifyParameters(setter, "oracleRelayer", address(oracleRelayer));
    }
    function testFail_setDefaultRatio_unauthorized() public {
        user.setDefaultCRatio(setter, "gold", 200);
    }
    function testFail_setDefaultRatio_inexistent_collateral() public {
        setter.setDefaultCRatio("silver", 200);
    }
    function testFail_setDefaultRatio_low_proposed_cratio() public {
        setter.setDefaultCRatio("gold", 140);
    }
    function testFail_setDefaultRatio_high_proposed_ratio() public {
        setter.setDefaultCRatio("gold", setter.MAX_CRATIO() + 1);
    }
    function test_setDefaultRatio() public {
        setter.setDefaultCRatio("gold", 200);
        assertEq(setter.defaultDesiredCollateralizationRatios("gold"), 200);
    }
    function testFail_setMinCRatio_unauthorized() public {
        user.setMinDesiredCollateralizationRatio(setter, "gold", 200);
    }
    function testFail_setMinCRatio_above_max() public {
        setter.setMinDesiredCollateralizationRatio("gold", setter.MAX_CRATIO() + 1);
    }
    function test_setMinCRatio() public {
        setter.setMinDesiredCollateralizationRatio("gold", 200);
        assertEq(setter.minDesiredCollateralizationRatios("gold"), 200);
    }
    function testFail_setDesiredCRatio_unauthorized() public {
        setter.setDesiredCollateralizationRatio("gold", 1, 200);
    }
    function testFail_setDesiredCRatio_proposed_ratio_smaller_than_scaled() public {
        safeManager.openSAFE("gold", address(this));
        setter.setDesiredCollateralizationRatio("gold", 1, 140);
    }
    function testFail_setDesiredCRatio_proposed_ratio_smaller_than_min() public {
        safeManager.openSAFE("gold", address(this));
        setter.setMinDesiredCollateralizationRatio("gold", 200);
        setter.setDesiredCollateralizationRatio("gold", 1, 199);
    }
    function testFail_setDesiredCRatio_proposed_ratio_higher_than_max() public {
        safeManager.openSAFE("gold", address(this));
        setter.setMinDesiredCollateralizationRatio("gold", 200);
        setter.setDesiredCollateralizationRatio("gold", 1, setter.MAX_CRATIO() + 1);
    }
    function test_setDesiredCRatio() public {
        safeManager.openSAFE("gold", address(this));
        setter.setMinDesiredCollateralizationRatio("gold", 200);
        setter.setDesiredCollateralizationRatio("gold", 1, 200);
        assertEq(setter.desiredCollateralizationRatios("gold", safeManager.safes(1)), 200);
    }
}
