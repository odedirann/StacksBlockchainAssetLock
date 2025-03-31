;; StacksBlockchainSecurity: An advanced blockchain asset lock system with conditional release mechanisms
;; This Clarity 2.0 smart contract enables secure blockchain asset storage and managed release
;; through milestone verification, temporal controls, and multiple security protocols.

;; Administrative constants
(define-constant ADMIN_PRINCIPAL tx-sender)
(define-constant ERR_PERMISSION_DENIED (err u200))
(define-constant ERR_ASSET_BOX_MISSING (err u201))
(define-constant ERR_ASSETS_RELEASED (err u202))
(define-constant ERR_TRANSACTION_REJECTED (err u203))
(define-constant ERR_INVALID_BOX_ID (err u204))
(define-constant ERR_INVALID_VALUE (err u205))
(define-constant ERR_INVALID_MILESTONE (err u206))
(define-constant ERR_BOX_EXPIRATION (err u207))
(define-constant BOX_DEFAULT_DURATION u1008)

;; Supplementary error definitions
(define-constant ERR_ALREADY_EXPIRED (err u208))
(define-constant ERR_EMERGENCY_MISSING (err u209))
(define-constant ERR_MILESTONE_SUBMITTED (err u210))
(define-constant ERR_PROXY_ALREADY_EXISTS (err u211))
(define-constant ERR_BATCH_OPERATION_FAILED (err u212))
(define-constant ERR_TRANSACTION_LIMIT (err u213))
(define-constant ERR_SECURITY_FLAG (err u215))
(define-constant ERR_DUPLICATE_CHALLENGE (err u236))
(define-constant ERR_CHALLENGE_PERIOD_ENDED (err u237))

;; Security parameters
(define-constant SECURITY_PERIOD u720) 
(define-constant ERR_SECURITY_ACTIVE (err u222))
(define-constant ERR_SECURITY_PERIOD (err u223))
(define-constant MAX_RECIPIENTS u5)
(define-constant ERR_RECIPIENT_MAX (err u224))
(define-constant ERR_DISTRIBUTION_INCORRECT (err u225))
(define-constant MAX_TIME_EXTENSION u1008) 
(define-constant TRANSACTION_PERIOD u144) 
(define-constant MAX_PERIOD_TRANSACTIONS u5)
(define-constant LARGE_TRANSACTION_THRESHOLD u1000000000) 
(define-constant HIGH_FREQUENCY_THRESHOLD u3) 
(define-constant CHALLENGE_WINDOW u1008)
(define-constant CHALLENGE_STAKE u1000000) 

;; Main data storage
(define-map AssetBoxes
  { box-id: uint }
  {
    depositor: principal,
    recipient: principal,
    amount: uint,
    status: (string-ascii 10),
    creation-height: uint,
    deadline-height: uint,
    milestones: (list 5 uint),
    completed-milestones: uint
  }
)

(define-data-var box-id-tracker uint u0)

;; Multi-recipient structure
(define-map MultiBoxes
  { multi-box-id: uint }
  {
    depositor: principal,
    beneficiaries: (list 5 { recipient: principal, allocation: uint }),
    total-amount: uint,
    creation-height: uint,
    status: (string-ascii 10)
  }
)

(define-data-var multi-box-tracker uint u0)

;; Verified recipient registry
(define-map ApprovedRecipients
  { recipient: principal }
  { approved: bool }
)

;; Milestone progress tracking
(define-map MilestoneProgress
  { box-id: uint, milestone-index: uint }
  {
    completion-level: uint,
    description: (string-ascii 200),
    update-height: uint,
    verification-data: (buff 32)
  }
)

;; Control delegation records
(define-map BoxDelegations
  { box-id: uint }
  {
    proxy: principal,
    can-cancel: bool,
    can-extend: bool,
    can-add-funds: bool,
    delegation-expiry: uint
  }
)

;; Security alert registry
(define-map AlertedBoxes
  { box-id: uint }
  { 
    alert-type: (string-ascii 20),
    reporter: principal,
    resolved: bool
  }
)

;; Depositor activity monitoring
(define-map DepositorActivity
  { depositor: principal }
  {
    last-transaction-height: uint,
    period-transactions: uint
  }
)

;; Challenge system
(define-map BoxChallenges
  { box-id: uint }
  {
    challenger: principal,
    challenge-reason: (string-ascii 200),
    stake-amount: uint,
    resolved: bool,
    valid-challenge: bool,
    challenge-height: uint
  }
)

;; Emergency retrieval system
(define-map EmergencyRequests
  { box-id: uint }
  { 
    admin-confirmed: bool,
    depositor-confirmed: bool,
    justification: (string-ascii 100)
  }
)

;; System operations control
(define-data-var system-halted bool false)

;; Utility functions
(define-private (is-valid-recipient (recipient principal))
  (not (is-eq recipient tx-sender))
)

(define-private (is-valid-box-id (box-id uint))
  (<= box-id (var-get box-id-tracker))
)

(define-private (get-allocation-value (beneficiary { recipient: principal, allocation: uint }))
  (get allocation beneficiary)
)

;; Query functions
(define-read-only (is-recipient-approved (recipient principal))
  (default-to false (get approved (map-get? ApprovedRecipients { recipient: recipient })))
)

;; Primary function: Create asset box with milestones
(define-public (create-asset-box (recipient principal) (amount uint) (milestones (list 5 uint)))
  (let
    (
      (box-id (+ (var-get box-id-tracker) u1))
      (deadline-height (+ block-height BOX_DEFAULT_DURATION))
    )
    (asserts! (> amount u0) ERR_INVALID_VALUE)
    (asserts! (is-valid-recipient recipient) ERR_INVALID_MILESTONE)
    (asserts! (> (len milestones) u0) ERR_INVALID_MILESTONE)
    (match (stx-transfer? amount tx-sender (as-contract tx-sender))
      success
        (begin
          (map-set AssetBoxes
            { box-id: box-id }
            {
              depositor: tx-sender,
              recipient: recipient,
              amount: amount,
              status: "active",
              creation-height: block-height,
              deadline-height: deadline-height,
              milestones: milestones,
              completed-milestones: u0
            }
          )
          (var-set box-id-tracker box-id)
          (ok box-id)
        )
      error ERR_TRANSACTION_REJECTED
    )
  )
)

;; Multi-recipient function: Create a shared box with proportional allocations
(define-public (create-multi-recipient-box (beneficiaries (list 5 { recipient: principal, allocation: uint })) (amount uint))
  (begin
    (asserts! (> amount u0) ERR_INVALID_VALUE)
    (asserts! (> (len beneficiaries) u0) ERR_INVALID_BOX_ID)
    (asserts! (<= (len beneficiaries) MAX_RECIPIENTS) ERR_RECIPIENT_MAX)

    ;; Verify allocation totals 100%
    (let
      (
        (total-allocation (fold + (map get-allocation-value beneficiaries) u0))
      )
      (asserts! (is-eq total-allocation u100) ERR_DISTRIBUTION_INCORRECT)

      ;; Process the multi-box creation
      (match (stx-transfer? amount tx-sender (as-contract tx-sender))
        success
          (let
            (
              (multi-box-id (+ (var-get multi-box-tracker) u1))
            )
            (map-set MultiBoxes
              { multi-box-id: multi-box-id }
              {
                depositor: tx-sender,
                beneficiaries: beneficiaries,
                total-amount: amount,
                creation-height: block-height,
                status: "active"
              }
            )
            (var-set multi-box-tracker multi-box-id)
            (ok multi-box-id)
          )
        error ERR_TRANSACTION_REJECTED
      )
    )
  )
)




