# GEB Safe Saviours

This repository contains several SAFE saviours that can be attached to GEB Safes and protect them from liquidation.

For more details on what saviours are and how they generally work, read the [official documentation](https://docs.reflexer.finance/integrations/safe-protection).

# Saviour Types

- CompoundSystemCoinSafeSaviour: this saviour lends system coins on a Compound like market and repays a Safe's debt when it's liquidated
- GeneralTokenReserveSafeSaviour: this saviour uses collateral to top up a Safe and save it
- NativeUnderlyingUniswapV2SafeSaviour: this saviour withdraws liquidity from Uniswap V2 and repays debt and/or tops up a Safe in order to save it
- NativeUnderlyingUniswapV3SafeSaviour: this saviour withdraws liquidity from Uniswap V3 and repays debt and/or tops up a Safe in order to save it
- SystemCoinUniswapV2SafeSaviour: this saviour withdraws liquidity from Uniswap V2, swaps one of the tokens for the Safe's collateral and repays debt and/or tops up the Safe in order to save it
- SystemCoinUniswapV3SafeSaviour: this saviour withdraws liquidity from Uniswap V3, swaps one of the tokens for the Safe's collateral and repays debt and/or tops up the Safe in order to save it
- YearnSystemCoinSafeSaviour: this saviour lends system coins in a Yearn strategy vault and repays a Safe's debt when it's liquidated
