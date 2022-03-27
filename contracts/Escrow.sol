pragma solidity 0.8.9;

import { IEscrow } from "./interfaces/IEscrow.sol";
import { LoanLib } from "./lib/LoanLib.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IOracle } from "./interfaces/IOracle.sol";

contract Escrow is IEscrow {

    uint public minimumCollateralRatio; // the minimum value of the collateral in relation to the outstanding debt e.g. 10% of outstanding debt
    address public loan;
    address public oracle; // used to value assets, must be an approved source
    address public lender;
    address public borrower;
    address public arbiter;
    bool public initCalled = false;
    LoanLib.STATUS public lastUpdatedStatus; // this status can constantly change, hence last updated status
    mapping(address => uint) public deposited; // tokens used as collateral (must be able to value with oracle)
    mapping(address => Farm) public farmedTokens; // collateral tokens that have been used for farming

    constructor(
        uint _minimumCollateralRatio,
        address _loanContract,
        address _oracle,
        address _lender,
        address _borrower,
        address _arbiter
    ) public {
        minimumCollateralRatio = minimumCollateralRatio;
        loan = loan;
        oracle = _oracle;
        lender = _lender;
        borrower = _borrower;
        arbiter = _arbiter;
        lastUpdatedStatus = LoanLib.STATUS.UNINITIALIZED; // TODO at what point does the escrow become initialized?
    }

    function init() external {
        // TODO
        require(!initCalled, "Escrow: init() has already been called");
        lastUpdatedStatus = LoanLib.STATUS.INITIALIZED;
        initCalled = true;
    }

    /*
    * @dev see IModule.sol
    */
    function healthcheck() public returns (LoanLib.STATUS status) {
        revert("Not implemented");
    }

    /*
    * @dev updates the current status by checking the cratio with the latest information
    */
    function _updateCollateralRatio() internal {
        revert("Not implemented");
    }

    /*
    * @dev see IModule.sol
    */
    function loan() external returns (address) {
        return loan;
    }

    /*
    * @dev see IEscrow.sol
    */
    function addCollateral(uint amount, address token) public {
        require(
            IOracle(oracle).getLatestAnswer(token) != 0,
            "Escrow: deposited token does not have a price feed"
        );
        require(IERC20(token).transferFrom(msg.sender, address(this), amount));
        deposited[token] += amount;
        _updateCollateralRatio();
    }

    /*
    * @dev see IEscrow.sol
    */
    function releaseCollateral(uint amount, address token, address to) public {
        revert("Not implemented");
    }

    /*
    * @dev see IEscrow.sol
    */
    function getCollateralRatio() public returns(uint) {
        revert("Not implemented");
    }

    /*
    * @dev see IEscrow.sol
    */
    function liquidate(address token, uint amount) public {
        require(msg.sender == loan, "Escrow: msg.sender must be the loan contract");
        require(healthcheck() == LoanLib.STATUS.LIQUIDATABLE, "Escrow: not eligible for liquidation");
        require(IERC20(token).transferFrom(address(this), arbiter, amount));
        deposited[token] -= amount;
    }

    // TODO @smokey
    function stakeCollateral(address token, uint amount, Farm memory farm) external {
        revert("Not implemented");
    }

    function unstakeCollateral(address token, uint amount, Farm memory farm) external {
        revert("Not implemented");
    }

    function claimStakingRewards(address[] memory farmedTokens) external {
        revert("Not implemented");
    }
}