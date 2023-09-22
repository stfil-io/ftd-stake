// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {ERC20VotesUpgradeable} from "../../dependencies/openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import {IERC20} from "../../dependencies/openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../../dependencies/openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IStakedFTD} from '../../interfaces/IStakedFTD.sol';
import {FilAddress} from '../libraries/utils/FilAddress.sol';
import {DistributionManager} from './DistributionManager.sol';

/**
 * @title StakedFTD
 * @notice StakedToken with FTD token as staked token
 * @author STFIL
 **/
contract StakedFTD is IStakedFTD, ERC20VotesUpgradeable, DistributionManager {
  using FilAddress for address;
  using SafeERC20 for IERC20;

  IERC20 public STAKED_TOKEN;
  IERC20 public REWARD_TOKEN;
  uint256 public COOLDOWN_SECONDS;

  /// @notice Seconds available to redeem once the cooldown period is fullfilled
  uint256 public UNSTAKE_WINDOW;

  /// @notice Address to pull from the rewards, needs to have approved this contract
  address public REWARDS_VAULT;

  mapping(address => uint256) public stakerRewardsToClaim;
  mapping(address => uint256) public stakersCooldowns;

  event Staked(address indexed from, address indexed onBehalfOf, uint256 amount);
  event Redeem(address indexed from, address indexed to, uint256 amount);

  event RewardsAccrued(address user, uint256 amount);
  event RewardsClaimed(address indexed from, address indexed to, uint256 amount);

  event Cooldown(address indexed user);

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  /**
   * @dev Initializes the StakedFTD
   */
  function initialize(
    IERC20 stakedToken, 
    IERC20 rewardToken,  
    uint256 cooldownSeconds,
    uint256 unstakeWindow, 
    address rewardsVault,
    address emissionManager
  ) external initializer {
    STAKED_TOKEN = stakedToken;
    REWARD_TOKEN = rewardToken;
    COOLDOWN_SECONDS = cooldownSeconds;
    UNSTAKE_WINDOW = unstakeWindow;
    REWARDS_VAULT = rewardsVault;

    __ERC20_init("Staked FTD","stkFTD");
    __ERC20Permit_init("Staked FTD");
    __DistributionManager_init(emissionManager);
  }

  function stake(address onBehalfOf, uint256 amount) external {
    require(amount != 0, 'INVALID_ZERO_AMOUNT');
    uint256 balanceOfUser = balanceOf(onBehalfOf);

    uint256 accruedRewards = _updateUserAssetInternal(onBehalfOf, address(this), balanceOfUser, totalSupply());
    if (accruedRewards != 0) {
      emit RewardsAccrued(onBehalfOf, accruedRewards);
      stakerRewardsToClaim[onBehalfOf] = stakerRewardsToClaim[onBehalfOf] + accruedRewards;
    }

    stakersCooldowns[onBehalfOf] = getNextCooldownTimestamp(0, amount, onBehalfOf, balanceOfUser);

    _mint(onBehalfOf, amount);
    IERC20(STAKED_TOKEN).safeTransferFrom(msg.sender, address(this), amount);

    emit Staked(msg.sender, onBehalfOf, amount);
  }

  /**
   * @dev Calculates the how is gonna be a new cooldown timestamp depending on the sender/receiver situation
   *  - If the timestamp of the sender is "better" or the timestamp of the recipient is 0, we take the one of the recipient
   *  - Weighted average of from/to cooldown timestamps if:
   *    # The sender doesn't have the cooldown activated (timestamp 0).
   *    # The sender timestamp is expired
   *    # The sender has a "worse" timestamp
   *  - If the receiver's cooldown timestamp expired (too old), the next is 0
   * @param fromCooldownTimestamp Cooldown timestamp of the sender
   * @param amountToReceive Amount
   * @param toAddress Address of the recipient
   * @param toBalance Current balance of the receiver
   * @return The new cooldown timestamp
   **/
  function getNextCooldownTimestamp(
    uint256 fromCooldownTimestamp,
    uint256 amountToReceive,
    address toAddress,
    uint256 toBalance
  ) public view returns (uint256) {
    uint256 toCooldownTimestamp = stakersCooldowns[toAddress];
    if (toCooldownTimestamp == 0) {
      return 0;
    }

    uint256 minimalValidCooldownTimestamp = block.timestamp - COOLDOWN_SECONDS - UNSTAKE_WINDOW;

    if (minimalValidCooldownTimestamp > toCooldownTimestamp) {
      toCooldownTimestamp = 0;
    } else {
      fromCooldownTimestamp = (minimalValidCooldownTimestamp > fromCooldownTimestamp) ? block.timestamp : fromCooldownTimestamp;

      if (fromCooldownTimestamp < toCooldownTimestamp) {
        return toCooldownTimestamp;
      } else {
        toCooldownTimestamp = (amountToReceive * fromCooldownTimestamp + toBalance * toCooldownTimestamp) / (amountToReceive + toBalance);
      }
    }
    return toCooldownTimestamp;
  }

  /**
   * @dev Redeems staked tokens, and stop earning rewards
   * @param to Address to redeem to
   * @param amount Amount to redeem
   **/
  function redeem(address to, uint256 amount) external {
    require(amount != 0, 'INVALID_ZERO_AMOUNT');
    //solium-disable-next-line
    uint256 cooldownStartTimestamp = stakersCooldowns[msg.sender];
    require(
      block.timestamp > cooldownStartTimestamp + COOLDOWN_SECONDS,
      'INSUFFICIENT_COOLDOWN'
    );
    require(
      block.timestamp - (cooldownStartTimestamp + COOLDOWN_SECONDS) <= UNSTAKE_WINDOW,
      'UNSTAKE_WINDOW_FINISHED'
    );
    uint256 balanceOfMessageSender = balanceOf(msg.sender);

    uint256 amountToRedeem = (amount > balanceOfMessageSender) ? balanceOfMessageSender : amount;

    _updateCurrentUnclaimedRewards(msg.sender, balanceOfMessageSender, true);

    _burn(msg.sender, amountToRedeem);

    if (balanceOfMessageSender - amountToRedeem == 0) {
      stakersCooldowns[msg.sender] = 0;
    }

    IERC20(STAKED_TOKEN).safeTransfer(to, amountToRedeem);

    emit Redeem(msg.sender, to, amountToRedeem);
  }


  /**
   * @dev Activates the cooldown period to unstake
   * - It can't be called if the user is not staking
   **/
  function cooldown() external {
    require(balanceOf(msg.sender) != 0, 'INVALID_BALANCE_ON_COOLDOWN');
    //solium-disable-next-line
    stakersCooldowns[msg.sender] = block.timestamp;

    emit Cooldown(msg.sender);
  }

  /**
   * @dev Claims an `amount` of `REWARD_TOKEN` to the address `to`
   * @param to Address to stake for
   * @param amount Amount to stake
   **/
  function claimRewards(address to, uint256 amount) external {
    uint256 newTotalRewards = _updateCurrentUnclaimedRewards(msg.sender, balanceOf(msg.sender), false);
    uint256 amountToClaim = (amount == type(uint256).max) ? newTotalRewards : amount;

    require(amountToClaim <= newTotalRewards, 'INVALID_AMOUNT');
    stakerRewardsToClaim[msg.sender] = newTotalRewards - amountToClaim;

    REWARD_TOKEN.safeTransferFrom(REWARDS_VAULT, to, amountToClaim);

    emit RewardsClaimed(msg.sender, to, amountToClaim);
  }

   /**
   * @dev Internal ERC20 _transfer of the tokenized staked tokens
   * @param from Address to transfer from
   * @param to Address to transfer to
   * @param amount Amount to transfer
   **/
  function _transfer(
    address from,
    address to,
    uint256 amount
  ) internal override {
    uint256 balanceOfFrom = balanceOf(from);
    // Sender
    _updateCurrentUnclaimedRewards(from, balanceOfFrom, true);

    // Recipient
    if (from != to) {
      uint256 balanceOfTo = balanceOf(to);
      _updateCurrentUnclaimedRewards(to, balanceOfTo, true);

      uint256 previousSenderCooldown = stakersCooldowns[from];
      stakersCooldowns[to] = getNextCooldownTimestamp(
        previousSenderCooldown,
        amount,
        to,
        balanceOfTo
      );
      // if cooldown was set and whole balance of sender was transferred - clear cooldown
      if (balanceOfFrom == amount && previousSenderCooldown != 0) {
        stakersCooldowns[from] = 0;
      }
    }

    super._transfer(from, to, amount);
  }

  /**
   * @dev Updates the user state related with his accrued rewards
   * @param user Address of the user
   * @param userBalance The current balance of the user
   * @param updateStorage Boolean flag used to update or not the stakerRewardsToClaim of the user
   * @return The unclaimed rewards that were added to the total accrued
   **/
  function _updateCurrentUnclaimedRewards(
    address user,
    uint256 userBalance,
    bool updateStorage
  ) internal returns (uint256) {
    uint256 accruedRewards = _updateUserAssetInternal(user, address(this), userBalance, totalSupply());
    uint256 unclaimedRewards = stakerRewardsToClaim[user] + accruedRewards;

    if (accruedRewards != 0) {
      if (updateStorage) {
        stakerRewardsToClaim[user] = unclaimedRewards;
      }
      emit RewardsAccrued(user, accruedRewards);
    }

    return unclaimedRewards;
  }
}