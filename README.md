# Mon Precog

A Monad prediction-market prototype with a beginner guide and the Monad Bounce mini-game.

## Smart contracts

`contracts/Precog.sol` combines a native-MON binary prediction market and an on-chain game-round registry. Deploying one contract enables both features:

- A market creator deposits initial MON liquidity, posts a question and close time, and is responsible for resolving the market after it closes.
- Traders buy YES or NO shares with MON. Quotes use a constant-product pool and include a 0.3% fee and caller-specified minimum shares for slippage protection.
- Winning shares redeem 1 MON per share. If the creator resolves a market as invalid, each YES/NO share redeems for half a MON. The creator can separately redeem winning shares held in the pool.
- `startGameRound()` records a player's round number and emits an event. It charges no game fee; each transaction still costs Monad network gas.

Market resolution is creator-controlled, not provided by an oracle. Only create or trade markets whose resolver you trust. This is prototype code and has not had an independent security audit. Use testnet only until the contract and resolution design have been reviewed.

### Install and test

Requires Node.js 20 or newer.

```powershell
npm install
npm test
npm run compile
```

### Deploy to Monad Testnet

1. Copy `.env.example` to `.env` and set `DEPLOYER_PRIVATE_KEY` to a dedicated testnet wallet key. Never use a mainnet key or commit `.env`.
2. Fund that wallet with testnet MON and verify the account and RPC URL.
3. Run `npm run deploy:monad-testnet`.
4. Save the printed contract address and verify it on [Monad Testnet Explorer](https://testnet.monadvision.com/).

The current static website still runs trades locally and does not call the deployed prediction contract. Configure and review the deployed address and frontend ABI integration before presenting any market action as on-chain.
