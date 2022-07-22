pragma solidity ^0.8.9;
interface ISpigotedLoan {
  event RevenuePayment(
    address indexed token,
    uint256 indexed amount
    // dont need to track value like other events because _repay already emits
    // this event is just semantics/helper to track payments from revenue specifically
  );

  event TradeSpigotRevenue(
    address indexed revenueToken,
    uint256 revenueTokenAmount,
    address indexed debtToken,
    uint256 indexed debtTokensBought
  );
  
  function unused(address token) external returns(uint256);

  function claimAndTrade(
    address claimToken, 
    bytes calldata zeroExTradeData
  ) external returns(uint256 tokensBought);

  function claimAndRepay(
    address token,
    bytes calldata zeroExTradeData
  ) external returns(bool);

  function sweep(address token) external returns(uint256);
}
