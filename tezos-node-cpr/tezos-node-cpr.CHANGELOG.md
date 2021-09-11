## Tezos Node CPR - v0.2 August 2021 (still in draft)
 
### Complete rewrite in bash (no python)
* [x] Ability to force VPN
* [x] Caching of block headers for full "concurrency" during script execution
* [x] Using protocol constants for calculating acceptable delays
* [x] Ability to use external RPC for validatin block height
* [x] Ability to force restart if threshold P2P traffic not met
* [x] More elaborate wrapping into functions
* [x] Better handling of errors in functions
* [x] Simplified logging with more info

### Still needs work
* [ ] Better network checking, e.g. ping retries
* [ ] Caching of protocol constants within block
