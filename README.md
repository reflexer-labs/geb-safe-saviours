# GEB Safe Saviours

This repository contains several SAFE saviours that can be attached to GEB Safes and protect them from liquidation.

For more details on what saviours are and how they generally work, read the [official documentation](hhttps://docs.reflexer.finance/liquidation-protection/safe-protection).

# Saviour Types

- **CompoundSystemCoinSafeSaviour**: this saviour lends system coins on a Compound like market and repays a Safe's debt when it's liquidated
- **CurveV1SafeSaviour**: this saviour uses a Curve V1 pool to withdraw liquidity and save a Safe
- **GeneralTokenReserveSafeSaviour**: this saviour uses collateral to top up a Safe and save it
- **GeneralUnderlyingUniswapV3SafeSaviour**: this saviour uses up to two different Uniswap v3 positions to protect a SAFE. Each position must have system coins in it but besides that it can be paired with any other token
- **NativeUnderlyingUniswapV2SafeSaviour**: this saviour withdraws liquidity from Uniswap V2 and repays debt and/or tops up a Safe in order to save it
- **NativeUnderlyingUniswapV3SafeSaviour**: this saviour withdraws liquidity from Uniswap V3 and repays debt and tops up a Safe in order to save it
- **SystemCoinUniswapV2SafeSaviour**: this saviour withdraws liquidity from Uniswap V2, swaps one of the tokens for the Safe's collateral and repays debt and/or tops up the Safe in order to save it
- **YearnSystemCoinSafeSaviour**: this saviour lends system coins in a Yearn strategy vault and repays a Safe's debt when it's liquidated

# Build Errors

In some cases you may need to use the `--no-yul-optimize` flag in order to build and test these contracts. This is because some contracts may use `pragma experimental ABIEncoderV2` which can throw a Yul error.
