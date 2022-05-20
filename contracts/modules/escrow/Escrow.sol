pragma solidity 0.8.9;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IEscrow } from "../../interfaces/IEscrow.sol";
import { IOracle } from "../../interfaces/IOracle.sol";
import { ILoan } from "../../interfaces/ILoan.sol";

contract Escrow is IEscrow {

    // the minimum value of the collateral in relation to the outstanding debt e.g. 10% of outstanding debt
    uint public minimumCollateralRatio;

    // return if have collateral but no debt
    uint256 MAX_INT = 115792089237316195423570985008687907853269984665640564039457584007913129639935;

    // Stakeholders and contracts used in Escrow
    address public loan;
    address public oracle;
    address public borrower;

    // tracking tokens that were deposited
    address[] private _tokensUsedAsCollateral;

    // mapping to check uniqueness of tokensUsedAsCollateral
    mapping(address => bool) private _tokensUsed;

    // tokens used as collateral (must be able to value with oracle)
    mapping(address => uint) public deposited;

    // collateral tokens that have been used for farming
    mapping(address => Farm) public farmedTokens;

    constructor(
        uint _minimumCollateralRatio,
        address _oracle,
        address _loan,
        address _borrower
    ) public {
        minimumCollateralRatio = _minimumCollateralRatio;
        oracle = _oracle;
        loan = _loan;
        borrower = _borrower;
    }

    /*
    * @dev updates the cratio according to the collateral value vs loan value
    * @dev calls accrue interest on the loan contract to update the latest interest payable
    * @returns the updated collateral ratio
    */
    function _getLatestCollateralRatio() internal returns(uint) {
        ILoan(loan).accrueInterest();
        uint debtValue = ILoan(loan).getOutstandingDebt();
        uint collateralValue = _getCollateralValue();
        if(collateralValue == 0) return 0;
        if(debtValue == 0) return MAX_INT;

        return _percent(collateralValue, debtValue, 18);
    }

    // https://stackoverflow.com/questions/42738640/division-in-ethereum-solidity/42739843#42739843
    function _percent(uint numerator, uint denominator, uint precision) internal pure returns(uint quotient) {
        uint _numerator  = numerator * 10 ** (precision + 1);
        // with rounding of last digit
        uint _quotient =  ((_numerator / denominator) + 5) / 10;
        return ( _quotient);
    }

    /*
    * @dev calculate the USD value of the collateral stored
    * @returns - the collateral's USD value
    */
    function _getCollateralValue() internal returns(uint) {
        int collateralValue = 0;
        for(uint i = 0; i < _tokensUsedAsCollateral.length; i++) {
            address token = _tokensUsedAsCollateral[i];
            uint deposit = deposited[token];
            if(deposit != 0) {
                int price = IOracle(oracle).getLatestAnswer(token);
                // need to scale value by token decimal
                (bool success, bytes memory result) = token.call(abi.encodeWithSignature("decimals()"));
                if(!success) {
                  int val = price < 0 ?
                      (uint256(-price) * deposit) / 1e18 : 
                      (uint256(price) * deposit) / 1e18;
                   collateralValue += val;
                } else {
                    uint8 decimals = abi.decode(result, (uint8));
                    collateralValue += price < 0 ?
                        (uint256(-price) * deposit) / (1 * 10 ** decimals) : 
                        (uint256(price) * deposit) / (1 * 10 ** decimals);
                }
                
            }
        }

        collateralValue = collateralValue < int(0) ? int(0) : collateralValue;

        return uint(collateralValue);
    }

    function _getCollateralValue() internal returns(uint) {
        uint collateralValue = 0;
        for(uint i = 0; i < _tokensUsedAsCollateral.length; i++) {
            address token = _tokensUsedAsCollateral[i];
            uint deposit = deposited[token];
            if(deposit != 0) {
                int price = IOracle(oracle).getLatestAnswer(token);
                // need to scale value by token decimal
                uint8 decimals = _getTokenDecimals(token);
                if(price < 0) {
                    // if negative price, get absolute value then subtract
                    uint negValue = (uint256(-price) * deposit) / (1 * 10 ** decimals);
                    // prevent underflow revert and floor value at 0
                    collateralValue = negValue > collateralValue ? 0 : collateralValue - negValue;
                } else {
                    collateralValue += (uint256(price) * deposit) / (1 * 10 ** decimals);
                }
            }
        }

        return collateralValue;
    }

    function _getTokenDecimals(address token) internal returns(uint8) {
       (bool success, bytes memory result) = token.call(abi.encodeWithSignature("decimals()"));
        if(!success) {
            return uint8(18); // default to standard erc20 18 decimals
        } else {
            return abi.decode(result, (uint8));
        }
    }
    /*
    * @dev see IEscrow.sol
    */
    function addCollateral(uint amount, address token) external returns(uint) {
        require(amount > 0, "Escrow: amount is 0");
        require(
            IOracle(oracle).getLatestAnswer(token) != 0,
            "Escrow: deposited token does not have a price feed"
        );
        require(IERC20(token).transferFrom(msg.sender, address(this), amount));
        deposited[token] += amount;
        _addTokenUsed(token);
        emit CollateralAdded(token, amount);

        return _getLatestCollateralRatio();
    }

    /*
    * @dev track the tokens used as collateral
    */
    function _addTokenUsed(address token) internal {
        if(!_tokensUsed[token]) {
            _tokensUsed[token] = true;
            _tokensUsedAsCollateral.push(token);
        }
    }

    /*
    * @dev see IEscrow.sol
    */
    function releaseCollateral(uint amount, address token, address to) external returns(uint) {
        require(amount > 0, "Escrow: amount is 0");
        require(msg.sender == borrower, "Escrow: only borrower can call");
        require(deposited[token] >= amount, "Escrow: insufficient balance");
        deposited[token] -= amount;
        require(IERC20(token).transfer(to, amount));
        uint cratio = _getLatestCollateralRatio();
        require(cratio >= minimumCollateralRatio, "Escrow: cannot release collateral if cratio becomes lower than the minimum");
        emit CollateralRemoved(token, amount);

        return cratio;
    }

    /*
    * @dev see IEscrow.sol
    */
    function getCollateralRatio() external returns(uint) {
        return _getLatestCollateralRatio();
    }

    /*
    * @dev see IEscrow.sol
    */
    function getCollateralValue() external returns(uint) {
        return _getCollateralValue();
    }

    /*
    * @dev see IEscrow.sol
    */
    function liquidate(uint amount, address token, address to) external returns(bool) {
        require(amount > 0, "Escrow: amount is 0");
        require(msg.sender == loan, "Escrow: msg.sender must be the loan contract");
        require(minimumCollateralRatio > _getLatestCollateralRatio(), "Escrow: not eligible for liquidation");
        require(deposited[token] >= amount, "Escrow: insufficient balance");
        deposited[token] -= amount;
        require(IERC20(token).transfer(to, amount));
        emit Liquidated(token, amount);

        return true;
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
