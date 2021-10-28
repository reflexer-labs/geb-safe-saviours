pragma solidity 0.6.7;

import "ds-test/test.sol";
import "ds-weth/weth9.sol";
import "ds-token/token.sol";

import "../interfaces/IERC721.sol";

import {SAFEEngine} from 'geb/SAFEEngine.sol';
import {Coin} from 'geb/Coin.sol';
import {LiquidationEngine} from 'geb/LiquidationEngine.sol';
import {AccountingEngine} from 'geb/AccountingEngine.sol';
import {TaxCollector} from 'geb/TaxCollector.sol';
import {BasicCollateralJoin, CoinJoin} from 'geb/BasicTokenAdapters.sol';
import {OracleRelayer} from 'geb/OracleRelayer.sol';
import {EnglishCollateralAuctionHouse} from 'geb/CollateralAuctionHouse.sol';
import {GebSafeManager} from "geb-safe-manager/GebSafeManager.sol";

import {SAFESaviourRegistry} from "../SAFESaviourRegistry.sol";

import "../integrations/uniswap/uni-v3/core/UniswapV3Factory.sol";
import "../integrations/uniswap/uni-v3/core/UniswapV3Pool.sol";

import "../saviours/NativeUnderlyingMaxUniswapV3SafeSaviour.sol";

// Users
contract PoolUser {


    function doTransferNFT(
        uint8 position,
        address receiver
    ) public {

    }

    function doApproveNFT(
        uint8 position,
        address who
    ) public {

    }
}

abstract contract Hevm {
    function warp(uint256) public virtual;
    function roll(uint256) public virtual;
}

contract NativeUnderlyingMaxUniswapV3SafeSaviourTest is DSTest {
    Hevm hevm;

    UniswapV3Pool pool;

    uint160 initialPoolPrice;

    PoolUser u1;
    PoolUser u2;

    function setUp() public {

    }

    function test_setup() public {

    }
}
