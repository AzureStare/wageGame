pragma solidity ^0.8.0;
contract Random {
    uint256 private nonce;
    function getRandom(uint256 seed) external view returns (uint256){
      return uint256(keccak256(abi.encodePacked(
      tx.origin,
      blockhash(block.number - 1),
      block.timestamp,
      nonce,
      seed
    )));
    }
    function addNonce() external{
       nonce = nonce + 1;
    }
}