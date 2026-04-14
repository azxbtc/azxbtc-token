// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

library SafeERC20Lite {
    function safeTransfer(IERC20 token, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = address(token).call(
            abi.encodeWithSelector(token.transfer.selector, to, amount)
        );
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "TRANSFER_FAILED");
    }

    function safeTransferFrom(IERC20 token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = address(token).call(
            abi.encodeWithSelector(token.transferFrom.selector, from, to, amount)
        );
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "TRANSFER_FROM_FAILED");
    }
}

abstract contract Ownable {
    address public owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    modifier onlyOwner() {
        require(msg.sender == owner, "NOT_OWNER");
        _;
    }

    constructor(address initialOwner) {
        require(initialOwner != address(0), "ZERO_OWNER");
        owner = initialOwner;
        emit OwnershipTransferred(address(0), initialOwner);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "ZERO_OWNER");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
}

contract AZXBTCStakingV3 is Ownable {
    using SafeERC20Lite for IERC20;

    struct UserInfo {
        uint256 amount;         // principal staked
        uint256 rewardDebt;     // amount * accRewardPerShare / ACC_PRECISION
        uint256 pendingRewards; // accrued rewards not yet claimed
    }

    IERC20 public immutable stakingToken;

    uint256 public constant ACC_PRECISION = 1e12;

    uint256 public totalStaked;
    uint256 public accRewardPerShare;

    // rewardPool = total rewards reserved inside the contract and not yet paid out
    // includes:
    // - rewards already distributed in accRewardPerShare but not claimed yet
    // - rewards pending in users.pendingRewards
    // - rewards waiting in unallocatedRewards when totalStaked == 0
    uint256 public rewardPool;
    uint256 public unallocatedRewards;

    bool public depositsPaused;

    mapping(address => UserInfo) public users;

    event Staked(address indexed user, uint256 requestedAmount, uint256 receivedAmount);
    event Unstaked(address indexed user, uint256 amount);
    event RewardClaimed(address indexed user, uint256 amount);
    event RewardsSynced(uint256 amount);
    event RewardsFunded(address indexed sender, uint256 requestedAmount, uint256 receivedAmount);
    event DepositsPausedSet(bool paused);
    event ExcessRecovered(address indexed to, uint256 amount);

    constructor(address token_, address owner_) Ownable(owner_) {
        require(token_ != address(0), "ZERO_TOKEN");
        stakingToken = IERC20(token_);
    }

    // =========================
    // Views
    // =========================

    function pendingReward(address account) external view returns (uint256) {
        UserInfo memory user = users[account];

        (
            uint256 previewAccRewardPerShare,
            ,
            
        ) = _previewSync();

        uint256 accumulated = (user.amount * previewAccRewardPerShare) / ACC_PRECISION;
        uint256 pendingFromAcc = 0;
        if (accumulated > user.rewardDebt) {
            pendingFromAcc = accumulated - user.rewardDebt;
        }

        return user.pendingRewards + pendingFromAcc;
    }

    function previewNewRewards() external view returns (uint256) {
        uint256 balance = stakingToken.balanceOf(address(this));
        uint256 reserved = totalStaked + rewardPool;
        if (balance <= reserved) return 0;
        return balance - reserved;
    }

    // =========================
    // Owner functions
    // =========================

    function fundRewards(uint256 amount) external onlyOwner {
        require(amount > 0, "ZERO_AMOUNT");

        _syncRewards();

        uint256 beforeBal = stakingToken.balanceOf(address(this));
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = stakingToken.balanceOf(address(this)) - beforeBal;
        require(received > 0, "NO_REWARDS_RECEIVED");

        _allocateIncomingRewards(received);

        emit RewardsFunded(msg.sender, amount, received);
    }

    function syncRewards() external returns (uint256 synced) {
        synced = _syncRewards();
    }

    function setDepositsPaused(bool paused) external onlyOwner {
        depositsPaused = paused;
        emit DepositsPausedSet(paused);
    }

    function recoverExcessTokens(address to, uint256 amount) external onlyOwner {
        require(to != address(0), "ZERO_TO");

        _syncRewards();

        uint256 balance = stakingToken.balanceOf(address(this));
        uint256 reserved = totalStaked + rewardPool;
        require(balance > reserved, "NO_EXCESS");

        uint256 excess = balance - reserved;
        require(amount <= excess, "AMOUNT_EXCEEDS_EXCESS");

        stakingToken.safeTransfer(to, amount);
        emit ExcessRecovered(to, amount);
    }

    // =========================
    // User functions
    // =========================

    function stake(uint256 amount) external {
        require(!depositsPaused, "DEPOSITS_PAUSED");
        require(amount > 0, "ZERO_AMOUNT");

        _syncRewards();

        UserInfo storage user = users[msg.sender];
        _accrueUser(user);

        uint256 beforeBal = stakingToken.balanceOf(address(this));
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = stakingToken.balanceOf(address(this)) - beforeBal;
        require(received > 0, "NO_TOKENS_RECEIVED");

        user.amount += received;
        totalStaked += received;

        // If rewards arrived while there were no stakers,
        // distribute them once staking resumes.
        if (unallocatedRewards > 0 && totalStaked > 0) {
            accRewardPerShare += (unallocatedRewards * ACC_PRECISION) / totalStaked;
            unallocatedRewards = 0;
        }

        user.rewardDebt = (user.amount * accRewardPerShare) / ACC_PRECISION;

        emit Staked(msg.sender, amount, received);
    }

    function claim() public {
        _syncRewards();

        UserInfo storage user = users[msg.sender];
        _accrueUser(user);

        uint256 reward = user.pendingRewards;
        require(reward > 0, "NO_REWARD");
        require(rewardPool >= reward, "INSUFFICIENT_REWARD_POOL");

        user.pendingRewards = 0;
        rewardPool -= reward;
        user.rewardDebt = (user.amount * accRewardPerShare) / ACC_PRECISION;

        stakingToken.safeTransfer(msg.sender, reward);

        emit RewardClaimed(msg.sender, reward);
    }

    function unstake(uint256 amount) external {
        require(amount > 0, "ZERO_AMOUNT");

        _syncRewards();

        UserInfo storage user = users[msg.sender];
        require(user.amount >= amount, "INSUFFICIENT_STAKE");

        _accrueUser(user);

        user.amount -= amount;
        totalStaked -= amount;
        user.rewardDebt = (user.amount * accRewardPerShare) / ACC_PRECISION;

        stakingToken.safeTransfer(msg.sender, amount);

        emit Unstaked(msg.sender, amount);
    }

    function exit() external {
        _syncRewards();

        UserInfo storage user = users[msg.sender];
        _accrueUser(user);

        uint256 staked = user.amount;
        uint256 reward = user.pendingRewards;

        if (staked > 0) {
            user.amount = 0;
            totalStaked -= staked;
        }

        if (reward > 0) {
            require(rewardPool >= reward, "INSUFFICIENT_REWARD_POOL");
            user.pendingRewards = 0;
            rewardPool -= reward;
        }

        user.rewardDebt = 0;

        if (staked > 0) {
            stakingToken.safeTransfer(msg.sender, staked);
            emit Unstaked(msg.sender, staked);
        }

        if (reward > 0) {
            stakingToken.safeTransfer(msg.sender, reward);
            emit RewardClaimed(msg.sender, reward);
        }
    }

    // =========================
    // Internal logic
    // =========================

    function _accrueUser(UserInfo storage user) internal {
        if (user.amount == 0) {
            user.rewardDebt = 0;
            return;
        }

        uint256 accumulated = (user.amount * accRewardPerShare) / ACC_PRECISION;
        if (accumulated > user.rewardDebt) {
            user.pendingRewards += accumulated - user.rewardDebt;
        }
    }

    function _syncRewards() internal returns (uint256 synced) {
        uint256 balance = stakingToken.balanceOf(address(this));
        uint256 reserved = totalStaked + rewardPool;

        if (balance <= reserved) {
            return 0;
        }

        synced = balance - reserved;
        _allocateIncomingRewards(synced);

        emit RewardsSynced(synced);
    }

    function _allocateIncomingRewards(uint256 amount) internal {
        if (amount == 0) return;

        rewardPool += amount;

        if (totalStaked == 0) {
            unallocatedRewards += amount;
        } else {
            accRewardPerShare += (amount * ACC_PRECISION) / totalStaked;
        }
    }

    function _previewSync()
        internal
        view
        returns (
            uint256 previewAccRewardPerShare,
            uint256 previewRewardPool,
            uint256 previewUnallocatedRewards
        )
    {
        previewAccRewardPerShare = accRewardPerShare;
        previewRewardPool = rewardPool;
        previewUnallocatedRewards = unallocatedRewards;

        uint256 balance = stakingToken.balanceOf(address(this));
        uint256 reserved = totalStaked + rewardPool;

        if (balance > reserved) {
            uint256 newRewards = balance - reserved;
            previewRewardPool += newRewards;

            if (totalStaked == 0) {
                previewUnallocatedRewards += newRewards;
            } else {
                previewAccRewardPerShare += (newRewards * ACC_PRECISION) / totalStaked;
            }
        }
    }
}
