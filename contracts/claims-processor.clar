;; Insurance Claims Processor Contract
;; Automated claims processing with damage assessment, fraud detection, and payout approval

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-found (err u101))
(define-constant err-unauthorized (err u102))
(define-constant err-invalid-amount (err u103))
(define-constant err-already-processed (err u104))
(define-constant err-fraud-detected (err u105))
(define-constant err-insufficient-coverage (err u106))
(define-constant err-paused (err u107))
(define-constant err-invalid-status (err u108))

;; Claim status constants
(define-constant status-pending u1)
(define-constant status-assessed u2)
(define-constant status-approved u3)
(define-constant status-rejected u4)
(define-constant status-paid u5)

;; Data Variables
(define-data-var claim-nonce uint u0)
(define-data-var fraud-threshold uint u70) ;; Fraud score threshold (0-100)
(define-data-var max-auto-approval uint u10000) ;; Max amount for auto-approval in micro-units
(define-data-var processing-paused bool false)
(define-data-var total-claims-processed uint u0)
(define-data-var total-payouts uint u0)

;; Data Maps
(define-map claims
    uint
    {
        claimant: principal,
        policy-id: (string-ascii 64),
        claim-amount: uint,
        damage-severity: uint,
        fraud-score: uint,
        status: uint,
        payout-amount: uint,
        coverage-limit: uint,
        deductible: uint,
        timestamp: uint,
        processed-by: (optional principal)
    }
)

(define-map policies
    (string-ascii 64)
    {
        holder: principal,
        coverage-limit: uint,
        deductible: uint,
        active: bool,
        claim-count: uint
    }
)

(define-map claim-history
    principal
    {
        total-claims: uint,
        approved-claims: uint,
        rejected-claims: uint,
        total-received: uint
    }
)

;; Private Functions

(define-private (calculate-payout-internal (claim-amount uint) (deductible uint) (coverage-limit uint))
    (let
        (
            (amount-after-deductible (if (> claim-amount deductible)
                (- claim-amount deductible)
                u0))
        )
        (if (> amount-after-deductible coverage-limit)
            coverage-limit
            amount-after-deductible
        )
    )
)

(define-private (assess-fraud-risk (claimant principal) (claim-amount uint) (damage-severity uint))
    (let
        (
            (history (default-to
                {total-claims: u0, approved-claims: u0, rejected-claims: u0, total-received: u0}
                (map-get? claim-history claimant)))
            (base-score u20)
            (amount-factor (if (> claim-amount u50000) u30 u10))
            (severity-mismatch (if (and (< damage-severity u30) (> claim-amount u20000)) u25 u0))
            (history-factor (if (> (get rejected-claims history) u2) u25 u0))
        )
        (+ (+ (+ base-score amount-factor) severity-mismatch) history-factor)
    )
)

(define-private (update-claim-history (claimant principal) (approved bool) (payout uint))
    (let
        (
            (current-history (default-to
                {total-claims: u0, approved-claims: u0, rejected-claims: u0, total-received: u0}
                (map-get? claim-history claimant)))
        )
        (map-set claim-history claimant
            (merge current-history {
                total-claims: (+ (get total-claims current-history) u1),
                approved-claims: (if approved
                    (+ (get approved-claims current-history) u1)
                    (get approved-claims current-history)),
                rejected-claims: (if approved
                    (get rejected-claims current-history)
                    (+ (get rejected-claims current-history) u1)),
                total-received: (if approved
                    (+ (get total-received current-history) payout)
                    (get total-received current-history))
            })
        )
    )
)

;; Public Functions

(define-public (register-policy (policy-id (string-ascii 64)) (coverage-limit uint) (deductible uint))
    (begin
        (asserts! (not (var-get processing-paused)) err-paused)
        (asserts! (> coverage-limit u0) err-invalid-amount)
        (ok (map-set policies policy-id {
            holder: tx-sender,
            coverage-limit: coverage-limit,
            deductible: deductible,
            active: true,
            claim-count: u0
        }))
    )
)

(define-public (submit-claim (policy-id (string-ascii 64)) (claim-amount uint) (damage-severity uint))
    (let
        (
            (claim-id (+ (var-get claim-nonce) u1))
            (policy (unwrap! (map-get? policies policy-id) err-not-found))
        )
        (asserts! (not (var-get processing-paused)) err-paused)
        (asserts! (is-eq (get holder policy) tx-sender) err-unauthorized)
        (asserts! (get active policy) err-unauthorized)
        (asserts! (> claim-amount u0) err-invalid-amount)
        (asserts! (<= damage-severity u100) err-invalid-amount)
        
        (map-set claims claim-id {
            claimant: tx-sender,
            policy-id: policy-id,
            claim-amount: claim-amount,
            damage-severity: damage-severity,
            fraud-score: u0,
            status: status-pending,
            payout-amount: u0,
            coverage-limit: (get coverage-limit policy),
            deductible: (get deductible policy),
            timestamp: block-height,
            processed-by: none
        })
        
        (map-set policies policy-id (merge policy {
            claim-count: (+ (get claim-count policy) u1)
        }))
        
        (var-set claim-nonce claim-id)
        (ok claim-id)
    )
)

