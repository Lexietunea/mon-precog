const { expect } = require('chai');
const { ethers } = require('hardhat');

describe('Precog', function () {
  let precog;
  let creator;
  let trader;
  let other;
  let marketId;
  let closesAt;
  const seed = ethers.parseEther('1');

  async function createTestMarket() {
    const now = (await ethers.provider.getBlock('latest')).timestamp;
    closesAt = now + 3600;
    const tx = await precog.connect(creator).createMarket('Will Monad test activity pass 1,000?', closesAt, { value: seed });
    const receipt = await tx.wait();
    const event = receipt.logs.map(log => {
      try { return precog.interface.parseLog(log); } catch { return null; }
    }).find(parsed => parsed?.name === 'MarketCreated');
    marketId = event.args.marketId;
  }

  async function closeMarket() {
    await ethers.provider.send('evm_increaseTime', [3601]);
    await ethers.provider.send('evm_mine');
  }

  beforeEach(async function () {
    [creator, trader, other] = await ethers.getSigners();
    const Precog = await ethers.getContractFactory('Precog', creator);
    precog = await Precog.deploy();
    await precog.waitForDeployment();
    await createTestMarket();
  });

  it('creates funded markets with a balanced starting pool', async function () {
    const market = await precog.getMarket(marketId);
    expect(market.creator).to.equal(creator.address);
    expect(market.yesReserve).to.equal(seed);
    expect(market.noReserve).to.equal(seed);
    expect(market.collateral).to.equal(seed);
    expect(market.result).to.equal(0);
  });

  it('records each game start on-chain without requiring game stake', async function () {
    await expect(precog.connect(trader).startGameRound())
      .to.emit(precog, 'GameRoundStarted')
      .withArgs(trader.address, 1, await ethers.provider.getBlockNumber() + 1);
    await precog.connect(trader).startGameRound();
    expect(await precog.gameRoundsStarted(trader.address)).to.equal(2);
    await expect(precog.connect(trader).startGameRound({ value: 1 })).to.be.reverted;
  });

  it('quotes and buys YES shares while preserving collateral accounting', async function () {
    const amount = ethers.parseEther('0.1');
    const [quotedShares] = await precog.quoteBuy(marketId, true, amount);
    await expect(precog.connect(trader).buy(marketId, true, quotedShares, { value: amount }))
      .to.emit(precog, 'SharesBought')
      .withArgs(marketId, trader.address, true, amount, quotedShares);
    expect(await precog.yesShares(marketId, trader.address)).to.equal(quotedShares);
    expect((await precog.getMarket(marketId)).collateral).to.equal(seed + amount);
  });

  it('rejects buys with insufficient slippage protection or after close', async function () {
    const amount = ethers.parseEther('0.1');
    await expect(precog.connect(trader).buy(marketId, true, ethers.MaxUint256, { value: amount }))
      .to.be.revertedWithCustomError(precog, 'SlippageExceeded');
    await closeMarket();
    await expect(precog.connect(trader).buy(marketId, false, 0, { value: amount }))
      .to.be.revertedWithCustomError(precog, 'MarketClosed');
  });

  it('allows only the market creator to resolve it after close', async function () {
    await expect(precog.connect(other).resolveMarket(marketId, 1))
      .to.be.revertedWithCustomError(precog, 'Unauthorized');
    await expect(precog.connect(creator).resolveMarket(marketId, 1))
      .to.be.revertedWithCustomError(precog, 'MarketStillOpen');
    await closeMarket();
    await expect(precog.connect(creator).resolveMarket(marketId, 0))
      .to.be.revertedWithCustomError(precog, 'InvalidResolution');
    await expect(precog.connect(creator).resolveMarket(marketId, 1))
      .to.emit(precog, 'MarketResolved');
  });

  it('pays YES winners and lets the creator redeem winning pool inventory', async function () {
    const amount = ethers.parseEther('0.1');
    await precog.connect(trader).buy(marketId, true, 0, { value: amount });
    const userShares = await precog.yesShares(marketId, trader.address);
    const poolShares = (await precog.getMarket(marketId)).yesReserve;
    await closeMarket();
    await precog.connect(creator).resolveMarket(marketId, 1);

    await expect(precog.connect(other).claim(marketId))
      .to.be.revertedWithCustomError(precog, 'NothingToClaim');
    await expect(precog.connect(trader).claim(marketId))
      .to.changeEtherBalance(trader, userShares);
    await expect(precog.connect(creator).claimLiquidity(marketId))
      .to.changeEtherBalance(creator, poolShares);
    expect((await precog.getMarket(marketId)).collateral).to.equal(0);
  });

  it('refunds both sides at half value for an invalid market', async function () {
    const amount = ethers.parseEther('0.1');
    await precog.connect(trader).buy(marketId, true, 0, { value: amount });
    const userYes = await precog.yesShares(marketId, trader.address);
    const market = await precog.getMarket(marketId);
    const expectedTraderRefund = userYes / 2n;
    const expectedCreatorRefund = (market.yesReserve + market.noReserve) / 2n;
    await closeMarket();
    await precog.connect(creator).resolveMarket(marketId, 3);

    await expect(precog.connect(trader).claim(marketId))
      .to.changeEtherBalance(trader, expectedTraderRefund);
    await expect(precog.connect(creator).claimLiquidity(marketId))
      .to.changeEtherBalance(creator, expectedCreatorRefund);
    expect((await precog.getMarket(marketId)).collateral).to.equal(0);
  });

  it('rejects direct MON transfers and prevents duplicate claims', async function () {
    await expect(trader.sendTransaction({ to: await precog.getAddress(), value: 1 }))
      .to.be.revertedWithCustomError(precog, 'DirectPaymentDisabled');
    await expect(precog.connect(trader).claim(marketId))
      .to.be.revertedWithCustomError(precog, 'MarketStillOpen');
  });
});