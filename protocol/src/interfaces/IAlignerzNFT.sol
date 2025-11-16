// SPDX-License-Identifier: MIT
pragma solidity =0.8.29;

interface IAlignerzNFT {
    function mint(address to) external returns (uint256);

    function extOwnerOf(uint256 tokenId) external view returns (address);

    function burn(uint256 tokenId) external;

    function getTotalMinted() external view returns (uint256);
}