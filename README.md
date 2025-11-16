# 2025-11-alignerz
- Join [Dualguard](https://discord.gg/UxrgEnbY) Discord
- Submit findings using the Issues page in your private contest repo (label issues as Gas, Info, Low, Medium or High)
- for more details, read the github channel: guidelines

# Q&A
### Q: On what chains are the smart contracts going to be deployed?
Polygon, Arbitrum, MegaETH

### Q: If you are integrating tokens, are you allowing only whitelisted tokens to work with the codebase or any complying with the standard? Are they assumed to have certain properties, e.g. be non-reentrant? Are there any types of weird tokens you want to integrate?
Protocol only supports standard tokens with 18 decimals, no weird tokens. 6 decimals tokens are used for the 2 stablecoins that will be used for bidding (USDT and USDC)

### Q: Are there any limitations on values set by admins (or other roles) in the codebase, including restrictions on array lengths?
Admin is fully trusted

### Q: Are there any limitations on values set by admins (or other roles) in protocols you integrate with, including restrictions on array lengths?
Nothing that is not mentioned in the codebase

### Q: Is the codebase expected to comply with any specific EIPs?
No

### Q: Are there any off-chain mechanisms involved in the protocol (e.g., keeper bots, arbitrage bots, etc.)? We assume these mechanisms will not misbehave, delay, or go offline unless otherwise specified.
There's a backend that generates the merkleproofs for refunds and TVS claims

### Q: What properties/invariants do you want to hold even if breaking them has a low/unknown impact?
N/A

### Q: Please discuss any design choices you made.
I decided to keep the assignedPoolId attribute in the rewardProject struct even if it has no use case, it will always be equal to 0 and that was made for practicality.

### Q: Please provide links to previous audits (if any) and all the known issues or acceptable risks.
[ShawarmaSec Audit](https://github.com/shawarma-sec/audits/blob/main/final-report-shawarmasec-alignerz.pdf)
Known issues: Will soon be provided for you

### Q: Please list any relevant protocol resources.
[Whitepaper](https://drive.google.com/file/d/1xN5bYUPd_BkBMtoRruHEO1CBUx0vBiit/)

# Audit Scope
![Scope](scope.jpg)
