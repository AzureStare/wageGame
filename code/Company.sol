pragma solidity ^0.8.0;

import "./IERC721Receiver.sol";
import "./Pausable.sol";
import "./Boss.sol";
import "./WAG.sol";

contract Company is Ownable, IERC721Receiver, Pausable {
  
  // maximum alpha score for a Boss
  uint8 public constant MAX_ALPHA = 8;

  // struct to store a stake's token, owner, and earning values
  struct Stake {
    uint16 tokenId;
    uint80 value;
    address owner;
  }

  event TokenStaked(address owner, uint256 tokenId, uint256 value);
  event ProgrammerClaimed(address owner, uint256 tokenId, uint256 earned, bool unstaked);
  event BossClaimed(address owner, uint256 tokenId, uint256 earned, bool unstaked);

  // reference to the Boss NFT contract
  Boss boss;
  // reference to the $WAG contract for minting $WAG earnings
  WAG wag;

  // maps tokenId to stake
  mapping(uint256 => Stake) public barn; 
  // maps alpha to all Boss stakes with that alpha
  mapping(uint256 => Stake[]) public pack; 
  // tracks location of each Boss in Pack
  mapping(uint256 => uint256) public packIndices; 
  // total alpha scores staked
  uint256 public totalAlphaStaked = 0; 
  // any rewards distributed when no wolves are staked
  uint256 public unaccountedRewards = 0; 
  // amount of $WAG due for each alpha point staked
  uint256 public wagPerAlpha = 0; 

  uint256 private LAST_DAMPING_TIME;

  // programmer earn 10000 $WAG per day
  uint256 private DAILY_WAG_RATE = 10000 ether;
  // programmer must have 2 days worth of $WAG to unstake or else it's too cold
  uint256 public constant MINIMUM_TO_EXIT = 2 days;
  
  uint256 public constant DAMPING_PERIOD = 7 days;
  // bosses take a 20% tax on all $WAG claimed
  uint256 public constant WAG_CLAIM_TAX_PERCENTAGE = 20;
  // there will only ever be (roughly) 2.4 billion $WAG earned through staking
  uint256 public constant MAXIMUM_GLOBAL_WAG = 2400000000 ether;

  // amount of $WAG earned so far
  uint256 public totalWagEarned;
  // number of Programmer staked in the Company
  uint256 public totalProgrammerStaked;
  // the last time $WAG was claimed
  uint256 public lastClaimTimestamp;

  uint256 public wageClaimed;
  uint256 public wageStolen;
  uint256 public wageTaxed;

  // emergency rescue to allow unstaking without any checks but without $WAG
  bool public rescueEnabled = false;

  /**
   * @param _boss reference to the Boss NFT contract
   * @param _wag reference to the $WAG token
   */
  constructor(address _boss, address _wag) { 
    boss = Boss(_boss);
    wag = WAG(_wag);
    LAST_DAMPING_TIME = block.timestamp;
  }

  /** STAKING */

  /**
   * adds Programmer and Wolves to the Barn and Pack
   * @param account the address of the staker
   * @param tokenIds the IDs of the Programmer and Bosses to stake
   */
  function addManyToBarnAndPack(address account, uint16[] calldata tokenIds) external {
    require(account == _msgSender() || _msgSender() == address(boss), "DONT GIVE YOUR TOKENS AWAY");
    for (uint i = 0; i < tokenIds.length; i++) {
      if (_msgSender() != address(boss)) { // dont do this step if its a mint + stake
        require(boss.ownerOf(tokenIds[i]) == _msgSender(), "AINT YO TOKEN");
        boss.transferFrom(_msgSender(), address(this), tokenIds[i]);
      } else if (tokenIds[i] == 0) {
        continue; // there may be gaps in the array for stolen tokens
      }

      if (isEmployee(tokenIds[i])) 
        _addProgrammerToBarn(account, tokenIds[i]);
      else 
        _addBossToPack(account, tokenIds[i]);
    }
  }

  /**
   * adds a single Programmer to the Barn
   * @param account the address of the staker
   * @param tokenId the ID of the Programmer to add to the Company
   */
  function _addProgrammerToBarn(address account, uint256 tokenId) internal whenNotPaused _updateEarnings {
    barn[tokenId] = Stake({
      owner: account,
      tokenId: uint16(tokenId),
      value: uint80(block.timestamp)
    });
    totalProgrammerStaked += 1;
    emit TokenStaked(account, tokenId, block.timestamp);
  }

  /**
   * adds a single Boss to the Pack
   * @param account the address of the staker
   * @param tokenId the ID of the Boss to add to the Pack
   */
  function _addBossToPack(address account, uint256 tokenId) internal {
    uint256 alpha = _alphaForBoss(tokenId);
    totalAlphaStaked += alpha; // Portion of earnings ranges from 8 to 5
    packIndices[tokenId] = pack[alpha].length; // Store the location of the boss in the Pack
    pack[alpha].push(Stake({
      owner: account,
      tokenId: uint16(tokenId),
      value: uint80(wagPerAlpha)
    })); // Add the boss to the Pack
    emit TokenStaked(account, tokenId, wagPerAlpha);
  }

  /** CLAIMING / UNSTAKING */

  /**
   * realize $WAG earnings and optionally unstake tokens from the Barn / Pack
   * to unstake a Programmer it will require it has 2 days worth of $WAG unclaimed
   * @param tokenIds the IDs of the tokens to claim earnings from
   * @param unstake whether or not to unstake ALL of the tokens listed in tokenIds
   */
  function claimManyFromBarnAndPack(uint16[] calldata tokenIds, bool unstake) external whenNotPaused _updateEarnings {
    uint256 owed = 0;
    for (uint i = 0; i < tokenIds.length; i++) {
      if (isEmployee(tokenIds[i]))
        owed += _claimProgrammerFromBarn(tokenIds[i], unstake);
      else
        owed += _claimBossFromPack(tokenIds[i], unstake);
    }
    if (owed == 0) return;
    wageClaimed += owed;
    wag.mint(_msgSender(), owed);
  }

  /**
   * realize $WAG earnings for a single Programmer and optionally unstake it
   * if not unstaking, pay a 20% tax to the staked Wolves
   * if unstaking, there is a 50% chance all $WAG is stolen
   * @param tokenId the ID of the Programmer to claim earnings from
   * @param unstake whether or not to unstake the Programmer
   * @return owed - the amount of $WAG earned
   */
  function _claimProgrammerFromBarn(uint256 tokenId, bool unstake) internal returns (uint256 owed) {
    Stake memory stake = barn[tokenId];
    require(stake.owner == _msgSender(), "SWIPER, NO SWIPING");
    require(!(unstake && block.timestamp - stake.value < MINIMUM_TO_EXIT), "GONNA BE COLD WITHOUT TWO DAY'S WAG");
    if (totalWagEarned < MAXIMUM_GLOBAL_WAG) {
      owed = (block.timestamp - stake.value) * DAILY_WAG_RATE / 1 days;
    } else if (stake.value > lastClaimTimestamp) {
      owed = 0; // $WAG production stopped already
    } else {
      owed = (lastClaimTimestamp - stake.value) * DAILY_WAG_RATE / 1 days; // stop earning additional $WAG if it's all been earned
    }
    if (unstake) {
      if (random(tokenId) & 1 == 1) { // 50% chance of all $WAG stolen
        _payBossTax(owed);
        wageStolen += owed;
        owed = 0;
      }
      boss.safeTransferFrom(address(this), _msgSender(), tokenId, ""); // send back Programmer
      delete barn[tokenId];
      totalProgrammerStaked -= 1;
    } else {
      uint256 taxWage = owed * WAG_CLAIM_TAX_PERCENTAGE / 100;
      wageTaxed += taxWage;
      _payBossTax(taxWage); // percentage tax to staked wolves
      owed = owed - taxWage; // remainder goes to Programmer owner
      barn[tokenId] = Stake({
        owner: _msgSender(),
        tokenId: uint16(tokenId),
        value: uint80(block.timestamp)
      }); // reset stake
    }
    emit ProgrammerClaimed(stake.owner, tokenId, owed, unstake);
  }

  /**
   * realize $WAG earnings for a single Boss and optionally unstake it
   * Wolves earn $WAG proportional to their Alpha rank
   * @param tokenId the ID of the Boss to claim earnings from
   * @param unstake whether or not to unstake the Boss
   * @return owed - the amount of $WAG earned
   */
  function _claimBossFromPack(uint256 tokenId, bool unstake) internal returns (uint256 owed) {
    require(boss.ownerOf(tokenId) == address(this), "AINT A PART OF THE PACK");
    uint256 alpha = _alphaForBoss(tokenId);
    Stake memory stake = pack[alpha][packIndices[tokenId]];
    require(stake.owner == _msgSender(), "SWIPER, NO SWIPING");
    owed = (alpha) * (wagPerAlpha - stake.value); // Calculate portion of tokens based on Alpha
    if (unstake) {
      totalAlphaStaked -= alpha; // Remove Alpha from total staked
      boss.safeTransferFrom(address(this), _msgSender(), tokenId, ""); // Send back Boss
      Stake memory lastStake = pack[alpha][pack[alpha].length - 1];
      pack[alpha][packIndices[tokenId]] = lastStake; // Shuffle last Boss to current position
      packIndices[lastStake.tokenId] = packIndices[tokenId];
      pack[alpha].pop(); // Remove duplicate
      delete packIndices[tokenId]; // Delete old mapping
    } else {
      pack[alpha][packIndices[tokenId]] = Stake({
        owner: _msgSender(),
        tokenId: uint16(tokenId),
        value: uint80(wagPerAlpha)
      }); // reset stake
    }
    emit BossClaimed(stake.owner, tokenId, owed, unstake);
  }

  /**
   * emergency unstake tokens
   * @param tokenIds the IDs of the tokens to claim earnings from
   */
  function rescue(uint256[] calldata tokenIds) external {
    require(rescueEnabled, "RESCUE DISABLED");
    uint256 tokenId;
    Stake memory stake;
    Stake memory lastStake;
    uint256 alpha;
    for (uint i = 0; i < tokenIds.length; i++) {
      tokenId = tokenIds[i];
      if (isEmployee(tokenId)) {
        stake = barn[tokenId];
        require(stake.owner == _msgSender(), "SWIPER, NO SWIPING");
        boss.safeTransferFrom(address(this), _msgSender(), tokenId, ""); // send back Programmer
        delete barn[tokenId];
        totalProgrammerStaked -= 1;
        emit ProgrammerClaimed(stake.owner, tokenId, 0, true);
      } else {
        alpha = _alphaForBoss(tokenId);
        stake = pack[alpha][packIndices[tokenId]];
        require(stake.owner == _msgSender(), "SWIPER, NO SWIPING");
        totalAlphaStaked -= alpha; // Remove Alpha from total staked
        boss.safeTransferFrom(address(this), _msgSender(), tokenId, ""); // Send back Boss
        lastStake = pack[alpha][pack[alpha].length - 1];
        pack[alpha][packIndices[tokenId]] = lastStake; // Shuffle last Boss to current position
        packIndices[lastStake.tokenId] = packIndices[tokenId];
        pack[alpha].pop(); // Remove duplicate
        delete packIndices[tokenId]; // Delete old mapping
        emit BossClaimed(stake.owner, tokenId, 0, true);
      }
    }
  }

  /** ACCOUNTING */

  /** 
   * add $WAG to claimable pot for the Pack
   * @param amount $WAG to add to the pot
   */
  function _payBossTax(uint256 amount) internal {
    if (totalAlphaStaked == 0) { // if there's no staked wolves
      unaccountedRewards += amount; // keep track of $WAG due to wolves
      return;
    }
    // makes sure to include any unaccounted $WAG 
    wagPerAlpha += (amount + unaccountedRewards) / totalAlphaStaked;
    unaccountedRewards = 0;
  }

  /**
   * tracks $WAG earnings to ensure it stops once 2.4 billion is eclipsed
   */
  modifier _updateEarnings() {
    for(uint256 t = block.timestamp; t - LAST_DAMPING_TIME >= DAMPING_PERIOD; LAST_DAMPING_TIME = LAST_DAMPING_TIME + DAMPING_PERIOD) {
        DAILY_WAG_RATE = DAILY_WAG_RATE * 4 / 5;
    }
    if (totalWagEarned < MAXIMUM_GLOBAL_WAG) {
      totalWagEarned += 
        (block.timestamp - lastClaimTimestamp)
        * totalProgrammerStaked
        * DAILY_WAG_RATE / 1 days; 
      lastClaimTimestamp = block.timestamp;
    }
    _;
  }

  /** ADMIN */

  /**
   * allows owner to enable "rescue mode"
   * simplifies accounting, prioritizes tokens out in emergency
   */
  function setRescueEnabled(bool _enabled) external onlyOwner {
    rescueEnabled = _enabled;
  }

  /**
   * enables owner to pause / unpause minting
   */
  function setPaused(bool _paused) external onlyOwner {
    if (_paused) _pause();
    else _unpause();
  }

  /** READ ONLY */
  /**
   * checks if a token is a Stake
   * @param tokenId the ID of the token to check
   * @return stake  - whether or not a token is stake
   */
  function isStake(uint256 tokenId) public view returns (bool stake) {
     return boss.ownerOf(tokenId) == address(this);
  }

  /**
   * checks if a token is a Programmer
   * @param tokenId the ID of the token to check
   * @return employee - whether or not a token is a Programmer
   */
  function isEmployee(uint256 tokenId) public view returns (bool employee) {
    (employee, , , , , , , , , ) = boss.tokenTraits(tokenId);
  }

  /**
   * gets the alpha score for a Boss
   * @param tokenId the ID of the Boss to get the alpha score for
   * @return the alpha score of the Boss (5-8)
   */
  function _alphaForBoss(uint256 tokenId) internal view returns (uint8) {
    ( , , , , , , , , , uint8 alphaIndex) = boss.tokenTraits(tokenId);
    return MAX_ALPHA - alphaIndex; // alpha index is 0-3
  }

  /**
   * chooses a random Boss thief when a newly minted token is stolen
   * @param seed a random value to choose a Boss from
   * @return the owner of the randomly selected Boss thief
   */
  function randomBossOwner(uint256 seed) external view returns (address) {
    if (totalAlphaStaked == 0) return address(0x0);
    uint256 bucket = (seed & 0xFFFFFFFF) % totalAlphaStaked; // choose a value from 0 to total alpha staked
    uint256 cumulative;
    seed >>= 32;
    // loop through each bucket of Wolves with the same alpha score
    for (uint i = MAX_ALPHA - 3; i <= MAX_ALPHA; i++) {
      cumulative += pack[i].length * i;
      // if the value is not inside of that bucket, keep going
      if (bucket >= cumulative) continue;
      // get the address of a random Boss with that alpha score
      return pack[i][seed % pack[i].length].owner;
    }
    return address(0x0);
  }

  /**
   * generates a pseudorandom number
   * @param seed a value ensure different outcomes for different sources in the same block
   * @return a pseudorandom value
   */
  function random(uint256 seed) internal view returns (uint256) {
    return uint256(keccak256(abi.encodePacked(
      tx.origin,
      blockhash(block.number - 1),
      block.timestamp,
      seed
    )));
  }

  function onERC721Received(
        address,
        address from,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
      require(from == address(0x0), "Cannot send tokens to Barn directly");
      return IERC721Receiver.onERC721Received.selector;
    }

  
}