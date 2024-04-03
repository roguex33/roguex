// SPDX-License-Identifier: MIT

pragma solidity 0.8.12;

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

interface IRewardsDistributor {
    function checkpoint_token() external;

    function checkpoint_total_supply() external;
}

interface IROX {
    function totalSupply() external view returns (uint);

    function balanceOf(address) external view returns (uint);

    function approve(address spender, uint value) external returns (bool);

    function transfer(address, uint) external returns (bool);

    function transferFrom(address, address, uint) external returns (bool);

    function mint(address, uint) external returns (bool);
}

interface IVoter {
    function _ve() external view returns (address);

    function notifyRewardAmount(uint amount) external;
}

interface IVotingEscrow {
    function token() external view returns (address);

    function totalSupply() external view returns (uint);
}

contract Minter {
    uint internal constant WEEK = 7 days; // allows minting once per week (reset every Thursday 00:00 UTC)
    uint internal constant EMISSION = 9900;
    uint internal constant TAIL_EMISSION = 10;
    uint internal constant PRECISION = 10000;
    IROX public immutable _rox;
    IVoter public immutable _voter;
    uint public rate = 100;
    IVotingEscrow public immutable _ve;
    IRewardsDistributor public immutable _rewards_distributor;
    uint public active_period;

    address internal initializer;

    event Mint(
        address indexed sender,
        uint weekly,
        uint growth,
        uint circulating_emission
    );

    constructor(
        address __voter, // the voting & distribution system
        address __ve, // the ve(3,3) system that will be locked into
        address __rewards_distributor // the distribution system that ensures users aren't diluted
    ) {
        initializer = msg.sender;
        _rox = IROX(IVotingEscrow(__ve).token());
        _voter = IVoter(__voter);
        _ve = IVotingEscrow(__ve);
        _rewards_distributor = IRewardsDistributor(__rewards_distributor);
        active_period = ((block.timestamp + (2 * WEEK)) / WEEK) * WEEK;
    }

    function initialize() external {
        require(initializer == msg.sender);
        initializer = address(0);
        active_period = ((block.timestamp) / WEEK) * WEEK; // allow minter.update_period() to mint new emissions THIS Thursday
    }

    // emission calculation is 1% of available supply to mint adjusted by circulating / total supply
    function calculate_emission() public view returns (uint) {
        return (((_rox.totalSupply() * rate) / PRECISION) * 2);
    }

    // weekly emission takes the max of calculated (aka target) emission versus circulating tail end emission
    function weekly_emission() public view returns (uint) {
        return Math.max(calculate_emission(), circulating_emission());
    }

    // calculates tail end (infinity) emissions as 0.1% of total supply
    function circulating_emission() public view returns (uint) {
        return (((_rox.totalSupply() * TAIL_EMISSION) / PRECISION) * 2);
    }

    //

    // calculate inflation and adjust ve balances accordingly
    function calculate_growth(uint _minted) public view returns (uint) {
        uint _veTotal = _ve.totalSupply();
        uint _roxTotal = _rox.totalSupply();
        if (_roxTotal < 1)
            return 0;
        return (((_minted * _veTotal) / _roxTotal) * 3) / 2;
    }

    // update period can only be called once per cycle (1 week)
    function update_period() external returns (uint) {
        uint _period = active_period;
        if (block.timestamp >= _period + WEEK && initializer == address(0)) {
            // only trigger if new week
            _period = (block.timestamp / WEEK) * WEEK;
            active_period = _period;
            uint weekly = weekly_emission(); // lp and swap reward
            uint _growth = calculate_growth(weekly / 2); // rebase reward
            uint _required = _growth + weekly;
            uint _balanceOf = _rox.balanceOf(address(this));
            if (_balanceOf < _required) {
                _rox.mint(address(this), _required - _balanceOf);
            }
            require(
                _rox.transfer(address(_rewards_distributor), _growth),
                "rewards_distributor growth error"
            );
            _rewards_distributor.checkpoint_token(); // checkpoint token balance that was just minted in rewards distributor
            _rewards_distributor.checkpoint_total_supply(); // checkpoint supply

            _rox.approve(address(_voter), weekly);
            _voter.notifyRewardAmount(weekly);
            rate = (rate * EMISSION) / PRECISION;
            emit Mint(msg.sender, weekly, _growth, circulating_emission());
        }
        return _period;
    }
}
