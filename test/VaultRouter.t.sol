// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {Deployers} from "./utils/Deployers.sol";

import {VaultRouter} from "../src/VaultRouter.sol";

// Mock ERC4626 Vault for testing
contract MockVault is ERC4626 {
    uint256 private _mockYield;
    
    constructor(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        uint256 mockYield_
    ) ERC4626(asset_) ERC20(name_, symbol_) {
        _mockYield = mockYield_;
    }
    
    function setMockYield(uint256 newYield) external {
        _mockYield = newYield;
    }
    
    // Override to simulate different yields
    function totalAssets() public view override returns (uint256) {
        uint256 baseAssets = super.totalAssets();
        return baseAssets + (_mockYield * baseAssets / 1e18);
    }
}

contract VaultRouterTest is Test, Deployers {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    Currency currency0;
    Currency currency1;
    MockERC20 token0;
    MockERC20 token1;

    PoolKey poolKey;
    VaultRouter hook;
    PoolId poolId;

    MockVault vault1;
    MockVault vault2;
    MockVault vault3;

    uint256 tokenId;
    int24 tickLower;
    int24 tickUpper;

    // Events to test
    event VaultAdded(address indexed vault, address indexed asset, uint256 priority);
    event VaultRemoved(address indexed vault);
    event VaultPriorityUpdated(address indexed vault, uint256 newPriority);
    event FundsRouted(address indexed fromVault, address indexed toVault, uint256 amount);
    event RoutingStrategyUpdated(PoolId indexed poolId, VaultRouter.RoutingStrategy strategy);

    function setUp() public {
        // Deploy all required artifacts
        deployArtifacts();

        // Deploy currency pair
        (currency0, currency1) = deployCurrencyPair();
        token0 = MockERC20(Currency.unwrap(currency0));
        token1 = MockERC20(Currency.unwrap(currency1));

        // Deploy the hook to an address with the correct flags
        address flags = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG | 
                Hooks.BEFORE_SWAP_FLAG | 
                Hooks.AFTER_SWAP_FLAG |
                Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG |
                Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            ) ^ (0x4444 << 144) // Namespace the hook to avoid collisions
        );
        
        bytes memory constructorArgs = abi.encode(poolManager);
        deployCodeTo("VaultRouter.sol:VaultRouter", constructorArgs, flags);
        hook = VaultRouter(flags);

        // Create the pool
        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(hook));
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        // Setup liquidity
        tickLower = TickMath.minUsableTick(poolKey.tickSpacing);
        tickUpper = TickMath.maxUsableTick(poolKey.tickSpacing);

        uint128 liquidityAmount = 100e18;

        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmount
        );

        (tokenId,) = positionManager.mint(
            poolKey,
            tickLower,
            tickUpper,
            liquidityAmount,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );

        // Deploy mock vaults
        vault1 = new MockVault(IERC20(address(token0)), "Vault1", "V1", 0.05e18); // 5% yield
        vault2 = new MockVault(IERC20(address(token0)), "Vault2", "V2", 0.10e18); // 10% yield
        vault3 = new MockVault(IERC20(address(token0)), "Vault3", "V3", 0.03e18); // 3% yield

         // Mint tokens to this contract for deposits
        token0.mint(address(this), 3000e18);
        
        // Deposit tokens to create shares (simulate real vault usage)
        token0.approve(address(vault1), 1000e18);
        token0.approve(address(vault2), 1000e18);
        token0.approve(address(vault3), 1000e18);
        vault1.deposit(1000e18, address(this));
        vault2.deposit(1000e18, address(this));
        vault3.deposit(1000e18, address(this));
    }

    function testAddVault() public {
        vm.expectEmit(true, true, false, true);
        emit VaultAdded(address(vault1), address(token0), 100);
        
        hook.addVault(address(vault1), 100, 50);
        
        VaultRouter.VaultInfo memory info = hook.getVaultInfo(address(vault1));
        assertEq(info.vault, address(vault1));
        assertEq(info.asset, address(token0));
        assertEq(info.priority, 100);
        assertEq(info.riskScore, 50);
        assertTrue(info.isActive);
        assertEq(info.totalRouted, 0);
        assertEq(info.allVaultsIndex, 0);
        assertEq(info.assetVaultsIndex, 0);

        // Add another vault to see indices increment
        hook.addVault(address(vault2), 100, 50);
        info = hook.getVaultInfo(address(vault2));
        assertEq(info.allVaultsIndex, 1);
        assertEq(info.assetVaultsIndex, 1);
    }

    function testAddVaultOnlyOwner() public {
        vm.prank(address(0x123));
        vm.expectRevert();
        hook.addVault(address(vault1), 100, 50);
    }

    function testAddVaultInvalidInputs() public {
        // Invalid vault address
        vm.expectRevert("Invalid vault address");
        hook.addVault(address(0), 100, 50);
        
        // Invalid risk score
        vm.expectRevert("Risk score must be 1-100");
        hook.addVault(address(vault1), 100, 0);
        
        vm.expectRevert("Risk score must be 1-100");
        hook.addVault(address(vault1), 100, 101);
    }

    function testAddVaultAlreadyExists() public {
        hook.addVault(address(vault1), 100, 50);
        
        vm.expectRevert("Vault already exists");
        hook.addVault(address(vault1), 200, 30);
    }

    function testRemoveVault() public {
        hook.addVault(address(vault1), 100, 50);
        
        vm.expectEmit(true, false, false, false);
        emit VaultRemoved(address(vault1));
        
        hook.removeVault(address(vault1));
        
        VaultRouter.VaultInfo memory info = hook.getVaultInfo(address(vault1));
        assertFalse(info.isActive);
    }

    function testRemoveVaultUpdatesIndices() public {
        hook.addVault(address(vault1), 100, 50);
        hook.addVault(address(vault2), 100, 30);
        hook.addVault(address(vault3), 100, 70);

        // Remove the middle vault (vault2)
        hook.removeVault(address(vault2));

        // vault3 should have been moved to vault2's old spot
        VaultRouter.VaultInfo memory info3 = hook.getVaultInfo(address(vault3));
        assertEq(info3.allVaultsIndex, 1, "allVaultsIndex should be updated");
        assertEq(info3.assetVaultsIndex, 1, "assetVaultsIndex should be updated");

        // Check array lengths
        address[] memory allVaults = hook.getAllActiveVaults();
        assertEq(allVaults.length, 2, "Should be 2 active vaults");

        address[] memory assetVaults = hook.getVaultsForAsset(address(token0));
        assertEq(assetVaults.length, 2, "Should be 2 asset vaults");
        assertEq(assetVaults[0], address(vault1));
        assertEq(assetVaults[1], address(vault3)); // vault3 moved here
    }

    function testRemoveVaultNotActive() public {
        vm.expectRevert("Vault not active");
        hook.removeVault(address(vault1));
    }

    function testUpdateVaultPriority() public {
        hook.addVault(address(vault1), 100, 50);
        
        vm.expectEmit(true, false, false, true);
        emit VaultPriorityUpdated(address(vault1), 200);
        
        hook.updateVaultPriority(address(vault1), 200);
        
        VaultRouter.VaultInfo memory info = hook.getVaultInfo(address(vault1));
        assertEq(info.priority, 200);
    }

    function testUpdateVaultRiskScore() public {
        hook.addVault(address(vault1), 100, 50);
        
        hook.updateVaultRiskScore(address(vault1), 75);
        
        VaultRouter.VaultInfo memory info = hook.getVaultInfo(address(vault1));
        assertEq(info.riskScore, 75);
    }

    function testSetPoolRoutingStrategy() public {
        vm.expectEmit(true, false, false, true);
        emit RoutingStrategyUpdated(poolId, VaultRouter.RoutingStrategy.HIGHEST_YIELD);
        
        hook.setPoolRoutingStrategy(poolId, VaultRouter.RoutingStrategy.HIGHEST_YIELD);
        
        assertEq(uint256(hook.poolRoutingStrategy(poolId)), uint256(VaultRouter.RoutingStrategy.HIGHEST_YIELD));
    }

    function testAddVaultsToPool() public {
        hook.addVault(address(vault1), 100, 50);
        hook.addVault(address(vault2), 200, 30);
        
        address[] memory vaults = new address[](2);
        vaults[0] = address(vault1);
        vaults[1] = address(vault2);
        
        hook.addVaultsToPool(poolId, vaults);
        
        assertTrue(hook.isVaultInPool(poolId, address(vault1)));
        assertTrue(hook.isVaultInPool(poolId, address(vault2)));
    }

    function testGetOptimalVaultHighestYield() public {
        // Add vaults with different yields
        hook.addVault(address(vault1), 100, 50); // 5% yield
        hook.addVault(address(vault2), 100, 30); // 10% yield
        hook.addVault(address(vault3), 100, 70); // 3% yield
        
        address[] memory vaults = new address[](3);
        vaults[0] = address(vault1);
        vaults[1] = address(vault2);
        vaults[2] = address(vault3);
        
        hook.addVaultsToPool(poolId, vaults);
        hook.setPoolRoutingStrategy(poolId, VaultRouter.RoutingStrategy.HIGHEST_YIELD);
        
        address optimal = hook.getOptimalVault(poolId, address(token0), 1e18);
        assertEq(optimal, address(vault2)); // Should select vault2 with highest yield
    }

    function testGetOptimalVaultLowestRisk() public {
        hook.addVault(address(vault1), 100, 50);
        hook.addVault(address(vault2), 100, 30); // Lowest risk
        hook.addVault(address(vault3), 100, 70);
        
        address[] memory vaults = new address[](3);
        vaults[0] = address(vault1);
        vaults[1] = address(vault2);
        vaults[2] = address(vault3);
        
        hook.addVaultsToPool(poolId, vaults);
        hook.setPoolRoutingStrategy(poolId, VaultRouter.RoutingStrategy.LOWEST_RISK);
        
        address optimal = hook.getOptimalVault(poolId, address(token0), 1e18);
        assertEq(optimal, address(vault2)); // Should select vault2 with lowest risk
    }

    function testGetOptimalVaultManualPriority() public {
        hook.addVault(address(vault1), 100, 50);
        hook.addVault(address(vault2), 300, 30); // Highest priority
        hook.addVault(address(vault3), 200, 70);
        
        address[] memory vaults = new address[](3);
        vaults[0] = address(vault1);
        vaults[1] = address(vault2);
        vaults[2] = address(vault3);
        
        hook.addVaultsToPool(poolId, vaults);
        hook.setPoolRoutingStrategy(poolId, VaultRouter.RoutingStrategy.MANUAL_PRIORITY);
        
        address optimal = hook.getOptimalVault(poolId, address(token0), 1e18);
        assertEq(optimal, address(vault2)); // Should select vault2 with highest priority
    }

    function testGetOptimalVaultRoundRobin_view() public {
        hook.addVault(address(vault1), 100, 50);
        hook.addVault(address(vault2), 100, 30);
        hook.addVault(address(vault3), 100, 70);
        
        address[] memory vaults = new address[](3);
        vaults[0] = address(vault1);
        vaults[1] = address(vault2);
        vaults[2] = address(vault3);
        
        hook.addVaultsToPool(poolId, vaults);
        hook.setPoolRoutingStrategy(poolId, VaultRouter.RoutingStrategy.ROUND_ROBIN);
        
        // First call should return first vault (index 0)
        address optimal1 = hook.getOptimalVault(poolId, address(token0), 1e18);
        assertEq(optimal1, address(vault1));
    }

    function testRoundRobinAfterSwapAdvancesIndex() public {
        hook.addVault(address(vault1), 100, 50);
        hook.addVault(address(vault2), 100, 30);
        hook.addVault(address(vault3), 100, 70);

        address[] memory vaults = new address[](3);
        vaults[0] = address(vault1);
        vaults[1] = address(vault2);
        vaults[2] = address(vault3);
        
        hook.addVaultsToPool(poolId, vaults);
        hook.setPoolRoutingStrategy(poolId, VaultRouter.RoutingStrategy.ROUND_ROBIN);

        // This hookData forces vault selection and deposit in afterSwap
        bytes memory hookData = abi.encode(address(this), address(0), uint256(0));

        // Swap 1: Should use vault1
        swapRouter.swapExactTokensForTokens({
            amountIn: 1e17, amountOutMin: 0, zeroForOne: false, poolKey: poolKey,
            hookData: hookData, receiver: address(hook), deadline: block.timestamp + 1
        });
        assertEq(hook.vaultUtilization(address(vault1)), 1);
        assertEq(hook.vaultUtilization(address(vault2)), 0);

        // Swap 2: Should use vault2
        swapRouter.swapExactTokensForTokens({
            amountIn: 1e17, amountOutMin: 0, zeroForOne: false, poolKey: poolKey,
            hookData: hookData, receiver: address(hook), deadline: block.timestamp + 1
        });
        assertEq(hook.vaultUtilization(address(vault1)), 1);
        assertEq(hook.vaultUtilization(address(vault2)), 1);
        assertEq(hook.vaultUtilization(address(vault3)), 0);

        // Swap 3: Should use vault3
        swapRouter.swapExactTokensForTokens({
            amountIn: 1e17, amountOutMin: 0, zeroForOne: false, poolKey: poolKey,
            hookData: hookData, receiver: address(hook), deadline: block.timestamp + 1
        });
        assertEq(hook.vaultUtilization(address(vault3)), 1);

        // Swap 4: Should wrap around to vault1
        swapRouter.swapExactTokensForTokens({
            amountIn: 1e17, amountOutMin: 0, zeroForOne: false, poolKey: poolKey,
            hookData: hookData, receiver: address(hook), deadline: block.timestamp + 1
        });
        assertEq(hook.vaultUtilization(address(vault1)), 2);
    }

    function testGetAvailableVaults() public {
        hook.addVault(address(vault1), 100, 50);
        hook.addVault(address(vault2), 100, 30);
        
        address[] memory vaults = new address[](2);
        vaults[0] = address(vault1);
        vaults[1] = address(vault2);
        
        hook.addVaultsToPool(poolId, vaults);
        
        address[] memory available = hook.getAvailableVaults(poolId, address(token0));
        assertEq(available.length, 2);
        assertEq(available[0], address(vault1));
        assertEq(available[1], address(vault2));
    }

    function testSwapTriggersHooks() public {
        // Add vault and set strategy
        hook.addVault(address(vault1), 100, 50);
        
        address[] memory vaults = new address[](1);
        vaults[0] = address(vault1);
        hook.addVaultsToPool(poolId, vaults);
        
        uint256 amountIn = 1e18;

        // The receiver of the swap must be the hook for it to deposit the assets.
        // We can pass this contract's address in the hookData to receive the shares.
        bytes memory hookData = abi.encode(address(this), address(0), uint256(0));
        
        // Perform swap
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: false, // Changed to false to output token0, which has a vault
            poolKey: poolKey,
            hookData: hookData,
            receiver: address(hook),
            deadline: block.timestamp + 1
        });
        
        // Check that swap was processed
        assertEq(hook.totalSwapsProcessed(poolId), 1);
        assertGt(hook.vaultUtilization(address(vault1)), 0);
    }

    function testGetAllActiveVaults() public {
        hook.addVault(address(vault1), 100, 50);
        hook.addVault(address(vault2), 100, 30);
        hook.addVault(address(vault3), 100, 70);
        
        // Remove one vault
        hook.removeVault(address(vault2));
        
        address[] memory activeVaults = hook.getAllActiveVaults();
        assertEq(activeVaults.length, 2);
        
        // Check that removed vault is not in active list
        bool foundVault2 = false;
        for (uint256 i = 0; i < activeVaults.length; i++) {
            if (activeVaults[i] == address(vault2)) {
                foundVault2 = true;
                break;
            }
        }
        assertFalse(foundVault2);
    }

    function testGetVaultsForAsset() public {
        hook.addVault(address(vault1), 100, 50);
        hook.addVault(address(vault2), 100, 30);
        
        address[] memory assetVaults = hook.getVaultsForAsset(address(token0));
        assertEq(assetVaults.length, 2);
    }

    function testGetPoolStats() public {
        hook.addVault(address(vault1), 100, 50);
        
        address[] memory vaults = new address[](1);
        vaults[0] = address(vault1);
        hook.addVaultsToPool(poolId, vaults);
        hook.setPoolRoutingStrategy(poolId, VaultRouter.RoutingStrategy.HIGHEST_YIELD);
        
        // Perform a swap to increment counter
        uint256 amountIn = 1e18;
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
        
        (uint256 swapsProcessed, VaultRouter.RoutingStrategy strategy, uint256 vaultCount) = 
            hook.getPoolStats(poolId);
        
        assertEq(swapsProcessed, 1);
        assertEq(uint256(strategy), uint256(VaultRouter.RoutingStrategy.HIGHEST_YIELD));
        assertEq(vaultCount, 1);
    }

    function testDefaultRoutingStrategy() public view {
        // When pool is initialized, it should have default strategy
        assertEq(uint256(hook.poolRoutingStrategy(poolId)), uint256(VaultRouter.RoutingStrategy.MANUAL_PRIORITY));
    }

    function testBalancedStrategy() public {
        // Set different yields and risk scores
        vault1.setMockYield(0.08e18); // 8% yield, risk 50
        vault2.setMockYield(0.12e18); // 12% yield, risk 80  
        vault3.setMockYield(0.04e18); // 4% yield, risk 20
        
        hook.addVault(address(vault1), 100, 50);
        hook.addVault(address(vault2), 100, 80);
        hook.addVault(address(vault3), 100, 20);
        
        address[] memory vaults = new address[](3);
        vaults[0] = address(vault1);
        vaults[1] = address(vault2);
        vaults[2] = address(vault3);
        
        hook.addVaultsToPool(poolId, vaults);
        hook.setPoolRoutingStrategy(poolId, VaultRouter.RoutingStrategy.BALANCED);
        
        address optimal = hook.getOptimalVault(poolId, address(token0), 1e18);
        // vault3 should win with 4% yield / 20 risk = 0.2 balance score
        // vs vault1: 8% / 50 = 0.16 and vault2: 12% / 80 = 0.15
        assertEq(optimal, address(vault3));
    }

    // Test edge cases
    function testNoVaultsAvailable() public {
        hook.setPoolRoutingStrategy(poolId, VaultRouter.RoutingStrategy.HIGHEST_YIELD);
        
        vm.expectRevert("No vaults available");
        hook.getOptimalVault(poolId, address(token0), 1e18);
    }

    function testAddVaultToPoolInactive() public {
        hook.addVault(address(vault1), 100, 50);
        hook.removeVault(address(vault1));
        
        address[] memory vaults = new address[](1);
        vaults[0] = address(vault1);
        
        vm.expectRevert("Vault not active");
        hook.addVaultsToPool(poolId, vaults);
    }

    function testTwoStepRouteWithReceiverHook() public {
        // Add vault and allow routing
        hook.addVault(address(vault1), 100, 50);
        address[] memory vaults = new address[](1);
        vaults[0] = address(vault1);
        hook.addVaultsToPool(poolId, vaults);

        // Also add a token1 vault to avoid beforeSwap reverting due to no available vaults for assetIn (token1)
        MockVault vaultToken1 = new MockVault(IERC20(address(token1)), "VaultT1", "VT1", 0);
        hook.addVault(address(vaultToken1), 1, 50);
        address[] memory vaultsT1 = new address[](1);
        vaultsT1[0] = address(vaultToken1);
        hook.addVaultsToPool(poolId, vaultsT1);

        uint256 amountIn = 1e18;

        // Swap token1 -> token0 and deliver token0 to the hook (receiver)
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(hook),
            deadline: block.timestamp + 1
        });

        // Deposit the held token0 from the hook into the optimal vault; shares to this test contract
        uint256 assetsBefore = vault1.totalAssets();
        (address usedVault, uint256 assets, uint256 shares) = hook.depositHeldToVault(
            poolId,
            address(token0),
            address(this),
            0,
            address(0)
        );
        assertEq(usedVault, address(vault1));
        assertGt(assets, 0);
        assertLe(assets, amountIn);
        assertGt(shares, 0);

        // Mock vault reports totalAssets with +5% yield
        uint256 assetsAfter = vault1.totalAssets();
        assertEq(assetsAfter, assetsBefore + assets + ((assets * 5e16) / 1e18));
    }

    function testDepositHeldToVault_ForcedVaultAndMinShares() public {
        // Add multiple vaults; force selection to vault2
        hook.addVault(address(vault1), 100, 50);
        hook.addVault(address(vault2), 200, 30);
        address[] memory vaults = new address[](2);
        vaults[0] = address(vault1);
        vaults[1] = address(vault2);
        hook.addVaultsToPool(poolId, vaults);

        // Prefund hook with token0 directly
        uint256 depositAssets = 2e18;
        token0.mint(address(hook), depositAssets);

        // Expect deposit succeeds with minShares set conservatively (<= ~assets/1.1 due to 10% mock yield)
        uint256 sharesMin = (depositAssets * 9) / 10;
        uint256 startShares = ERC20(address(vault2)).balanceOf(address(this));
        (address usedVault, uint256 assets, uint256 shares) = hook.depositHeldToVault(
            poolId,
            address(token0),
            address(this),
            sharesMin,
            address(vault2)
        );

        assertEq(usedVault, address(vault2));
        assertEq(assets, depositAssets);
        assertGe(shares, sharesMin);
        uint256 endShares = ERC20(address(vault2)).balanceOf(address(this));
        assertEq(endShares - startShares, shares);
    }

    function testDepositHeldToVault_NoAssetsRevert() public {
        // Add a vault and attempt deposit with zero balance
        hook.addVault(address(vault1), 100, 50);
        address[] memory vaults = new address[](1);
        vaults[0] = address(vault1);
        hook.addVaultsToPool(poolId, vaults);

        vm.expectRevert(bytes("No assets to deposit"));
        hook.depositHeldToVault(poolId, address(token0), address(this), 0, address(0));
    }

    function testAfterSwapMintsSharesToReceiverFromHookData() public {
        // Prepare vault for token0 (assetOut when swapping token1 -> token0)
        hook.addVault(address(vault1), 100, 50);
        address[] memory vaults = new address[](1);
        vaults[0] = address(vault1);
        hook.addVaultsToPool(poolId, vaults);

        // Share receiver will be this contract; force vault1 to avoid strategy variance
        address shareReceiver = address(this);
        bytes memory hookData = abi.encode(shareReceiver, address(vault1), uint256(0));

        uint256 startShares = ERC20(address(vault1)).balanceOf(shareReceiver);

        // Perform swap token1 -> token0 to the hook so the hook can deposit
        uint256 amountIn = 1e18;
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: poolKey,
            hookData: hookData,
            receiver: address(hook),
            deadline: block.timestamp + 1
        });

        // After swap, the hook holds the output tokens; deposit them into the forced vault
        (address usedVault, uint256 assets, uint256 shares) = hook.depositHeldToVault(
            poolId,
            address(token0),
            shareReceiver,
            0,
            address(vault1)
        );
        assertEq(usedVault, address(vault1));
        assertGt(assets, 0);
        assertGt(shares, 0);

        uint256 endShares = ERC20(address(vault1)).balanceOf(shareReceiver);
        assertGt(endShares, startShares);
    }
}