// SPDX-License-Identifier: MIT
pragma solidity 0.8.12;

interface IOwnable {
    function manager() external view returns (address);

    function renounceManagement() external;

    function pushManagement(address newOwner_) external;

    function pullManagement() external;
}

contract Ownable is IOwnable {
    address internal _owner;
    address internal _newOwner;

    event OwnershipPushed(
        address indexed previousOwner,
        address indexed newOwner
    );
    event OwnershipPulled(
        address indexed previousOwner,
        address indexed newOwner
    );

    constructor() {
        _owner = msg.sender;
        emit OwnershipPushed(address(0), _owner);
    }

    function manager() public view override returns (address) {
        return _owner;
    }

    modifier onlyManager() {
        require(_owner == msg.sender, "Ownable: caller is not the owner");
        _;
    }

    function renounceManagement() public virtual override onlyManager {
        emit OwnershipPushed(_owner, address(0));
        _owner = address(0);
    }

    function pushManagement(
        address newOwner_
    ) public virtual override onlyManager {
        require(
            newOwner_ != address(0),
            "Ownable: new owner is the zero address"
        );
        emit OwnershipPushed(_owner, newOwner_);
        _newOwner = newOwner_;
    }

    function pullManagement() public virtual override {
        require(msg.sender == _newOwner, "Ownable: must be new owner to pull");
        emit OwnershipPulled(_owner, _newOwner);
        _owner = _newOwner;
    }
}

