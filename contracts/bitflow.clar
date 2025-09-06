;; Title: BitFlow Protocol - Advanced AMM & Liquidity Infrastructure
;;
;; Summary: A sophisticated, capital-efficient Automated Market Maker (AMM) protocol 
;; engineered for Stacks Layer 2, delivering institutional-grade DeFi primitives 
;; secured by Bitcoin's robust consensus layer.

;; TRAIT DEFINITIONS

(define-trait ft-trait
    (
        (transfer (uint principal principal (optional (buff 34))) (response bool uint))
        (get-balance (principal) (response uint uint))
        (get-total-supply () (response uint uint))
    )
)

(define-trait flash-loan-callback-trait
    (
        (execute-flash-swap (uint uint) (response bool uint))
    )
)

;; ERROR CONSTANTS

(define-constant ERR-NOT-AUTHORIZED (err u1000))
(define-constant ERR-INSUFFICIENT-BALANCE (err u1001))
(define-constant ERR-POOL-ALREADY-EXISTS (err u1002))
(define-constant ERR-POOL-NOT-FOUND (err u1003))
(define-constant ERR-INVALID-PAIR (err u1004))
(define-constant ERR-ZERO-LIQUIDITY (err u1005))
(define-constant ERR-PRICE-IMPACT-HIGH (err u1006))
(define-constant ERR-EXPIRED (err u1007))
(define-constant ERR-MIN-TOKENS (err u1008))
(define-constant ERR-FLASH-LOAN-FAILED (err u1009))
(define-constant ERR-ORACLE-STALE (err u1010))
(define-constant ERR-SLIPPAGE-TOO-HIGH (err u1011))
(define-constant ERR-EMERGENCY-SHUTDOWN (err u1015))

;; PROTOCOL CONSTANTS

(define-constant CONTRACT-OWNER tx-sender)
(define-constant FEE-DENOMINATOR u10000)
(define-constant INITIAL-LIQUIDITY-TOKENS u1000)
(define-constant MAX-PRICE-IMPACT u200)
(define-constant MIN-LIQUIDITY u1000000)
(define-constant FLASH-LOAN-FEE u10)
(define-constant ORACLE-VALIDITY-PERIOD u150)
(define-constant REWARD-MULTIPLIER u100)
(define-constant DEFAULT-FEE-RATE u30)

;; STATE VARIABLES

(define-data-var next-pool-id uint u0)
(define-data-var next-loan-id uint u0)
(define-data-var total-fees-collected uint u0)
(define-data-var protocol-fee-rate uint u50)
(define-data-var emergency-shutdown bool false)
(define-data-var governance-token (optional principal) none)

;; DATA MAPS

(define-map pools 
    { pool-id: uint }
    {
        token-x: principal,
        token-y: principal,
        reserve-x: uint,
        reserve-y: uint,
        total-supply: uint,
        fee-rate: uint,
        last-block: uint,
        price-cumulative-last: uint,
        price-timestamp: uint,
        twap: uint
    }
)

(define-map liquidity-providers
    { pool-id: uint, provider: principal }
    {
        shares: uint,
        staked-amount: uint,
        last-stake-block: uint
    }
)

(define-map governance-stakes
    { staker: principal }
    {
        amount: uint,
        power: uint,
        lock-until: uint,
        delegation: (optional principal)
    }
)

(define-map flash-loans
    { loan-id: uint }
    {
        borrower: principal,
        amount: uint,
        token: principal,
        due-block: uint
    }
)

(define-map yield-farms
    { pool-id: uint }
    {
        reward-token: principal,
        reward-per-block: uint,
        total-staked: uint,
        last-reward-block: uint,
        accumulated-reward-per-share: uint
    }
)

;; UTILITY FUNCTIONS

(define-private (min (a uint) (b uint))
    (if (<= a b) a b)
)

(define-private (calculate-liquidity-shares (amount-x uint) (amount-y uint) (reserve-x uint) (reserve-y uint) (total-supply uint))
    (if (is-eq total-supply u0)
        INITIAL-LIQUIDITY-TOKENS
        (min
            (/ (* amount-x total-supply) reserve-x)
            (/ (* amount-y total-supply) reserve-y)
        )
    )
)

(define-private (check-price-impact (amount uint) (reserve uint))
    (<= (/ (* amount u10000) reserve) MAX-PRICE-IMPACT)
)

