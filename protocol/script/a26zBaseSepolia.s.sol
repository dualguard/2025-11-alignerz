// SPDX-License-Identifier: MIT
pragma solidity =0.8.29;

import {Script, console} from "forge-std/Script.sol";
import {Aligners26} from "../src/contracts/token/Aligners26.sol";
import {AlignerzNFT} from "../src/contracts/nft/AlignerzNFT.sol";
import {MockUSD} from "../src/MockUSD.sol";
import {AlignerzVesting} from "../src/contracts/vesting/AlignerzVesting.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract a26zBaseSepolia is Script {
    Aligners26 public erc20;
    AlignerzNFT public nft;
    MockUSD public mockUSD;
    AlignerzVesting public vesting;

    function setUp() public {}

    function run() public {
        vm.createSelectFork(vm.rpcUrl("base-sepolia"));

        vm.startBroadcast();

        mockUSD = new MockUSD();
        console.logString("MockUSD deployed at: ");
        console.logAddress(address(mockUSD));

        erc20 = new Aligners26("26Aligners", "A26Z");
        console.logString("Aligners26 deployed at: ");
        console.logAddress(address(erc20));

        nft = new AlignerzNFT("AlignerzNFT", "AZNFT", "https://alignerz.cryptoware.me/nft/");
        console.logString("AlignerzNFT deployed at: ");
        console.logAddress(address(nft));

        address payable proxy = payable(Upgrades.deployUUPSProxy(
            "AlignerzVesting.sol",
            abi.encodeCall(AlignerzVesting.initialize, (address(nft))))
        );
        vesting = AlignerzVesting(proxy);
        console.logString("AlignerzVesting deployed at: ");
        console.logAddress(proxy);

        nft.addMinter(proxy);
        console.logString("Set AlignerzVesting as minter for AlignerzNFT");
        nft.transferOwnership(0x64E6728D28D323Dd17b4232857B3A8e3AB9194d9);
        mockUSD.transferOwnership(0x64E6728D28D323Dd17b4232857B3A8e3AB9194d9);
        erc20.transferOwnership(0x64E6728D28D323Dd17b4232857B3A8e3AB9194d9);
        vesting.transferOwnership(0x64E6728D28D323Dd17b4232857B3A8e3AB9194d9);
        console.logString("Transfers tokens to the new owner");

        vm.stopBroadcast();
    }
}