library Math {
    function max(uint a, uint b) internal pure returns (uint) {
        return a >= b ? a : b;
    }

    function min(uint a, uint b) internal pure returns (uint) {
        return a < b ? a : b;
    }

    function sqrt(uint y) internal pure returns (uint z) {
        if (y > 3) {
            z = y;
            uint x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }

    function cbrt(uint256 n) internal pure returns (uint256) {
        unchecked {
            uint256 x = 0;
            for (uint256 y = 1 << 255; y > 0; y >>= 3) {
                x <<= 1;
                uint256 z = 3 * x * (x + 1) + 1;
                if (n / y >= z) {
                    n -= y * z;
                    x += 1;
                }
            }
            return x;
        }
    }
}

library SafeMath {
    /**
     * @dev Returns the addition of two unsigned integers, with an overflow flag.
     *
     * _Available since v3.4._
     */
    function tryAdd(
        uint256 a,
        uint256 b
    ) internal pure returns (bool, uint256) {
        uint256 c = a + b;
        if (c < a) return (false, 0);
        return (true, c);
    }

    /**
     * @dev Returns the substraction of two unsigned integers, with an overflow flag.
     *
     * _Available since v3.4._
     */
    function trySub(
        uint256 a,
        uint256 b
    ) internal pure returns (bool, uint256) {
        if (b > a) return (false, 0);
        return (true, a - b);
    }

    /**
     * @dev Returns the multiplication of two unsigned integers, with an overflow flag.
     *
     * _Available since v3.4._
     */
    function tryMul(
        uint256 a,
        uint256 b
    ) internal pure returns (bool, uint256) {
        // Gas optimization: this is cheaper than requiring 'a' not being zero, but the
        // benefit is lost if 'b' is also tested.
        // See: https://github.com/OpenZeppelin/openzeppelin-contracts/pull/522
        if (a == 0) return (true, 0);
        uint256 c = a * b;
        if (c / a != b) return (false, 0);
        return (true, c);
    }

    /**
     * @dev Returns the division of two unsigned integers, with a division by zero flag.
     *
     * _Available since v3.4._
     */
    function tryDiv(
        uint256 a,
        uint256 b
    ) internal pure returns (bool, uint256) {
        if (b == 0) return (false, 0);
        return (true, a / b);
    }

    /**
     * @dev Returns the remainder of dividing two unsigned integers, with a division by zero flag.
     *
     * _Available since v3.4._
     */
    function tryMod(
        uint256 a,
        uint256 b
    ) internal pure returns (bool, uint256) {
        if (b == 0) return (false, 0);
        return (true, a % b);
    }

    /**
     * @dev Returns the addition of two unsigned integers, reverting on
     * overflow.
     *
     * Counterpart to Solidity's `+` operator.
     *
     * Requirements:
     *
     * - Addition cannot overflow.
     */
    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c = a + b;
        require(c >= a, "SafeMath: addition overflow");
        return c;
    }

    /**
     * @dev Returns the subtraction of two unsigned integers, reverting on
     * overflow (when the result is negative).
     *
     * Counterpart to Solidity's `-` operator.
     *
     * Requirements:
     *
     * - Subtraction cannot overflow.
     */
    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b <= a, "SafeMath: subtraction overflow");
        return a - b;
    }

    /**
     * @dev Returns the multiplication of two unsigned integers, reverting on
     * overflow.
     *
     * Counterpart to Solidity's `*` operator.
     *
     * Requirements:
     *
     * - Multiplication cannot overflow.
     */
    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0) return 0;
        uint256 c = a * b;
        require(c / a == b, "SafeMath: multiplication overflow");
        return c;
    }

    /**
     * @dev Returns the integer division of two unsigned integers, reverting on
     * division by zero. The result is rounded towards zero.
     *
     * Counterpart to Solidity's `/` operator. Note: this function uses a
     * `revert` opcode (which leaves remaining gas untouched) while Solidity
     * uses an invalid opcode to revert (consuming all remaining gas).
     *
     * Requirements:
     *
     * - The divisor cannot be zero.
     */
    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b > 0, "SafeMath: division by zero");
        return a / b;
    }

    /**
     * @dev Returns the remainder of dividing two unsigned integers. (unsigned integer modulo),
     * reverting when dividing by zero.
     *
     * Counterpart to Solidity's `%` operator. This function uses a `revert`
     * opcode (which leaves remaining gas untouched) while Solidity uses an
     * invalid opcode to revert (consuming all remaining gas).
     *
     * Requirements:
     *
     * - The divisor cannot be zero.
     */
    function mod(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b > 0, "SafeMath: modulo by zero");
        return a % b;
    }

    /**
     * @dev Returns the subtraction of two unsigned integers, reverting with custom message on
     * overflow (when the result is negative).
     *
     * CAUTION: This function is deprecated because it requires allocating memory for the error
     * message unnecessarily. For custom revert reasons use {trySub}.
     *
     * Counterpart to Solidity's `-` operator.
     *
     * Requirements:
     *
     * - Subtraction cannot overflow.
     */
    function sub(
        uint256 a,
        uint256 b,
        string memory errorMessage
    ) internal pure returns (uint256) {
        require(b <= a, errorMessage);
        return a - b;
    }

    /**
     * @dev Returns the integer division of two unsigned integers, reverting with custom message on
     * division by zero. The result is rounded towards zero.
     *
     * CAUTION: This function is deprecated because it requires allocating memory for the error
     * message unnecessarily. For custom revert reasons use {tryDiv}.
     *
     * Counterpart to Solidity's `/` operator. Note: this function uses a
     * `revert` opcode (which leaves remaining gas untouched) while Solidity
     * uses an invalid opcode to revert (consuming all remaining gas).
     *
     * Requirements:
     *
     * - The divisor cannot be zero.
     */
    function div(
        uint256 a,
        uint256 b,
        string memory errorMessage
    ) internal pure returns (uint256) {
        require(b > 0, errorMessage);
        return a / b;
    }

    /**
     * @dev Returns the remainder of dividing two unsigned integers. (unsigned integer modulo),
     * reverting with custom message when dividing by zero.
     *
     * CAUTION: This function is deprecated because it requires allocating memory for the error
     * message unnecessarily. For custom revert reasons use {tryMod}.
     *
     * Counterpart to Solidity's `%` operator. This function uses a `revert`
     * opcode (which leaves remaining gas untouched) while Solidity uses an
     * invalid opcode to revert (consuming all remaining gas).
     *
     * Requirements:
     *
     * - The divisor cannot be zero.
     */
    function mod(
        uint256 a,
        uint256 b,
        string memory errorMessage
    ) internal pure returns (uint256) {
        require(b > 0, errorMessage);
        return a % b;
    }
}

interface IERC20 {
    function totalSupply() external view returns (uint256);

    function transfer(address recipient, uint amount) external returns (bool);

    function decimals() external view returns (uint8);

    function symbol() external view returns (string memory);

    function balanceOf(address) external view returns (uint);

    function transferFrom(
        address sender,
        address recipient,
        uint amount
    ) external returns (bool);

    function allowance(
        address owner,
        address spender
    ) external view returns (uint);

    function approve(address spender, uint value) external returns (bool);