;; READ-ONLY FUNCTIONS

(define-read-only (get-pool-details (pool-id uint))
    (ok (unwrap! (map-get? pools { pool-id: pool-id }) ERR-POOL-NOT-FOUND))
)

(define-read-only (get-twap-price (pool-id uint))
    (match (map-get? pools { pool-id: pool-id })
        pool-info 
        (if (>= (- stacks-block-height (get price-timestamp pool-info)) ORACLE-VALIDITY-PERIOD)
            (err ERR-ORACLE-STALE)
            (ok (get twap pool-info))
        )
        (err ERR-POOL-NOT-FOUND)
    )
)

(define-read-only (calculate-swap-output (pool-id uint) (input-amount uint) (is-x-to-y bool))
    (match (map-get? pools { pool-id: pool-id })
        pool-info 
        (let (
            (reserve-in (if is-x-to-y (get reserve-x pool-info) (get reserve-y pool-info)))
            (reserve-out (if is-x-to-y (get reserve-y pool-info) (get reserve-x pool-info)))
            (fee-adjustment (- FEE-DENOMINATOR (get fee-rate pool-info)))
        )
            (ok {
                output: (/ (* input-amount (* reserve-out fee-adjustment)) 
                          (+ (* reserve-in FEE-DENOMINATOR) (* input-amount fee-adjustment))),
                fee: (/ (* input-amount (get fee-rate pool-info)) FEE-DENOMINATOR)
            })
        )
        (err ERR-POOL-NOT-FOUND)
    )
)

(define-read-only (get-provider-info (pool-id uint) (provider principal))
    (ok (unwrap! (map-get? liquidity-providers { pool-id: pool-id, provider: provider }) ERR-NOT-AUTHORIZED))
)

(define-read-only (get-governance-token)
    (ok (var-get governance-token))
)

;; POOL MANAGEMENT FUNCTIONS

(define-public (create-pool (token-x <ft-trait>) (token-y <ft-trait>) (initial-x uint) (initial-y uint))
    (let (
        (pool-id (var-get next-pool-id))
        (token-x-principal (contract-of token-x))
        (token-y-principal (contract-of token-y))
    )
        (asserts! (not (var-get emergency-shutdown)) ERR-EMERGENCY-SHUTDOWN)
        (asserts! (not (is-eq token-x-principal token-y-principal)) ERR-INVALID-PAIR)
        (asserts! (and (> initial-x u0) (> initial-y u0)) ERR-ZERO-LIQUIDITY)
        
        (try! (contract-call? token-x transfer initial-x tx-sender (as-contract tx-sender) none))
        (try! (contract-call? token-y transfer initial-y tx-sender (as-contract tx-sender) none))
        
        (map-set pools 
            { pool-id: pool-id }
            {
                token-x: token-x-principal,
                token-y: token-y-principal,
                reserve-x: initial-x,
                reserve-y: initial-y,
                total-supply: INITIAL-LIQUIDITY-TOKENS,
                fee-rate: DEFAULT-FEE-RATE,
                last-block: stacks-block-height,
                price-cumulative-last: u0,
                price-timestamp: stacks-block-height,
                twap: u0
            }
        )
        
        (map-set liquidity-providers
            { pool-id: pool-id, provider: tx-sender }
            {
                shares: INITIAL-LIQUIDITY-TOKENS,
                staked-amount: u0,
                last-stake-block: stacks-block-height
            }
        )
        
        (var-set next-pool-id (+ pool-id u1))
        (ok pool-id)
    )
)

