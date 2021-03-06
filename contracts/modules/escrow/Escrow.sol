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
    mapping(address => Deposit) public deposited;

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
        uint collateralValue = 0;
        for(uint i = 0; i < _tokensUsedAsCollateral.length; i++) {
            address token = _tokensUsedAsCollateral[i];
            uint deposit = deposited[token].amount;
            if(deposit != 0) {
                if(deposited[token].isERC4626) {
                    // this conversion could shift, hence it is best to get it each time
                    (bool success, bytes memory assetAmount) = token.call(abi.encodeWithSignature("previewRedeem(uint256)", deposit));
                    deposit = abi.decode(assetAmount, (uint));
                }
                int prc = IOracle(oracle).getLatestAnswer(token);
                // treat negative prices as 0
                uint price = prc < 0 ? 0 : uint(prc);
                // need to scale value by token decimal
                collateralValue += (price * deposit) / (1 * 10 ** deposited[token].assetDecimals);
            }
        }

        return collateralValue;
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
        deposited[token].amount += amount;
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
            (bool passed, bytes memory tokenAddrBytes) = token.call(abi.encodeWithSignature("asset()"));
            bool is4626 = tokenAddrBytes.length > 0 && passed;
            deposited[token].isERC4626 = is4626;
            if(is4626) {
                deposited[token].asset = abi.decode(tokenAddrBytes, (address));
            } else {
                deposited[token].asset = token;
            }
            (bool successDecimals, bytes memory decimalBytes) = deposited[token].asset.call(abi.encodeWithSignature("decimals()"));
            if(decimalBytes.length > 0 && successDecimals) {
                deposited[token].assetDecimals = abi.decode(decimalBytes, (uint8));
            } else {
                deposited[token].assetDecimals = 18;
            }
        }
    }

    /*
    * @dev see IEscrow.sol
    */
    function releaseCollateral(uint amount, address token, address to) external returns(uint) {
        require(amount > 0, "Escrow: amount is 0");
        require(msg.sender == borrower, "Escrow: only borrower can call");
        require(deposited[token].amount >= amount, "Escrow: insufficient balance");
        deposited[token].amount -= amount;
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
        require(deposited[token].amount >= amount, "Escrow: insufficient balance");
        deposited[token].amount -= amount;
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
