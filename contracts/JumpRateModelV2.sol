// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "./BaseJumpRateModelV2.sol";
import "./InterestRateModel.sol";


/**
  * @title Compound's JumpRateModel Contract V2 for V2 cTokens
  * @author Arr00
  * @notice Supports only for V2 cTokens
  */
contract JumpRateModelV2 is InterestRateModel, BaseJumpRateModelV2  {

	/**
     * @notice Calculates the current borrow rate per block
     * 计算每个区块的当前借款利率
     * @param cash The amount of cash in the market
     * 市场上的现金量
     * @param borrows The amount of borrows in the market
     * 市场上的借款数额
     * @param reserves The amount of reserves in the market
     * 市场上的准备金数量
     * @return The borrow rate percentage per block as a mantissa (scaled by 1e18)
     * 以mantissa表示的每个区块的借款利率百分比(乘以1e18)
     */
    function getBorrowRate(uint cash, uint borrows, uint reserves) override external view returns (uint) {
        // 计算每个区块的当前借款利率
        return getBorrowRateInternal(cash, borrows, reserves);
    }

    constructor(uint baseRatePerYear, uint multiplierPerYear, uint jumpMultiplierPerYear, uint kink_, address owner_)

    BaseJumpRateModelV2(baseRatePerYear,multiplierPerYear,jumpMultiplierPerYear,kink_,owner_) public {}
}