(define-public (add-liquidity (pool-id uint) (token-x <ft-trait>) (token-y <ft-trait>) (amount-x uint) (amount-y uint) (min-shares uint))
    (let (
        (pool (unwrap! (map-get? pools { pool-id: pool-id }) ERR-POOL-NOT-FOUND))
        (shares-to-mint (calculate-liquidity-shares amount-x amount-y (get reserve-x pool) (get reserve-y pool) (get total-supply pool)))
    )
        (asserts! (not (var-get emergency-shutdown)) ERR-EMERGENCY-SHUTDOWN)
        (asserts! (is-eq (contract-of token-x) (get token-x pool)) ERR-INVALID-PAIR)
        (asserts! (is-eq (contract-of token-y) (get token-y pool)) ERR-INVALID-PAIR)
        (asserts! (>= shares-to-mint min-shares) ERR-MIN-TOKENS)
        
        (try! (contract-call? token-x transfer amount-x tx-sender (as-contract tx-sender) none))
        (try! (contract-call? token-y transfer amount-y tx-sender (as-contract tx-sender) none))
        
        (map-set pools
            { pool-id: pool-id }
            (merge pool {
                reserve-x: (+ (get reserve-x pool) amount-x),
                reserve-y: (+ (get reserve-y pool) amount-y),
                total-supply: (+ (get total-supply pool) shares-to-mint)
            })
        )
        
        (match (map-get? liquidity-providers { pool-id: pool-id, provider: tx-sender })
            prev-balance
            (map-set liquidity-providers
                { pool-id: pool-id, provider: tx-sender }
                (merge prev-balance {
                    shares: (+ (get shares prev-balance) shares-to-mint)
                })
            )
            (map-set liquidity-providers
                { pool-id: pool-id, provider: tx-sender }
                {
                    shares: shares-to-mint,
                    staked-amount: u0,
                    last-stake-block: stacks-block-height
                }
            )
        )
        
        (ok shares-to-mint)
    )
)

;; TRADING FUNCTIONS

(define-public (swap-exact-x-for-y (pool-id uint) (token-x <ft-trait>) (token-y <ft-trait>) (amount-x uint) (min-y uint))
    (let (
        (pool (unwrap! (map-get? pools { pool-id: pool-id }) ERR-POOL-NOT-FOUND))
        (swap-output (unwrap! (calculate-swap-output pool-id amount-x true) ERR-POOL-NOT-FOUND))
        (output-amount (get output swap-output))
        (fee-amount (get fee swap-output))
    )
        (asserts! (not (var-get emergency-shutdown)) ERR-EMERGENCY-SHUTDOWN)
        (asserts! (is-eq (contract-of token-x) (get token-x pool)) ERR-INVALID-PAIR)
        (asserts! (is-eq (contract-of token-y) (get token-y pool)) ERR-INVALID-PAIR)
        (asserts! (>= output-amount min-y) ERR-MIN-TOKENS)
        (asserts! (check-price-impact amount-x (get reserve-x pool)) ERR-PRICE-IMPACT-HIGH)
        
        (try! (contract-call? token-x transfer amount-x tx-sender (as-contract tx-sender) none))
        (try! (as-contract (contract-call? token-y transfer output-amount (as-contract tx-sender) tx-sender none)))
        
        (map-set pools
            { pool-id: pool-id }
            (merge pool {
                reserve-x: (+ (get reserve-x pool) amount-x),
                reserve-y: (- (get reserve-y pool) output-amount),
                last-block: stacks-block-height
            })
        )
        
        (var-set total-fees-collected (+ (var-get total-fees-collected) fee-amount))
        (ok output-amount)
    )
)

;; FLASH LOAN SYSTEM

(define-public (flash-swap (pool-id uint) (token-x <ft-trait>) (token-y <ft-trait>) (amount-x uint) (callback-contract <flash-loan-callback-trait>))
    (let (
        (pool (unwrap! (map-get? pools { pool-id: pool-id }) ERR-POOL-NOT-FOUND))
        (loan-id (var-get next-loan-id))
        (fee (/ (* amount-x FLASH-LOAN-FEE) FEE-DENOMINATOR))
    )
        (asserts! (not (var-get emergency-shutdown)) ERR-EMERGENCY-SHUTDOWN)
        (asserts! (is-eq (contract-of token-x) (get token-x pool)) ERR-INVALID-PAIR)
        (asserts! (is-eq (contract-of token-y) (get token-y pool)) ERR-INVALID-PAIR)
        
        (map-set flash-loans
            { loan-id: loan-id }
            {
                borrower: tx-sender,
                amount: amount-x,
                token: (contract-of token-x),
                due-block: (+ stacks-block-height u1)
            }
        )
        
        (try! (as-contract (contract-call? token-x transfer 
            amount-x 
            (as-contract tx-sender) 
            tx-sender 
            none)))
        
        (try! (contract-call? callback-contract execute-flash-swap loan-id pool-id))
        
        (let ((updated-pool (unwrap! (map-get? pools { pool-id: pool-id }) ERR-POOL-NOT-FOUND)))
            (asserts! (>= (get reserve-x updated-pool) (+ (get reserve-x pool) fee)) ERR-FLASH-LOAN-FAILED)
            
            (var-set next-loan-id (+ loan-id u1))
            (var-set total-fees-collected (+ (var-get total-fees-collected) fee))
            (ok loan-id)
        )
    )
)

