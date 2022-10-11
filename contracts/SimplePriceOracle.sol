// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "./PriceOracle.sol";
import "./CErc20.sol";

contract SimplePriceOracle is PriceOracle {
    mapping(address => uint) prices;
    event PricePosted(address asset, uint previousPriceMantissa, uint requestedPriceMantissa, uint newPriceMantissa);

    // 获取CToken对应的标的资产的地址
    function _getUnderlyingAddress(CToken cToken) private view returns (address) {
        address asset;
        if (compareStrings(cToken.symbol(), "cETH")) { // cETH特殊处理
            // 这个地址被许多公司（Bancor、Kyber 等）用作所谓的“以太币代币”的“占位符”，以允许像系统中的任何其他代币一样处理以太币。
            // 它不应该是您将以太币或代币转移到的地址。
            // 显然没有人拥有它的私钥，所以如果你选择将你的资产转移给它，那么你可以放心，你永远不会再看到它们了。
            asset = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
        } else {
            // CToken-->address-->CErc20, 取标的资产, underlying状态变量定义在CErc20Storage中的
            asset = address(CErc20(address(cToken)).underlying());
        }
        return asset;
    }

    // 获取CToken对应的标的资产的价格
    function getUnderlyingPrice(CToken cToken) public override view returns (uint) {
        // 两步：1.获取CToken对应的标的资产的地址 2.获取标的资产的价格
        return prices[_getUnderlyingAddress(cToken)];
    }

    // 上传CToken对应的标的资产的价格，由外部触发
    function setUnderlyingPrice(CToken cToken, uint underlyingPriceMantissa) public {
        address asset = _getUnderlyingAddress(cToken);
        emit PricePosted(asset, prices[asset], underlyingPriceMantissa, underlyingPriceMantissa);
        prices[asset] = underlyingPriceMantissa;
    }

    function setDirectPrice(address asset, uint price) public {
        emit PricePosted(asset, prices[asset], price, price);
        prices[asset] = price;
    }

    // v1 price oracle interface for use as backing of proxy
    function assetPrices(address asset) external view returns (uint) {
        return prices[asset];
    }

    function compareStrings(string memory a, string memory b) internal pure returns (bool) {
        return (keccak256(abi.encodePacked((a))) == keccak256(abi.encodePacked((b))));
    }
}