(define-public (assess-claim (claim-id uint))
    (let
        (
            (claim (unwrap! (map-get? claims claim-id) err-not-found))
            (fraud-score (assess-fraud-risk
                (get claimant claim)
                (get claim-amount claim)
                (get damage-severity claim)))
        )
        (asserts! (not (var-get processing-paused)) err-paused)
        (asserts! (is-eq (get status claim) status-pending) err-already-processed)
        
        (map-set claims claim-id (merge claim {
            fraud-score: fraud-score,
            status: status-assessed,
            processed-by: (some tx-sender)
        }))
        
        (ok {assessed: true, fraud-score: fraud-score})
    )
)

(define-public (approve-payout (claim-id uint))
    (let
        (
            (claim (unwrap! (map-get? claims claim-id) err-not-found))
            (payout (calculate-payout-internal
                (get claim-amount claim)
                (get deductible claim)
                (get coverage-limit claim)))
        )
        (asserts! (not (var-get processing-paused)) err-paused)
        (asserts! (is-eq (get status claim) status-assessed) err-invalid-status)
        (asserts! (< (get fraud-score claim) (var-get fraud-threshold)) err-fraud-detected)
        (asserts! (> payout u0) err-invalid-amount)
        
        (map-set claims claim-id (merge claim {
            payout-amount: payout,
            status: status-approved,
            processed-by: (some tx-sender)
        }))
        
        (update-claim-history (get claimant claim) true payout)
        (var-set total-claims-processed (+ (var-get total-claims-processed) u1))
        (var-set total-payouts (+ (var-get total-payouts) payout))
        
        (ok {approved: true, payout: payout})
    )
)

(define-public (reject-claim (claim-id uint) (reason (string-ascii 256)))
    (let
        (
            (claim (unwrap! (map-get? claims claim-id) err-not-found))
        )
        (asserts! (not (var-get processing-paused)) err-paused)
        (asserts! (or
            (is-eq (get status claim) status-pending)
            (is-eq (get status claim) status-assessed)) err-already-processed)
        
        (map-set claims claim-id (merge claim {
            status: status-rejected,
            processed-by: (some tx-sender)
        }))
        
        (update-claim-history (get claimant claim) false u0)
        (var-set total-claims-processed (+ (var-get total-claims-processed) u1))
        
        (ok true)
    )
)

(define-public (mark-claim-paid (claim-id uint))
    (let
        (
            (claim (unwrap! (map-get? claims claim-id) err-not-found))
        )
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (asserts! (is-eq (get status claim) status-approved) err-invalid-status)
        
        (ok (map-set claims claim-id (merge claim {
            status: status-paid
        })))
    )
)

;; Administrative Functions

(define-public (update-fraud-threshold (new-threshold uint))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (asserts! (<= new-threshold u100) err-invalid-amount)
        (ok (var-set fraud-threshold new-threshold))
    )
)

(define-public (set-max-auto-approval (new-max uint))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (ok (var-set max-auto-approval new-max))
    )
)

(define-public (toggle-processing)
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (ok (var-set processing-paused (not (var-get processing-paused))))
    )
)

(define-public (deactivate-policy (policy-id (string-ascii 64)))
    (let
        (
            (policy (unwrap! (map-get? policies policy-id) err-not-found))
        )
        (asserts! (is-eq tx-sender (get holder policy)) err-unauthorized)
        (ok (map-set policies policy-id (merge policy {active: false})))
    )
)

;; Read-Only Functions

(define-read-only (get-claim (claim-id uint))
    (ok (map-get? claims claim-id))
)

(define-read-only (get-claim-status (claim-id uint))
    (ok (get status (unwrap! (map-get? claims claim-id) err-not-found)))
)

(define-read-only (get-policy (policy-id (string-ascii 64)))
    (ok (map-get? policies policy-id))
)

(define-read-only (get-claimant-history (claimant principal))
    (ok (map-get? claim-history claimant))
)

(define-read-only (calculate-payout (claim-amount uint) (deductible uint) (coverage-limit uint))
    (ok (calculate-payout-internal claim-amount deductible coverage-limit))
)

(define-read-only (get-fraud-threshold)
    (ok (var-get fraud-threshold))
)

(define-read-only (get-processing-status)
    (ok (var-get processing-paused))
)

(define-read-only (get-platform-stats)
    (ok {
        total-claims: (var-get claim-nonce),
        total-processed: (var-get total-claims-processed),
        total-payouts: (var-get total-payouts),
        fraud-threshold: (var-get fraud-threshold),
        paused: (var-get processing-paused)
    })
)


;; title: claims-processor
;; version:
;; summary:
;; description:

;; traits
;;

;; token definitions
;;

;; constants
;;

;; data vars
;;

;; data maps
;;

;; public functions
;;

;; read only functions
;;

;; private functions
;;

