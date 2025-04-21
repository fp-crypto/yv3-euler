// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

interface IAuctionFactory {
    event DeployedNewAuction(address indexed auction, address indexed want);
    function DEFAULT_AUCTION_LENGTH() external view returns (uint256);
    function DEFAULT_STARTING_PRICE() external view returns (uint256);
    function auctions(uint256) external view returns (address);
    function createNewAuction(address _want) external returns (address);
    function createNewAuction(
        address _want,
        address _receiver,
        address _governance,
        uint256 _auctionLength
    ) external returns (address);
    function createNewAuction(
        address _want,
        address _receiver,
        address _governance,
        uint256 _auctionLength,
        uint256 _startingPrice
    ) external returns (address);
    function createNewAuction(
        address _want,
        address _receiver,
        address _governance
    ) external returns (address);
    function createNewAuction(
        address _want,
        address _receiver
    ) external returns (address);
    function getAllAuctions() external view returns (address[] memory);
    function numberOfAuctions() external view returns (uint256);
    function original() external view returns (address);
}
