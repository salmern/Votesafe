# VoteSafe 🗳️

**VoteSafe** is a decentralized DAO voting protocol designed for **fairer, safer, and more inclusive governance**. It leverages:

- 🧠 Quadratic voting to prevent whale dominance
- 🕒 Timelock-controlled execution for security and transparency
- 🌐 Snapshot.js for off-chain vote collection
- 🗂️ IPFS for decentralized proposal storage
- ⚙️ Foundry for robust testing

---

## 🧰 Tech Stack

- **Solidity** (Smart contracts)
- **Foundry** (Development & testing)
- **Snapshot.js** (Off-chain voting)
- **React** (Frontend dashboard - coming soon)
- **IPFS** (Proposal content storage)
- **Sepolia Testnet** (Deployment & testing)

---

## ✨ Features

- 🪙 `ERC20Votes`-based governance token
- 📦 Proposals stored off-chain on IPFS
- ✅ Off-chain quadratic voting, on-chain execution
- 🚨 Emergency proposal mechanism
- 🔐 Role-based TimelockController
- 🧪 Comprehensive tests using Foundry

---

## 🛠️ Getting Started

Clone and install dependencies:

```bash
forge install
forge build
forge test --gas-report
