# GEB Safe Saviours

This repository contains several SAFE saviours that can be attached to GEB Safes and protect them from liquidation.

For more details on what saviours are and how they generally work, read the [official documentation](https://docs.reflexer.finance/liquidation-protection/safe-protection).

# Saviour Types

- **CompoundSystemTargetCoinSafeSaviour**: this saviour lends system coins on a Compound like market and repays a Safe's debt when it's liquidated
- **CurveV1MaxSafeSaviour**: this saviour uses a Curve V1 pool to withdraw liquidity and save a Safe
- **GeneralTokenReserveSafeSaviour**: this saviour uses collateral to top up a Safe and save it
- **GeneralUnderlyingMaxUniswapV3SafeSaviour**: this saviour uses up to two different Uniswap v3 positions to protect a SAFE. Each position must have system coins in it but besides that it can be paired with any other token
- **NativeUnderlyingMaxUniswapV2SafeSaviour**: this saviour withdraws liquidity from Uniswap V2 and repays debt and/or tops up a Safe in order to save it
- **NativeUnderlyingTargetUniswapV3SafeSaviour** and **NativeUnderlyingMaxUniswapV3SafeSaviour**: these saviours withdraw liquidity from Uniswap V3 and repay debt and top up a Safe in order to save it
- **SystemCoinTargetUniswapV2SafeSaviour**: this saviour withdraws liquidity from Uniswap V2, swaps one of the tokens for the Safe's collateral and repays debt and/or tops up the Safe in order to save it
- **YearnV3MaxSystemCoinSafeSaviour**: this saviour lends system coins in a Yearn v3 strategy vault and repays a Safe's debt when it's liquidated
