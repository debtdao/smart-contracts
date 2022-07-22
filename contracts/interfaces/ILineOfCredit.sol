import { LoanLib } from "../utils/LoanLib.sol";
import { ILoan } from "./ILoan.sol";

interface ILineOfCredit is ILoan {
  // Lender data
  struct DebtPosition {
    //  all denominated in token, not USD
    uint256 deposit;          // total liquidity provided by lender for token
    uint256 principal;        // amount actively lent out
    uint256 interestAccrued;  // interest accrued but not repaid
    uint256 interestRepaid;   // interest repaid by borrower but not withdrawn by lender
    uint8 decimals;           // decimals of debt token for calcs

    address lender;           // person to repay
    address token;            // token being lent out
  }

  event SetRates(bytes32 indexed positionId, uint128 indexed drawnRate, uint128 indexed facilityRate);

  function addDebtPosition(
    uint128 drawnRate,
    uint128 facilityRate,
    uint256 amount,
    address token,
    address lender
  ) external returns(bytes32);
  function borrow(bytes32 positionId, uint256 amount) external returns(bool);
  function close(bytes32 positionId) external returns(bool);
}
