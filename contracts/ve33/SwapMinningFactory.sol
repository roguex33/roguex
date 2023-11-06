// SPDX-License-Identifier: BUSL-1.1
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
    function distribute(address _gauge) external;
}

contract SwapMinning {
    uint internal _unlocked = 1;
    modifier lock() {
        require(_unlocked == 1);
        _unlocked = 2;
        _;
        _unlocked = 1;
    }

    address public immutable depositer;

    address[] public rewardTokens;

    uint256 internal constant DURATION = 7 days; // rewards are released over 7 days
    uint256 internal constant PRECISION = 10 ** 18;

    mapping(address => mapping(uint256 => uint256)) public periodFinish; //token=>round>tmestamp

    mapping(address => mapping(uint256 => uint256)) public rewardRate; //token=>round>amount

    mapping(address => mapping(uint256 => uint256)) public lastUpdateTime; //token=>round>tmestamp

    mapping(address => mapping(uint256 => uint256)) public rewardPerTokenStored; //token=>round>amount

    mapping(uint256 => uint256) public totalSupply; //round>amount
    mapping(address => bool) public isReward; //token =>bool
    mapping(address => mapping(uint256 => uint256)) public balanceOf; //user=>round=>amount

    mapping(address => mapping(uint256 => mapping(address => uint256)))
        public userRewardPerTokenPaid; //token=>round>user=>amount

    mapping(address => mapping(uint256 => mapping(address => uint256)))
        public rewards; //token =>round =>user =>amount

    event Deposit(address indexed from, address to, uint256 amount);

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

    constructor(address _depositer, address[] memory _allowedRewardTokens) {
        depositer = _depositer;
        for (uint i; i < _allowedRewardTokens.length; i++) {
            if (_allowedRewardTokens[i] != address(0)) {
                isReward[_allowedRewardTokens[i]] = true;
                rewardTokens.push(_allowedRewardTokens[i]);
            }
        }
    }

    function rewardPerToken(
        address token,
        uint round
    ) public view returns (uint256) {
        if (totalSupply[round] == 0) {
            return rewardPerTokenStored[token][round];
        }
        return
            rewardPerTokenStored[token][round] +
            ((lastTimeRewardApplicable(token, round) -
                lastUpdateTime[token][round]) *
                rewardRate[token][round] *
                PRECISION) /
            totalSupply[round];
    }

    function lastTimeRewardApplicable(
        address token,
        uint round
    ) public view returns (uint256) {
        return Math.min(block.timestamp, periodFinish[token][round]);
    }

    function getRewardList() public view returns (address[] memory) {
        return rewardTokens;
    }

    function getReward(address _account, uint round) external lock {
        _updateRewards(_account, round);
        for (uint i = 0; i < rewardTokens.length; i++) {
            address token = rewardTokens[i];
            uint256 reward = rewards[token][round][_account];
            if (reward > 0) {
                rewards[token][round][_account] = 0;
                IERC20(token).transfer(_account, reward);
            }
            emit ClaimRewards(msg.sender, token, reward);
        }
    }

    function earned(
        address token,
        address _account,
        uint round
    ) public view returns (uint256) {
        return
            (balanceOf[_account][round] *
                (rewardPerToken(token, round) -
                    userRewardPerTokenPaid[token][round][_account])) /
            PRECISION +
            rewards[token][round][_account];
    }

    function deposit(uint256 _amount, address _recipient) external lock {
        require(depositer == msg.sender, "not depositer");
        _deposit(_amount, _recipient);
    }

    function _deposit(uint256 _amount, address _recipient) internal {
        uint round = getCurrRound();
        _updateRewards(_recipient, round);
        totalSupply[round] += _amount;
        balanceOf[_recipient][round] += _amount;
        emit Deposit(msg.sender, _recipient, _amount);
    }

    function _updateRewards(address _account, uint round) internal {
        for (uint i = 0; i < rewardTokens.length; i++) {
            address token = rewardTokens[i];
            rewardPerTokenStored[token][round] = rewardPerToken(token, round);
            lastUpdateTime[token][round] = lastTimeRewardApplicable(
                token,
                round
            );
            rewards[token][round][_account] = earned(token, _account, round);
            userRewardPerTokenPaid[token][round][
                _account
            ] = rewardPerTokenStored[token][round];
        }
    }

    function notifyRewardAmount(address token, uint256 _amount) external {
        require(_amount > 0, "amount not zero");
        require(token != address(0), "zero Token");
        if (!isReward[token]) {
            require(rewardTokens.length < 4, "not reward Token");
            isReward[token] = true;
            rewardTokens.push(token);
        }

        address sender = msg.sender;
        uint round = getCurrRound();
        rewardPerTokenStored[token][round] = rewardPerToken(token, round);
        uint256 timestamp = block.timestamp;
        uint256 timeUntilNext = epochNext(timestamp) - timestamp;

        if (timestamp >= periodFinish[token][round]) {
            IERC20(token).transferFrom(sender, address(this), _amount);
            rewardRate[token][round] = _amount / timeUntilNext;
        } else {
            uint256 _remaining = periodFinish[token][round] - timestamp;
            uint256 _leftover = _remaining * rewardRate[token][round];
            IERC20(token).transferFrom(sender, address(this), _amount);
            rewardRate[token][round] = (_amount + _leftover) / timeUntilNext;
        }

        lastUpdateTime[token][round] = timestamp;
        periodFinish[token][round] = timestamp + timeUntilNext;
        emit NotifyReward(msg.sender, token, _amount);
    }

    function getCurrRound() public view returns (uint) {
        return (block.timestamp / DURATION) * DURATION;
    }

    function epochNext(uint256 timestamp) internal pure returns (uint256) {
        unchecked {
            return timestamp - (timestamp % DURATION) + DURATION;
        }
    }
}

contract SwapMinningFactory is Ownable {
    address public last_swapMinning;
    address public voter;

    event SwapMinningCreated(
        address voter,
        address masterChef,
        uint256 timestamp
    );

    function setVoter(address _voter) external onlyManager {
        voter = _voter;
    }

    function createSwapMinning(
        address[] memory allowedRewards
    ) external returns (address) {
        require(voter != address(0));
        last_swapMinning = address(new SwapMinning(voter, allowedRewards));
        emit SwapMinningCreated(voter, last_swapMinning, block.timestamp);
        return last_swapMinning;
    }
}
