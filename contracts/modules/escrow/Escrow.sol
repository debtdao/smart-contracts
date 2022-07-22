pragma solidity 0.8.9;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IEscrow } from "../../interfaces/IEscrow.sol";
import { IOracle } from "../../interfaces/IOracle.sol";
import { ILoan } from "../../interfaces/ILoan.sol";

contract Escrow is IEscrow {

    // the minimum value of the collateral in relation to the outstanding debt e.g. 10% of outstanding debt
    uint public minimumCollateralRatio;

    // return if have collateral but no debt
    uint256 constant MAX_INT = 115792089237316195423570985008687907853269984665640564039457584007913129639935;

    // Stakeholders and contracts used in Escrow
    address immutable public loan;
    address immutable public oracle;
    address immutable public borrower;

    // tracking tokens that were deposited
    address[] private _collateralTokens;

    // mapping if lenders allow token as collateral. ensures uniqueness in tokensUsedAsCollateral
    mapping(address => bool) private enabled;

    // tokens used as collateral (must be able to value with oracle)
    mapping(address => Deposit) public deposited;

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

  /**
    * @notice updates the cratio according to the collateral value vs loan value
    * @dev calls accrue interest on the loan contract to update the latest interest payable
    * @return the updated collateral ratio in 18 decimals
    */
    function _getLatestCollateralRatio() internal returns(uint) {
        ILoan(loan).accrueInterest();
        uint debtValue = ILoan(loan).getOutstandingDebt();
        uint collateralValue = _getCollateralValue();
        if(collateralValue == 0) return 0;
        if(debtValue == 0) return MAX_INT;

        return _percent(collateralValue, debtValue, 18);
    }

    /**
     * @notice - computes the ratio of one value to another
               - e.g. _percent(100, 100, 18) = 1 ether = 100%
     * @param numerator - value to compare
     * @param denominator - value to compare against
     * @param precision - number of decimal places of accuracy to return in answer 
     * @return - 
    */
    function _percent(uint numerator, uint denominator, uint precision) internal pure returns(uint quotient) {
        uint _numerator  = numerator * 10 ** (precision + 1);
        // with rounding of last digit
        uint _quotient =  ((_numerator / denominator) + 5) / 10;
        return ( _quotient);
    }

    /**

    * @dev calculate the USD value of all the collateral stored
    * @return - the collateral's USD value in 8 decimals
    */
    function _getCollateralValue() internal returns(uint) {
        uint collateralValue = 0;
        uint length = _collateralTokens.length;
        for(uint i = 0; i < length; i++) {
            address token = _collateralTokens[i];
            uint deposit = deposited[token].amount;
            if(deposit != 0) {
                if(deposited[token].isERC4626) {
                    // this conversion could shift, hence it is best to get it each time
                    (bool success, bytes memory assetAmount) = token.call(
                      abi.encodeWithSignature("previewRedeem(uint256)", deposit)
                    );
                    if(!success) continue;
                    deposit = abi.decode(assetAmount, (uint));
                }
                int prc = IOracle(oracle).getLatestAnswer(deposited[token].asset);
                // treat negative prices as 0
                uint price = prc < 0 ? 0 : uint(prc);
                // need to scale value by token decimal
                collateralValue += (price * deposit) / (1 * 10 ** deposited[token].assetDecimals);
            }
        }

        return collateralValue;
    }
    
  /**
    * @notice add collateral to your position
    * @dev updates cratio
    * @dev requires that the token deposited can be valued by the escrow's oracle & the depositor has approved this contract
    * @dev - callable by anyone
    * @param amount - the amount of collateral to add
    * @param token - the token address of the deposited token
    * @return - the updated cratio
    */
    function addCollateral(uint amount, address token) external returns(uint) {
        require(amount > 0, "Escrow: amount is 0");
        require(enabled[token], "Escrow: bad token");

        require(IERC20(token).transferFrom(msg.sender, address(this), amount));

        deposited[token].amount += amount;

        emit AddCollateral(token, amount);

        return _getLatestCollateralRatio();
    }


    function enableCollatareal(address token) external returns(bool) {
        require(msg.sender == loan.arbiter());

        _enableToken(token);

        return true;
    }

    /**
    * @notice track the tokens used as collateral. Ensures uniqueness,
              flags if its a EIP 4626 token, and gets its decimals
    * @dev - if 4626 token then Deposit.asset s the underlying asset, not the 4626 token
    */
    function _enableToken(address token) internal {
        if(!enabled[token]) {            
            Deposit memory deposit = deposited[token]; // gas savings
            
            (bool passed, bytes memory tokenAddrBytes) = token.call(abi.encodeWithSignature("asset()"));
            bool is4626 = tokenAddrBytes.length > 0 && passed;
            deposit.isERC4626 = is4626;
            if(is4626) {
              // if 4626 save the underlying token to use for oracle pricing
                deposit.asset = abi.decode(tokenAddrBytes, (address));
            } else {
                deposit.asset = token;
            }

            require(
              IOracle(oracle).getLatestAnswer(deposit.asset) > 0,
              "Escrow: cant enable with no price"
            );
            
            (bool successDecimals, bytes memory decimalBytes) = deposit.asset.call(abi.encodeWithSignature("decimals()"));
            if(decimalBytes.length > 0 && successDecimals) {
                deposit.assetDecimals = abi.decode(decimalBytes, (uint8));
            } else {
                deposit.assetDecimals = 18;
            }

            deposited[token] = deposit; // store results 
        }
    }

    /**
    * @notice remove collateral from your position. Must remain above min collateral ratio
    * @dev callable by `borrower`
    * @dev updates cratio
    * @param amount - the amount of collateral to release
    * @param token - the token address to withdraw
    * @param to - who should receive the funds
    * @return - the updated cratio
    */
    function releaseCollateral(uint amount, address token, address to) external returns(uint) {
        require(amount > 0, "Escrow: amount is 0");
        require(msg.sender == borrower, "Escrow: only borrower can call");
        require(deposited[token].amount >= amount, "Escrow: insufficient balance");
        deposited[token].amount -= amount;
        require(IERC20(token).transfer(to, amount));
        uint cratio = _getLatestCollateralRatio();
        require(cratio >= minimumCollateralRatio, "Escrow: cannot release collateral if cratio becomes lower than the minimum");
        emit RemoveCollateral(token, amount);

        return cratio;
    }

    /**
    * @notice calculates the cratio
    * @dev callable by anyone
    * @return - the calculated cratio
    */
    function getCollateralRatio() external returns(uint) {
        return _getLatestCollateralRatio();
    }

    /**
    * @notice calculates the collateral value in USD to 8 decimals
    * @dev callable by anyone
    * @return - the calculated collateral value to 8 decimals
    */
    function getCollateralValue() external returns(uint) {
        return _getCollateralValue();
    }

    /**
    * @notice liquidates borrowers collateral by token and amount
    * @dev requires that the cratio is at or below the liquidation threshold
    * @dev callable by `loan`
    * @param amount - the amount of tokens to liquidate
    * @param token - the address of the token to draw funds from
    * @param to - the address to receive the funds
    * @return - true if successful
    */
    function liquidate(uint amount, address token, address to) external returns(bool) {
        require(amount > 0, "Escrow: amount is 0");
        require(msg.sender == loan, "Escrow: msg.sender must be the loan contract");
        require(minimumCollateralRatio > _getLatestCollateralRatio(), "Escrow: not eligible for liquidation");
        require(deposited[token].amount >= amount, "Escrow: insufficient balance");

        deposited[token].amount -= amount;
        require(IERC20(token).transfer(to, amount));
        
        emit Liquidate(token, amount);

        return true;
    }

}