    event Transfer(address indexed from, address indexed to, uint value);
    event Approval(address indexed owner, address indexed spender, uint value);
}

interface IVoter {
    function _ve() external view returns (address);
}

interface IVotingEscrow {
    function team() external returns (address);

    function ownerOf(uint) external view returns (address);

    function isApprovedOrOwner(address, uint) external view returns (bool);
}

// Bribes pay out rewards for a given pool based on the votes that were received from the user (goes hand in hand with Voter.vote())
contract VotingReward {
    address public immutable voter; // only voter can modify balances (since it only happens on vote())
    address public immutable _ve;

    uint internal constant DURATION = 7 days; // rewards are released over 7 days
    uint public constant PRECISION = 10 ** 18;

    // default snx staking contract implementation
    mapping(address => uint) public rewardRate;
    mapping(address => uint) public periodFinish;
    mapping(address => uint) public lastUpdateTime;
    mapping(address => uint) public rewardPerTokenStored;

    mapping(address => mapping(uint => uint)) public lastEarn;
    mapping(address => mapping(uint => uint)) public userRewardPerTokenStored;

    address[] public rewards;
    mapping(address => bool) public isReward;
    mapping(address => bool) public isBlackReward;

    uint public totalSupply;
    mapping(uint => uint) public balanceOf;

    /// @notice A checkpoint for marking balance
    struct Checkpoint {
        uint timestamp;
        uint balanceOf;
    }

    /// @notice A checkpoint for marking reward rate
    struct RewardPerTokenCheckpoint {
        uint timestamp;
        uint rewardPerToken;
    }

    /// @notice A checkpoint for marking supply
    struct SupplyCheckpoint {
        uint timestamp;
        uint supply;
    }

    /// @notice A record of balance checkpoints for each account, by index
    mapping(uint => mapping(uint => Checkpoint)) public checkpoints;
    /// @notice The number of checkpoints for each account
    mapping(uint => uint) public numCheckpoints;
    /// @notice A record of balance checkpoints for each token, by index
    mapping(uint => SupplyCheckpoint) public supplyCheckpoints;
    /// @notice The number of checkpoints
    uint public supplyNumCheckpoints;
    /// @notice A record of balance checkpoints for each token, by index
    mapping(address => mapping(uint => RewardPerTokenCheckpoint))
        public rewardPerTokenCheckpoints;
    /// @notice The number of checkpoints for each token
    mapping(address => uint) public rewardPerTokenNumCheckpoints;

    event NotifyReward(
        address indexed from,
        address indexed reward,
        uint amount
    );

    event ClaimRewards(
        address indexed from,
        address indexed reward,
        uint amount
    );

    constructor(address _voter, address[] memory _allowedRewardTokens) {
        voter = _voter;
        _ve = IVoter(_voter)._ve();

        for (uint i; i < _allowedRewardTokens.length; i++) {
            if (_allowedRewardTokens[i] != address(0)) {
                isReward[_allowedRewardTokens[i]] = true;
                rewards.push(_allowedRewardTokens[i]);
            }
        }
    }

    // simple re-entrancy check
    uint internal _unlocked = 1;
    modifier lock() {
        require(_unlocked == 1);
        _unlocked = 2;
        _;
        _unlocked = 1;
    }

    /**
     * @notice Determine the prior balance for an account as of a block number
     * @dev Block number must be a finalized block or else this function will revert to prevent misinformation.
     * @param tokenId The token of the NFT to check
     * @param timestamp The timestamp to get the balance at
     * @return The balance the account had as of the given block
     */
    function getPriorBalanceIndex(
        uint tokenId,
        uint timestamp
    ) public view returns (uint) {
        uint nCheckpoints = numCheckpoints[tokenId];
        if (nCheckpoints == 0) {
            return 0;
        }

        // First check most recent balance
        if (checkpoints[tokenId][nCheckpoints - 1].timestamp <= timestamp) {
            return (nCheckpoints - 1);
        }

        // Next check implicit zero balance
        if (checkpoints[tokenId][0].timestamp > timestamp) {
            return 0;
        }

        uint lower = 0;
        uint upper = nCheckpoints - 1;
        while (upper > lower) {
            uint center = upper - (upper - lower) / 2; // ceil, avoiding overflow
            Checkpoint memory cp = checkpoints[tokenId][center];
            if (cp.timestamp == timestamp) {
                return center;
            } else if (cp.timestamp < timestamp) {
                lower = center;
            } else {
                upper = center - 1;
            }
        }
        return lower;
    }

    function getPriorSupplyIndex(uint timestamp) public view returns (uint) {
        uint nCheckpoints = supplyNumCheckpoints;
        if (nCheckpoints == 0) {
            return 0;
        }

        // First check most recent balance
        if (supplyCheckpoints[nCheckpoints - 1].timestamp <= timestamp) {
            return (nCheckpoints - 1);
        }

        // Next check implicit zero balance
        if (supplyCheckpoints[0].timestamp > timestamp) {
            return 0;
        }

        uint lower = 0;
        uint upper = nCheckpoints - 1;
        while (upper > lower) {
            uint center = upper - (upper - lower) / 2; // ceil, avoiding overflow
            SupplyCheckpoint memory cp = supplyCheckpoints[center];
            if (cp.timestamp == timestamp) {
                return center;
            } else if (cp.timestamp < timestamp) {
                lower = center;
            } else {
                upper = center - 1;
            }
        }
        return lower;
    }

    function getPriorRewardPerToken(
        address token,
        uint timestamp
    ) public view returns (uint, uint) {
        uint nCheckpoints = rewardPerTokenNumCheckpoints[token];
        if (nCheckpoints == 0) {
            return (0, 0);
        }

        // First check most recent balance
        if (
            rewardPerTokenCheckpoints[token][nCheckpoints - 1].timestamp <=
            timestamp
        ) {
            return (
                rewardPerTokenCheckpoints[token][nCheckpoints - 1]
                    .rewardPerToken,
                rewardPerTokenCheckpoints[token][nCheckpoints - 1].timestamp
            );
        }

        // Next check implicit zero balance
        if (rewardPerTokenCheckpoints[token][0].timestamp > timestamp) {
            return (0, 0);
        }

        uint lower = 0;
        uint upper = nCheckpoints - 1;
        while (upper > lower) {
            uint center = upper - (upper - lower) / 2; // ceil, avoiding overflow
            RewardPerTokenCheckpoint memory cp = rewardPerTokenCheckpoints[
                token
            ][center];
            if (cp.timestamp == timestamp) {
                return (cp.rewardPerToken, cp.timestamp);
            } else if (cp.timestamp < timestamp) {
                lower = center;
            } else {
                upper = center - 1;
            }
        }
        return (
            rewardPerTokenCheckpoints[token][lower].rewardPerToken,
            rewardPerTokenCheckpoints[token][lower].timestamp
        );
    }

    function _writeCheckpoint(uint tokenId, uint balance) internal {
        uint _timestamp = block.timestamp;
        uint _nCheckPoints = numCheckpoints[tokenId];

        if (
            _nCheckPoints > 0 &&
            checkpoints[tokenId][_nCheckPoints - 1].timestamp == _timestamp
        ) {
            checkpoints[tokenId][_nCheckPoints - 1].balanceOf = balance;
        } else {
            checkpoints[tokenId][_nCheckPoints] = Checkpoint(
                _timestamp,
                balance
            );
            numCheckpoints[tokenId] = _nCheckPoints + 1;
        }
    }

    function _writeRewardPerTokenCheckpoint(
        address token,
        uint reward,
        uint timestamp
    ) internal {
        uint _nCheckPoints = rewardPerTokenNumCheckpoints[token];

        if (
            _nCheckPoints > 0 &&
            rewardPerTokenCheckpoints[token][_nCheckPoints - 1].timestamp ==
            timestamp
        ) {
            rewardPerTokenCheckpoints[token][_nCheckPoints - 1]
                .rewardPerToken = reward;
        } else {
            rewardPerTokenCheckpoints[token][
                _nCheckPoints
            ] = RewardPerTokenCheckpoint(timestamp, reward);
            rewardPerTokenNumCheckpoints[token] = _nCheckPoints + 1;
        }
    }

    function _writeSupplyCheckpoint() internal {
        uint _nCheckPoints = supplyNumCheckpoints;
        uint _timestamp = block.timestamp;

        if (
            _nCheckPoints > 0 &&
            supplyCheckpoints[_nCheckPoints - 1].timestamp == _timestamp
        ) {
            supplyCheckpoints[_nCheckPoints - 1].supply = totalSupply;
        } else {
            supplyCheckpoints[_nCheckPoints] = SupplyCheckpoint(
                _timestamp,
                totalSupply
            );
            supplyNumCheckpoints = _nCheckPoints + 1;
        }
    }

    function getRewardList() external view returns (address[] memory) {
        return rewards;
    }

    // returns the last time the reward was modified or periodFinish if the reward has ended
    function lastTimeRewardApplicable(
        address token
    ) public view returns (uint) {
        return Math.min(block.timestamp, periodFinish[token]);
    }

    // allows a user to claim rewards for a given token
    function getReward(
        uint[] memory tokenIds,
        address[] memory tokens
    ) external lock {
        for (uint j = 0; j < tokenIds.length; j++) {
            uint tokenId = tokenIds[j];
            require(
                IVotingEscrow(_ve).isApprovedOrOwner(msg.sender, tokenId),
                "not owner"
            );
            for (uint i = 0; i < tokens.length; i++) {
                (
                    rewardPerTokenStored[tokens[i]],
                    lastUpdateTime[tokens[i]]
                ) = _updateRewardPerToken(tokens[i], type(uint).max, true);

                uint _reward = earned(tokens[i], tokenId);
                lastEarn[tokens[i]][tokenId] = block.timestamp;
                userRewardPerTokenStored[tokens[i]][
                    tokenId
                ] = rewardPerTokenStored[tokens[i]];
                if (_reward > 0) _safeTransfer(tokens[i], msg.sender, _reward);

                emit ClaimRewards(msg.sender, tokens[i], _reward);
            }
        }
    }

    function getRewardForOwner(
        uint[] memory tokenIds,
        address[] memory tokens
    ) external lock {
        require(msg.sender == voter, "only voter");
        for (uint j = 0; j < tokenIds.length; j++) {
            uint tokenId = tokenIds[j];
            address _owner = IVotingEscrow(_ve).ownerOf(tokenId);
            for (uint i = 0; i < tokens.length; i++) {
                (
                    rewardPerTokenStored[tokens[i]],
                    lastUpdateTime[tokens[i]]
                ) = _updateRewardPerToken(tokens[i], type(uint).max, true);

                uint _reward = earned(tokens[i], tokenId);
                lastEarn[tokens[i]][tokenId] = block.timestamp;
                userRewardPerTokenStored[tokens[i]][
                    tokenId
                ] = rewardPerTokenStored[tokens[i]];
                if (_reward > 0) _safeTransfer(tokens[i], _owner, _reward);

                emit ClaimRewards(_owner, tokens[i], _reward);
            }
        }
    }

    function rewardPerToken(address token) public view returns (uint) {
        if (totalSupply == 0) {
            return rewardPerTokenStored[token];
        }
        return
            rewardPerTokenStored[token] +
            (((lastTimeRewardApplicable(token) -
                Math.min(lastUpdateTime[token], periodFinish[token])) *
                rewardRate[token] *
                PRECISION) / totalSupply);
    }

    function batchRewardPerToken(address token, uint maxRuns) external {
        require(!isBlackReward[token], "token hasBlack");
        (
            rewardPerTokenStored[token],
            lastUpdateTime[token]
        ) = _batchRewardPerToken(token, maxRuns);
    }

    function _batchRewardPerToken(
        address token,
        uint maxRuns
    ) internal returns (uint, uint) {
        uint _startTimestamp = lastUpdateTime[token];
        uint reward = rewardPerTokenStored[token];

        if (supplyNumCheckpoints == 0) {
            return (reward, _startTimestamp);
        }

        if (rewardRate[token] == 0) {
            return (reward, block.timestamp);
        }

        uint _startIndex = getPriorSupplyIndex(_startTimestamp);
        uint _endIndex = Math.min(supplyNumCheckpoints - 1, maxRuns);

        for (uint i = _startIndex; i < _endIndex; i++) {
            SupplyCheckpoint memory sp0 = supplyCheckpoints[i];
            if (sp0.supply > 0) {
                SupplyCheckpoint memory sp1 = supplyCheckpoints[i + 1];
                (uint _reward, uint endTime) = _calcRewardPerToken(
                    token,
                    sp1.timestamp,
                    sp0.timestamp,
                    sp0.supply,
                    _startTimestamp
                );
                reward += _reward;
                _writeRewardPerTokenCheckpoint(token, reward, endTime);
                _startTimestamp = endTime;
            }
        }

        return (reward, _startTimestamp);
    }

    function _calcRewardPerToken(
        address token,
        uint timestamp1,
        uint timestamp0,
        uint supply,
        uint startTimestamp
    ) internal view returns (uint, uint) {
        uint endTime = Math.max(timestamp1, startTimestamp);
        return (
            (((Math.min(endTime, periodFinish[token]) -
                Math.min(
                    Math.max(timestamp0, startTimestamp),
                    periodFinish[token]
                )) *
                rewardRate[token] *
                PRECISION) / supply),
            endTime
        );
    }

    /// @dev Update stored rewardPerToken values without the last one snapshot
    ///      If the contract will get "out of gas" error on users actions this will be helpful
    function batchUpdateRewardPerToken(address token, uint maxRuns) external {
        require(!isBlackReward[token], "token hasBlack");
        (
            rewardPerTokenStored[token],
            lastUpdateTime[token]
        ) = _updateRewardPerToken(token, maxRuns, false);
    }

    function _updateRewardForAllTokens() internal {
        uint length = rewards.length;
        for (uint i; i < length; i++) {
            address token = rewards[i];
            if (!isBlackReward[token]) {
                (
                    rewardPerTokenStored[token],
                    lastUpdateTime[token]
                ) = _updateRewardPerToken(token, type(uint).max, true);
            }
        }
    }

    function _updateRewardPerToken(
        address token,
        uint maxRuns,
        bool actualLast
    ) internal returns (uint, uint) {
        uint _startTimestamp = lastUpdateTime[token];
        uint reward = rewardPerTokenStored[token];

        if (supplyNumCheckpoints == 0) {
            return (reward, _startTimestamp);
        }

        if (rewardRate[token] == 0) {
            return (reward, block.timestamp);
        }

        uint _startIndex = getPriorSupplyIndex(_startTimestamp);
        uint _endIndex = Math.min(supplyNumCheckpoints - 1, maxRuns);

        if (_endIndex > 0) {
            for (uint i = _startIndex; i <= _endIndex - 1; i++) {
                SupplyCheckpoint memory sp0 = supplyCheckpoints[i];
                if (sp0.supply > 0) {
                    SupplyCheckpoint memory sp1 = supplyCheckpoints[i + 1];
                    (uint _reward, uint _endTime) = _calcRewardPerToken(
                        token,
                        sp1.timestamp,
                        sp0.timestamp,
                        sp0.supply,
                        _startTimestamp
                    );
                    reward += _reward;
                    _writeRewardPerTokenCheckpoint(token, reward, _endTime);
                    _startTimestamp = _endTime;
                }
            }
        }

        if (actualLast) {
            SupplyCheckpoint memory sp = supplyCheckpoints[_endIndex];
            if (sp.supply > 0) {
                (uint _reward, ) = _calcRewardPerToken(
                    token,
                    lastTimeRewardApplicable(token),
                    Math.max(sp.timestamp, _startTimestamp),
                    sp.supply,
                    _startTimestamp
                );
                reward += _reward;
                _writeRewardPerTokenCheckpoint(token, reward, block.timestamp);
                _startTimestamp = block.timestamp;
            }
        }

        return (reward, _startTimestamp);
    }

    function earnedByTokenIds(
        address token,
        uint[] memory tokenIdS
    ) public view returns (uint totalEarn) {
        for (uint i = 0; i < tokenIdS.length; i++) {
            totalEarn += earned(token, tokenIdS[i]);
        }
    }

    function earned(address token, uint tokenId) public view returns (uint) {
        if (isBlackReward[token]) {
            return 0;
        }
        uint _startTimestamp = Math.max(
            lastEarn[token][tokenId],
            rewardPerTokenCheckpoints[token][0].timestamp
        );

        if (numCheckpoints[tokenId] == 0) {
            return 0;
        }

        uint _startIndex = getPriorBalanceIndex(tokenId, _startTimestamp);
        uint _endIndex = numCheckpoints[tokenId] - 1;

        uint reward = 0;

        if (_endIndex > 0) {
            for (uint i = _startIndex; i <= _endIndex - 1; i++) {
                Checkpoint memory cp0 = checkpoints[tokenId][i];
                Checkpoint memory cp1 = checkpoints[tokenId][i + 1];
                (uint _rewardPerTokenStored0, ) = getPriorRewardPerToken(
                    token,
                    cp0.timestamp
                );
                (uint _rewardPerTokenStored1, ) = getPriorRewardPerToken(
                    token,
                    cp1.timestamp
                );
                reward +=
                    (cp0.balanceOf *
                        (_rewardPerTokenStored1 - _rewardPerTokenStored0)) /
                    PRECISION;
            }
        }

        Checkpoint memory cp = checkpoints[tokenId][_endIndex];
        (uint _rewardPerTokenStored, ) = getPriorRewardPerToken(
            token,
            cp.timestamp
        );
        reward +=
            (cp.balanceOf *
                (rewardPerToken(token) -
                    Math.max(
                        _rewardPerTokenStored,
                        userRewardPerTokenStored[token][tokenId]
                    ))) /
            PRECISION;

        return reward;
    }

    // This is an external function, but internal notation is used since it can only be called "internally" from Gauges
    function _deposit(uint amount, uint tokenId) external {
        require(msg.sender == voter, "not voter");
        _updateRewardForAllTokens();

        totalSupply += amount;
        balanceOf[tokenId] += amount;

        _writeCheckpoint(tokenId, balanceOf[tokenId]);
        _writeSupplyCheckpoint();
    }

    function _withdraw(uint amount, uint tokenId) external {
        require(msg.sender == voter, "not voter");
        _updateRewardForAllTokens();

        totalSupply -= amount;
        balanceOf[tokenId] -= amount;

        _writeCheckpoint(tokenId, balanceOf[tokenId]);
        _writeSupplyCheckpoint();
    }

    function left(address token) external view returns (uint) {
        if (block.timestamp >= periodFinish[token]) return 0;
        uint _remaining = periodFinish[token] - block.timestamp;
        return _remaining * rewardRate[token];
    }

    // used to notify a gauge/bribe of a given reward, this can create griefing attacks by extending rewards
    function notifyRewardAmount(address token, uint amount) external  {
        require(amount > 0, "amount not zero");
        require(!isBlackReward[token], "token hasBlack");
        require(supplyNumCheckpoints > 0, "supplyNumCheckpoints not zero");
        if (!isReward[token]) {
            require(rewards.length < 4);
            isReward[token] = true;
            rewards.push(token);
        }

        if (rewardRate[token] == 0)
            _writeRewardPerTokenCheckpoint(token, 0, block.timestamp);
        (
            rewardPerTokenStored[token],
            lastUpdateTime[token]
        ) = _updateRewardPerToken(token, type(uint).max, true);

        _safeTransferFrom(token, msg.sender, address(this), amount);
        rewardRate[token] += amount / (DURATION - (block.timestamp % DURATION));
        require(rewardRate[token] > 0);
        periodFinish[token] = getEpochStart(block.timestamp) + DURATION;

        emit NotifyReward(msg.sender, token, amount);
    }

    function setBlackToken(address[] memory tokens, bool _black) external {
        // require(msg.sender == IVotingEscrow(_ve).team(), "only team");
        for (uint i = 0; i < tokens.length; i++) {
            isBlackReward[tokens[i]] = _black;
        }
    }

    function swapOutRewardToken(address oldToken, address newToken) external {
        // require(msg.sender == IVotingEscrow(_ve).team(), "only team");
        require(rewards[rewards.length - 1] == oldToken);
        isReward[oldToken] = false;
        isReward[newToken] = true;
        rewards[rewards.length - 1] = newToken;
    }

    function _safeTransfer(address token, address to, uint256 value) internal {
        require(token.code.length > 0);
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, value)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))));
    }

    function _safeTransferFrom(
        address token,
        address from,
        address to,
        uint256 value
    ) internal {
        require(token.code.length > 0);
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(
                IERC20.transferFrom.selector,
                from,
                to,
                value
            )
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))));
    }

    function getEpochStart(uint timestamp) public pure returns (uint) {
        uint bribeStart = timestamp - (timestamp % (DURATION));
        uint bribeEnd = bribeStart + DURATION;
        return timestamp < bribeEnd ? bribeStart : bribeStart + DURATION;
    }
}

contract VotingRewardFactory is Ownable {
    address public last_voting_reward;
    address public voter;

    function setVoter(address _voter) external onlyManager {
        voter = _voter;
    }

    function createVotingReward(
        address[] memory allowedRewards
    ) external returns (address) {
        require(voter != address(0));
        last_voting_reward = address(new VotingReward(voter, allowedRewards));
        return last_voting_reward;
    }
}
