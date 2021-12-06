// SPDX-License-Identifier: MIT LICENSE 

pragma solidity ^0.8.0;

interface ICompany {
  function addManyToBarnAndPack(address account, uint16[] calldata tokenIds) external;
  function randomBossOwner(uint256 seed) external view returns (address);
}