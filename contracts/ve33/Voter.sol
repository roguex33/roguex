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

interface IVotingReward {
    function getReward(address _account, uint round) external;

    function deposit(uint256 _amount, address _recipient) external;

    function notifyRewardAmount(address token, uint amount) external;
}

interface IVotingRewardFactory {
    function createVotingReward(address[] memory) external returns (address);
}

interface IMinter {
    function active_period() external view returns (uint);

    function update_period() external returns (uint);
}

interface IVotingEscrow {
    function token() external view returns (address);

    function team() external returns (address);

    function ownerOf(uint) external view returns (address);

    function isApprovedOrOwner(address, uint) external view returns (bool);

    function transferFrom(address, address, uint) external;

    function voting(uint tokenId) external;

    function abstain(uint tokenId) external;

    function balanceOfNFT(uint) external view returns (uint);

    function totalSupply() external view returns (uint);
}

interface IPoolV3 {
    function token0() external view returns (address);

    /// @notice The second of the two tokens of the pool, sorted by address
    /// @return The token contract address
    function token1() external view returns (address);
}

interface ISwapMinning {
    function notifyRewardAmount(address token, uint256 _amount) external;

    function getReward(address _account, uint round) external;

    function deposit(uint256 _amount, address _recipient) external;
}

interface ISwapMinningFactory {
    function createSwapMinning(address[] memory) external returns (address);
}

interface IMasterChefFactory {
    function createMasterChef(
        address _hypervisor,
        address[] memory allowedRewards
    ) external returns (address);
}

interface IMasterChef {
    function notifyRewardAmount(address token, uint256 _amount) external;

    function getReward(address _account) external;
}

