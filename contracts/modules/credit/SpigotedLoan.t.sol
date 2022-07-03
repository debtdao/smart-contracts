
pragma solidity ^0.8.9;

pragma solidity 0.8.9;

import { DSTest } from  "../../../lib/ds-test/src/test.sol";
import { RevenueToken } from "../../mock/RevenueToken.sol";
import { SimpleOracle } from "../../mock/SimpleOracle.sol";
import { ZeroEx } from "../../mock/ZeroEx.sol";

import { SpigotController } from "../spigot/Spigot.sol";
import { SpigotedLoan } from './SpigotedLoan.sol';
import { LoanLib } from '../../utils/LoanLib.sol';

/**
 * @notice
 * @dev - does not test spigot integration e.g. claimEscrow() since that should already be covered in Spigot tests
 *      - these tests would fail if that assumption was wrong anyway
 */
contract SpigotedLoanTest is DSTest {
    ZeroEx dex;
    SpigotedLoan loan;
    SpigotController spigot;

    RevenueToken debtToken;
    RevenueToken revenueToken;

    // Named vars for common inputs
    address constant eth = address(0);
    address constant revenueContract = address(0xdebf);
    uint lentAmount = 1 ether;
    
    uint128 constant drawnRate = 100;
    uint128 constant facilityRate = 1;
    uint constant ttl = 10 days; // allows us t
    uint8 constant ownerSplit = 10; // 10% of all borrower revenue goes to spigot

    uint constant MAX_INT = 115792089237316195423570985008687907853269984665640564039457584007913129639935;
    uint constant MAX_REVENUE = MAX_INT / 100;

    // Loan access control vars
    address private lender;
    SimpleOracle private oracle;
    address private arbiter;
    address private borrower;

    function setUp() public {
        lender = address(this);
        arbiter = address(this);
        borrower = address(this);
        dex = new ZeroEx();
        debtToken = new RevenueToken();
        revenueToken = new RevenueToken();

        oracle = new SimpleOracle(address(revenueToken), address(debtToken));
        loan = new SpigotedLoan(address(oracle), arbiter, borrower, address(dex), ttl, ownerSplit);
        spigot = loan.spigot();

        _mintAndApprove();
        
        // take out loan
        loan.addDebtPosition(drawnRate, facilityRate, lentAmount, address(debtToken), lender);
        loan.addDebtPosition(drawnRate, facilityRate, lentAmount, address(debtToken), lender);

        SpigotController.SpigotSettings memory setting = SpigotController.SpigotSettings({
          token: address(revenueToken),
          ownerSplit: ownerSplit,
          claimFunction: bytes4(0),
          transferOwnerFunction: bytes4("1234")
        });
        loan.addSpigot(revenueContract, setting);
        loan.addSpigot(revenueContract, setting);

        // revenue go brrrrrrr
        spigot.claimRevenue(address(revenueContract), "");
    }

    function _mintAndApprove() public {
      
      // seed dex with tokens to buy
      debtToken.mint(address(dex), MAX_REVENUE);
      // allow loan to use tokens for depositAndRepay()
      debtToken.mint(address(this), MAX_REVENUE);
      debtToken.approve(address(loan), MAX_INT);
      

      // tokens to trade
      revenueToken.mint(address(this), MAX_REVENUE);
      // revenue earned
      revenueToken.mint(address(spigot), MAX_REVENUE);
      // allow deposits
      revenueToken.approve(address(loan), MAX_INT);
    }

    // can only remove spigot if repaid or insolvent (propery access for both situations)

    // trades work
    function _x_test_can_trade(uint buyAmount, uint sellAmount) public {
      // oracle prices not relevant to test
      if(buyAmount == 0 || sellAmount == 0) return;
      if(buyAmount > MAX_REVENUE || sellAmount > MAX_REVENUE) return;

      bytes memory tradeData = abi.encodeWithSignature(
        'trade(address,address,uint256,uint256)',
        address(revenueToken),
        address(debtToken),
        sellAmount,
        buyAmount
      );

      uint claimable = spigot.getEscrowBalance(address(revenueToken));

      loan.claimAndTrade(address(revenueToken), tradeData);
      
      // dex balances
      assertEq(revenueToken.balanceOf((address(dex))), sellAmount + MAX_REVENUE);
      assertEq(debtToken.balanceOf((address(dex))), MAX_REVENUE - buyAmount);
      
      // loan balances
      assertEq(debtToken.balanceOf((address(loan))), lentAmount + buyAmount);
      assertEq(revenueToken.balanceOf((address(loan))), 0);
      
      // spigot balances
      // should have no tokens.  most sent to tresury in setup(). rest sent in claimAndTrade
      assertEq(revenueToken.balanceOf((address(spigot))), 0);
      assertEq(debtToken.balanceOf((address(spigot))), 0);
    }

    function _x_test_can_trade_and_repay(uint buyAmount, uint sellAmount) public {
      if(buyAmount == 0 || sellAmount == 0) return;
      if(buyAmount > MAX_REVENUE || sellAmount > MAX_REVENUE) return;

      loan.borrow(loan.positionIds(0), lentAmount);
      
      // amount of tokens owed in interest (not usd owed!)
      uint256 interest = loan.accrueInterest() / uint(oracle.getLatestAnswer(address(debtToken)));

      // oracle prices not relevant to test
      bytes memory tradeData = abi.encodeWithSignature(
        'trade(address,address,uint256,uint256)',
        address(revenueToken),
        address(debtToken),
        sellAmount,
        buyAmount
      );


      loan.claimAndTrade(address(revenueToken), tradeData);

      // principal, interest, repaid
      (,uint p, uint i, uint r,,,) = loan.debts(loan.positionIds(0));

      // outstanding debt = initial principal + accrued interest - tokens repaid
      assertEq(p + i, lentAmount + interest - buyAmount);

      if(interest > buyAmount) {
        // only interest paid
        assertEq(r, buyAmount); // paid what interest we could
        assertEq(i, interest - buyAmount); // interest owed should be reduced by repay amount
        assertEq(p, lentAmount); // no change in principal

      } else {
        assertEq(p, lentAmount - interest);
        // all interest repaid
        assertEq(i, 0);
        assertEq(r, interest);

        assertEq(loan.unusedTokens(address(debtToken)), buyAmount - i);
        assertEq(loan.unusedTokens(address(revenueToken)), 0); // TODO come up with scenario where this should be > 0
      }

    }

    // check unsused balances. Do so by changing minAmountOut in trade 0

    // Spigot integration tests
    // Only checking that Loan functions dont fail. Check `Spigot.t.sol` for expected functionality

    function _x_test_can_deposit_and_repay() public {
      loan.borrow(loan.positionIds(0), lentAmount);
      loan.depositAndRepay(lentAmount);
    }

    function test_update_split() public {
      loan.updateOwnerSplit(revenueContract);
    }

    function testFail_release_spigot_while_active() public {
      assertTrue(loan.releaseSpigot());
    }

    function test_release_spigot_when_repaid() public {
      assertTrue(loan.close(loan.positionIds(0)));

      assertTrue(loan.releaseSpigot());

      // TODO: bad test, will be address(this either way
      assertEq(spigot.owner(), borrower);
    }

    function test_cant_sweep_tokens_while_active() public {
      assertEq(0, loan.sweep(address(debtToken))); // no tokens transfered
    }

    function test_sweep_tokens_when_repaid() public {
      assertTrue(loan.close(loan.positionIds(0)));
      uint unused = loan.unusedTokens(address(debtToken));
      assertEq(loan.sweep(address(debtToken)), unused);
    }

    function testFail_update_split_bad_contract() public {
      loan.updateOwnerSplit(address(0xdead));
    }

    // TODO force loan into liquidatable to test - updateOwnerSplit, sweep, and releaseSpigot
}