;; YIELD FARMING SYSTEM

(define-public (create-farm (pool-id uint) (reward-token principal) (reward-rate uint))
    (begin
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
        (map-set yield-farms
            { pool-id: pool-id }
            {
                reward-token: reward-token,
                reward-per-block: reward-rate,
                total-staked: u0,
                last-reward-block: stacks-block-height,
                accumulated-reward-per-share: u0
            }
        )
        (ok true)
    )
)

(define-public (stake-in-farm (pool-id uint) (amount uint))
    (let (
        (provider-info (unwrap! (map-get? liquidity-providers { pool-id: pool-id, provider: tx-sender }) ERR-NOT-AUTHORIZED))
        (farm (unwrap! (map-get? yield-farms { pool-id: pool-id }) ERR-POOL-NOT-FOUND))
    )
        (map-set liquidity-providers
            { pool-id: pool-id, provider: tx-sender }
            (merge provider-info {
                staked-amount: (+ (get staked-amount provider-info) amount),
                last-stake-block: stacks-block-height
            })
        )
        
        (map-set yield-farms
            { pool-id: pool-id }
            (merge farm {
                total-staked: (+ (get total-staked farm) amount)
            })
        )
        
        (ok true)
    )
)

;; GOVERNANCE SYSTEM

(define-public (set-governance-token (token principal))
    (begin
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
        (ok (var-set governance-token (some token)))
    )
)

(define-public (stake-governance (token <ft-trait>) (amount uint) (lock-blocks uint))
    (let (
        (current-stake (default-to 
            {
                amount: u0, 
                power: u0, 
                lock-until: u0, 
                delegation: none
            } 
            (map-get? governance-stakes { staker: tx-sender })
        ))
        (gov-token (unwrap! (var-get governance-token) ERR-NOT-AUTHORIZED))
        (power (* amount (+ u1 (/ lock-blocks u1000))))
    )
        (asserts! (is-eq (contract-of token) gov-token) ERR-NOT-AUTHORIZED)
        
        (try! (contract-call? token transfer amount tx-sender (as-contract tx-sender) none))
        
        (map-set governance-stakes
            { staker: tx-sender }
            {
                amount: (+ (get amount current-stake) amount),
                power: (+ (get power current-stake) power),
                lock-until: (+ stacks-block-height lock-blocks),
                delegation: (get delegation current-stake)
            }
        )
        
        (ok power)
    )
)

(define-public (delegate-votes (delegate-to principal))
    (let (
        (current-stake (unwrap! (map-get? governance-stakes { staker: tx-sender }) ERR-NOT-AUTHORIZED))
    )
        (map-set governance-stakes
            { staker: tx-sender }
            (merge current-stake {
                delegation: (some delegate-to)
            })
        )
        
        (ok true)
    )
)

;; PRICE ORACLE SYSTEM

(define-public (update-price-oracle (pool-id uint))
    (let (
        (pool (unwrap! (map-get? pools { pool-id: pool-id }) ERR-POOL-NOT-FOUND))
        (time-elapsed (- stacks-block-height (get price-timestamp pool)))
        (price-cumulative (* (/ (get reserve-y pool) (get reserve-x pool)) time-elapsed))
    )
        (asserts! (< pool-id (var-get next-pool-id)) ERR-POOL-NOT-FOUND)
        (asserts! (> time-elapsed u0) ERR-ORACLE-STALE)
        (asserts! (> (get reserve-x pool) u0) ERR-ZERO-LIQUIDITY)
        
        (map-set pools
            { pool-id: pool-id }
            (merge pool {
                price-cumulative-last: (+ (get price-cumulative-last pool) price-cumulative),
                price-timestamp: stacks-block-height,
                twap: (/ price-cumulative time-elapsed)
            })
        )
        
        (ok true)
    )
)

;; ADMIN FUNCTIONS

(define-public (toggle-emergency-shutdown)
    (begin
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
        (ok (var-set emergency-shutdown (not (var-get emergency-shutdown))))
    )
)

(define-public (set-protocol-fee (new-fee uint))
    (begin
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
        (asserts! (<= new-fee u1000) ERR-NOT-AUTHORIZED)
        (ok (var-set protocol-fee-rate new-fee))
    )
)