contract Voter is Ownable {
    address public immutable _ve; // the ve token that governs these .
    address internal immutable base;

    address public immutable swapRouter;
    address public immutable tradeRouter;
    address public immutable masterChefFactory;
    address public immutable votingRewardFactory;
    address public immutable swapMinningFactory;

    uint internal constant DURATION = 7 days; // rewards are released over 7 days
    address public minter;
    address public hypervisorFactory;
    address[] public pools; // all pools viable for incentives

    mapping(address => uint256) public gaugesDistributionTimestmap; // gauge    => last Distribution Time
    mapping(address => address) public masterChefs; // hypervisor=> gauge
    mapping(address => address) public gauges; // pool => gauge
    mapping(address => address) public poolForGauge; // gauge => pool
    mapping(address => address) public swaps; // pool => swap
    mapping(address => address) public poolForSwap; // swap => pool
    mapping(address => address) public bribes; // gauge => internal bribe (only fees)
    mapping(uint => mapping(address => uint256)) public votes; // nft => pool => votes
    mapping(uint => mapping(uint => bool)) public isVoted; //  nft=> round=>isVoted
    mapping(uint => mapping(uint => mapping(address => uint256)))
        public epochVotes; // nft => round => pool => votes
    mapping(uint => address[]) public poolVote; // nft => pools
    mapping(uint256 => mapping(address => uint256)) internal weightsPerEpoch; // timestamp => pool => weights
    mapping(uint256 => uint256) internal totalWeightsPerEpoch; // timestamp => total weights
    mapping(uint => uint) public lastVoted; // nft => timestamp of last vote, to ensure one vote per epoch
    mapping(address => uint) public poolowed0;
    mapping(address => uint) public poolowed1;
    mapping(address => bool) public isGauge;
    mapping(address => bool) public isAlive;

    event DistributeReward(
        address indexed sender,
        address indexed gauge,
        uint256 amount
    );

    event CreateGauge(
        address indexed creater,
        address indexed lpAddr,
        address indexed gauge,
        address votingReward,
        address swapMinning,
        address hypervisor
    );

    event NotifyReward(
        address indexed sender,
        address indexed reward,
        uint amount
    );

    event Swaped(
        address indexed recipient,
        address indexed pool,
        uint256 amount,
        uint256 timestamp,
        bool isPerp
    );

    event Voted(
        address indexed voter,
        address indexed pool,
        uint256 indexed tokenId,
        uint256 weight,
        uint256 totalWeight,
        uint256 timestamp
    );

    event Abstained(
        address indexed voter,
        address indexed pool,
        uint256 indexed tokenId,
        uint256 weight,
        uint256 totalWeight,
        uint256 timestamp
    );

    event GaugeKilled(address indexed gauge);
    event GaugeRevived(address indexed gauge);

    constructor(
        address __ve,
        address _swapMinningFactory,
        address _masterChefFactory,
        address _votingRewardFactory,
        address _swapRouter,
        address _tradeRouter
    ) {
        _ve = __ve;
        base = IVotingEscrow(__ve).token();
        masterChefFactory = _masterChefFactory;
        votingRewardFactory = _votingRewardFactory;
        swapMinningFactory = _swapMinningFactory;
        swapRouter = _swapRouter;
        tradeRouter = _tradeRouter;
    }

    // simple re-entrancy check
    uint internal _unlocked = 1;

    modifier lock() {
        require(_unlocked == 1);
        _unlocked = 2;
        _;
        _unlocked = 1;
    }

    function setHypervisorFactory(address _f) external onlyManager {
        hypervisorFactory = _f;
    }

    function setMinter(address _minter) external onlyManager {
        minter = _minter;
    }

    modifier onlyNewEpoch(uint _tokenId) {
        // ensure new epoch since last vote
        require(
            (block.timestamp / DURATION) * DURATION > lastVoted[_tokenId],
            "TOKEN_ALREADY_VOTED_THIS_EPOCH"
        );
        _;
    }

    function reset(uint _tokenId) external onlyNewEpoch(_tokenId) {
        require(IVotingEscrow(_ve).isApprovedOrOwner(msg.sender, _tokenId));
        _reset(_tokenId);
        lastVoted[_tokenId] = block.timestamp;
        IVotingEscrow(_ve).abstain(_tokenId);
    }

    function resetNoVoted(uint _tokenId) external {
        require(msg.sender == _ve, "not ve");
        uint256 _time = _epochTimestamp();
        require(!isVoted[_tokenId][_time], "AlreadyVoted");
        _reset(_tokenId);
        IVotingEscrow(_ve).abstain(_tokenId);
    }

    function _reset(uint _tokenId) internal {
        address[] storage _poolVote = poolVote[_tokenId];
        uint _poolVoteCnt = _poolVote.length;
        uint256 _totalWeight = 0;
        uint256 _time = _epochTimestamp();
        for (uint i = 0; i < _poolVoteCnt; i++) {
            address _pool = _poolVote[i];
            uint256 _votes = votes[_tokenId][_pool];

            if (_votes != 0) {
                if (lastVoted[_tokenId] > _time)
                    weightsPerEpoch[_time][_pool] -= _votes;
                delete votes[_tokenId][_pool];
                // IVotingReward(bribes[gauges[_pool]])._withdraw(
                //     uint256(_votes),
                //     _tokenId
                // );
                _totalWeight += _votes;
                emit Abstained(
                    msg.sender,
                    _pool,
                    _tokenId,
                    _votes,
                    weightsPerEpoch[_time][_pool],
                    block.timestamp
                );
            }
        }
        // if user last vote is < than epochTimestamp then _totalWeight is 0! IF not underflow occur
        if (lastVoted[_tokenId] < _time) _totalWeight = 0;
        totalWeightsPerEpoch[_time] -= _totalWeight;
        delete poolVote[_tokenId];
    }

    function poke(uint _tokenId) external {
        address[] memory _poolVote = poolVote[_tokenId];
        uint _poolCnt = _poolVote.length;
        uint256[] memory _weights = new uint256[](_poolCnt);

        for (uint i = 0; i < _poolCnt; i++) {
            _weights[i] = votes[_tokenId][_poolVote[i]];
        }

        _vote(_tokenId, _poolVote, _weights);
    }

    function _vote(
        uint _tokenId,
        address[] memory _poolVote,
        uint256[] memory _weights
    ) internal {
        _reset(_tokenId);
        uint _poolCnt = _poolVote.length;
        uint256 _weight = IVotingEscrow(_ve).balanceOfNFT(_tokenId);
        uint256 _totalVoteWeight = 0;
        uint256 _totalWeight = 0;
        uint256 _usedWeight = 0;
        uint256 _time = _epochTimestamp();
        for (uint i = 0; i < _poolCnt; i++) {
            _totalVoteWeight += _weights[i];
        }

        for (uint i = 0; i < _poolCnt; i++) {
            address _pool = _poolVote[i];
            address _gauge = gauges[_pool];
            require(_gauge != address(0));
            if (isGauge[_gauge]) {
                uint256 _poolWeight = (_weights[i] * _weight) /
                    _totalVoteWeight;
                require(votes[_tokenId][_pool] == 0);
                require(_poolWeight != 0);

                poolVote[_tokenId].push(_pool);

                weightsPerEpoch[_time][_pool] += _poolWeight;

                votes[_tokenId][_pool] += _poolWeight;

                epochVotes[_tokenId][_time][_pool] += _poolWeight;

                isVoted[_tokenId][_time] = true;

                IVotingReward(bribes[_gauge]).deposit(
                    uint256(_poolWeight),
                    msg.sender
                );

                _usedWeight += _poolWeight;
                _totalWeight += _poolWeight;
                emit Voted(
                    msg.sender,
                    _pool,
                    _tokenId,
                    _poolWeight,
                    weightsPerEpoch[_time][_pool],
                    block.timestamp
                );
            }
        }
        if (_usedWeight > 0) IVotingEscrow(_ve).voting(_tokenId);
        totalWeightsPerEpoch[_time] += _totalWeight;
    }

    function vote(
        uint tokenId,
        address[] calldata _poolVote,
        uint256[] calldata _weights
    ) external onlyNewEpoch(tokenId) {
        require(
            IVotingEscrow(_ve).isApprovedOrOwner(msg.sender, tokenId),
            "isApprovedOrOwner error"
        );
        require(_poolVote.length == _weights.length);
        _vote(tokenId, _poolVote, _weights);
        lastVoted[tokenId] = block.timestamp;
    }

    function notifyFeeAmount(
        address poolAddrss,
        uint amount0,
        uint amount1
    ) external lock {
        //   require(msg.sender==hypervisor);
        address tokenA = IPoolV3(poolAddrss).token0();
        address tokenB = IPoolV3(poolAddrss).token1();
        if (amount0 > 0) {
            _safeTransferFrom(tokenA, msg.sender, address(this), amount0);
            poolowed0[poolAddrss] += amount0;
        }
        if (amount1 > 0) {
            _safeTransferFrom(tokenB, msg.sender, address(this), amount1);
            poolowed1[poolAddrss] += amount1;
        }
    }

    function createGauge(
        address _pool,
        address _hypervisor
    ) external returns (address, address, address) {
        require(gauges[_pool] == address(0x0), "exists");
        require(msg.sender == hypervisorFactory, "not hypervisorFactory");
        address[] memory allowedRewards = new address[](3);

        address tokenA = IPoolV3(_pool).token0();
        address tokenB = IPoolV3(_pool).token1();

        allowedRewards[0] = tokenA;
        allowedRewards[1] = tokenB;
        if (base != tokenA && base != tokenB) {
            allowedRewards[2] = base;
        }

        address _votingReward = IVotingRewardFactory(votingRewardFactory)
            .createVotingReward(allowedRewards);

        address _swapMinning = ISwapMinningFactory(swapMinningFactory)
            .createSwapMinning(allowedRewards);

        address _gauge = IMasterChefFactory(masterChefFactory).createMasterChef(
            _hypervisor,
            allowedRewards
        );

        IERC20(tokenA).approve(_votingReward, type(uint).max);
        IERC20(tokenB).approve(_votingReward, type(uint).max);
        IERC20(base).approve(_gauge, type(uint).max);
        IERC20(base).approve(_swapMinning, type(uint).max);
        masterChefs[_hypervisor] = _gauge;
        swaps[_pool] = _swapMinning;
        poolForSwap[_swapMinning] = _pool;

        bribes[_gauge] = _votingReward;

        gauges[_pool] = _gauge;
        poolForGauge[_gauge] = _pool;

        isGauge[_gauge] = true;
        isAlive[_gauge] = true;
        pools.push(_pool);
        emit CreateGauge(
            msg.sender,
            _pool,
            _gauge,
            _votingReward,
            _swapMinning,
            _hypervisor
        );
        return (_gauge, _swapMinning, _votingReward);
    }

    function killGauge(address _gauge) external onlyManager {
        require(isAlive[_gauge], "gauge already dead");
        isAlive[_gauge] = false;
        claimable[_gauge] = 0;

        uint _time = _epochTimestamp();
        totalWeightsPerEpoch[_time] -= weightsPerEpoch[_time][
            poolForGauge[_gauge]
        ];

        emit GaugeKilled(_gauge);
    }

    function reviveGauge(address _gauge) external onlyManager {
        require(!isAlive[_gauge], "gauge already alive");
        isAlive[_gauge] = true;
        emit GaugeRevived(_gauge);
    }

    function _epochTimestamp() public view returns (uint256) {
        return IMinter(minter).active_period();
    }

    function weights(address _pool) public view returns (uint256) {
        uint256 _time = _epochTimestamp();
        return weightsPerEpoch[_time][_pool];
    }

    function weightsAt(
        address _pool,
        uint256 _time
    ) public view returns (uint256) {
        return weightsPerEpoch[_time][_pool];
    }

    function totalWeight() public view returns (uint256) {
        uint256 _time = _epochTimestamp();
        return totalWeightsPerEpoch[_time];
    }

    function totalWeightAt(uint256 _time) public view returns (uint256) {
        return totalWeightsPerEpoch[_time];
    }

    function getPools() external view returns (address[] memory) {
        return pools;
    }

    function getEpochVotes(
        uint[] memory _tokenIds,
        uint _epoch,
        address _pool
    ) external view returns (uint allEpochVotes) {
        for (uint i = 0; i < _tokenIds.length; i++) {
            uint id = _tokenIds[i];
            allEpochVotes += epochVotes[id][_epoch][_pool];
        }
    }

    function depositSwap(
        address _pool,
        uint256 _amount,
        address _recipient
    ) external {
        require(
            msg.sender == swapRouter || msg.sender == tradeRouter,
            "not router"
        );
        if (swaps[_pool] != address(0)) {
            ISwapMinning(swaps[_pool]).deposit(_amount, _recipient);
            emit Swaped(
                _recipient,
                _pool,
                _amount,
                block.timestamp,
                msg.sender == tradeRouter
            );
        }
    }

    uint internal index;
    mapping(address => uint) internal supplyIndex;
    mapping(address => uint) public claimable;

    function notifyRewardAmount(uint amount) external {
        //  require(msg.sender == minter, "!minter");
        _safeTransferFrom(base, msg.sender, address(this), amount); // transfer the distro in
        uint256 _totalWeight = totalWeightAt(_epochTimestamp() - DURATION);
        uint256 _ratio = 0;
        if (_totalWeight > 0) _ratio = (amount * 1e18) / _totalWeight; // 1e18 adjustment is removed during claim
        if (_ratio > 0) {
            index += _ratio;
        }
        emit NotifyReward(msg.sender, base, amount);
    }

    function updateFor(address[] memory _gauges) external {
        for (uint i = 0; i < _gauges.length; i++) {
            _updateFor(_gauges[i]);
        }
    }

    function _updateFor(address _gauge) private {
        address _pool = poolForGauge[_gauge];
        uint256 _time = _epochTimestamp() - 604800;
        uint256 _supplied = weightsPerEpoch[_time][_pool];
        if (_supplied > 0) {
            uint _supplyIndex = supplyIndex[_gauge];
            uint _index = index; // get global index0 for accumulated distro
            supplyIndex[_gauge] = _index; // update _gauge current position to global position
            uint _delta = _index - _supplyIndex; // see if there is any difference that need to be accrued
            if (_delta > 0) {
                uint _share = (uint(_supplied) * _delta) / 1e18; // add accrued difference for each supplied token
                if (isAlive[_gauge]) {
                    claimable[_gauge] += _share;
                } else {
                    IERC20(base).transfer(minter, _share); // send rewards back to Minter so they're not stuck in Voter
                }
            }
        } else {
            supplyIndex[_gauge] = index; // new users are set to the default global state
        }
    }

    function _updateForFee(address _gauge) internal {
        address pool = poolForGauge[_gauge];
        uint _poolowed0 = poolowed0[pool];
        if (_poolowed0 / DURATION > 0) {
            poolowed0[pool] = 0;
            address tokenA = IPoolV3(pool).token0();
            IVotingReward(bribes[_gauge]).notifyRewardAmount(
                tokenA,
                _poolowed0
            );
        }
        uint _poolowed1 = poolowed1[pool];
        if (_poolowed1 / DURATION > 0) {
            poolowed1[pool] = 0;
            address tokenB = IPoolV3(pool).token1();
            IVotingReward(bribes[_gauge]).notifyRewardAmount(
                tokenB,
                _poolowed1
            );
        }
    }

    function claimBribes(
        address[] memory _bribes,
        uint[][] memory _rounds
    ) external {
        for (uint j = 0; j < _bribes.length; j++) {
            for (uint i = 0; i < _rounds[i].length; i++) {
                IVotingReward(_bribes[j]).getReward(msg.sender, _rounds[i][j]);
            }
        }
    }

    function claimSwappings(
        address[] memory _swaps,
        uint[][] memory _rounds
    ) external {
        for (uint j = 0; j < _swaps.length; j++) {
            for (uint i = 0; i < _rounds[i].length; i++) {
                ISwapMinning(_swaps[j]).getReward(msg.sender, _rounds[i][j]);
            }
        }
    }

    function claimMasterChefs(address[] memory _masterChefs) external {
        for (uint i = 0; i < _masterChefs.length; i++) {
            IMasterChef(_masterChefs[i]).getReward(msg.sender);
        }
    }

    function distribute(address _gauge) public lock {
        IMinter(minter).update_period();
        _distribute(_gauge);
    }

    function _distribute(address _gauge) internal {
        uint256 lastTimestamp = gaugesDistributionTimestmap[_gauge];
        uint256 currentTimestamp = _epochTimestamp();
        if (lastTimestamp < currentTimestamp) {
            _updateFor(_gauge); // should set claimable to 0 if killed
            uint256 _claimable = claimable[_gauge];
            address pool = poolForGauge[_gauge];
            // distribute only if claimable is > 0, currentEpoch != lastepoch and gauge is alive
            if (_claimable > 0 && isAlive[_gauge]) {
                claimable[_gauge] = 0;
                gaugesDistributionTimestmap[_gauge] = currentTimestamp;
                _updateForFee(_gauge);
                IMasterChef(_gauge).notifyRewardAmount(base, _claimable / 2);
                ISwapMinning(swaps[pool]).notifyRewardAmount(
                    base,
                    _claimable / 2
                );
                emit DistributeReward(msg.sender, _gauge, _claimable);
            }
        }
    }

    function distribute(address[] memory _gauges) external {
        IMinter(minter).update_period();
        for (uint256 x = 0; x < _gauges.length; x++) {
            _distribute(_gauges[x]);
        }
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
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "_safeTransferFrom error"
        );
    }
}
