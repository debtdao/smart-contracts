import { LoanLib } from "../utils/LoanLib.sol";

interface ILoan {
  // Stakeholder data
  struct DebtPosition {
    address lender;           // person to repay
    address token;            // token being lent out
    uint8 decimals;           // token's decimals for adjusting price / amounts
    bool init;                // if lender made deposit yet
    // all denominated in token, not USD
    uint256 deposit;          // total liquidity provided by lender for token
    uint256 principal;        // amount actively lent out
    uint256 interestAccrued;  // interest accrued but not repaid
    uint256 interestRepaid;   // interest repaid by borrower but not withdrawn by lender
  }

  // Lender Events

  event AddDebtPosition(address indexed lender, address indexed token, uint256 indexed deposit);
  // can reference only positionId once AddDebtPosition is emitted because it will be stored in subgraph

  event Withdraw(bytes32 indexed positionId, uint256 indexed amount);

  event CloseDebtPosition(bytes32 indexed positionId);

  event InterestAccrued(bytes32 indexed positionId, uint256 indexed tokenAmount, uint256 indexed value);

  // Borrower Events
  event Borrow(bytes32 indexed positionId, uint256 indexed amount);

  event RepayInterest(bytes32 indexed positionId, uint256 indexed amount);

  event RepayPrincipal(bytes32 indexed positionId, uint256 indexed amount);

  event Liquidate(bytes32 indexed positionId, uint256 indexed amount, address indexed token);

  event Default(bytes32 indexed positionId);

  // General Events
  event UpdateLoanStatus(uint256 indexed status); // store as normal uint so it can be indexed in subgraph


  // External Functions  
  function addDebtPosition(uint256 amount, address token, address lender) external returns(bool);
  function withdraw(bytes32 positionId, uint256 amount) external returns(bool);
  function borrow(bytes32 positionId, uint256 amount) external returns(bool);
  function close(bytes32 positionId) external returns(bool);
  function liquidate(bytes32 positionId, uint256 amount, address targetToken) external returns(uint256);

  function depositAndRepay(bytes32 positionId, uint256 amount) external returns(bool);
  function depositAndClose(bytes32 positionId) external returns(bool);

  function accrueInterest() external returns(uint256 amountAccrued);
  function getOutstandingDebt() external returns(uint256 totalDebt);
  function healthcheck() external returns(LoanLib.STATUS);
}
