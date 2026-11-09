#[dusk_forge::contract(events = [
    GuardianSet,
    GuardianAccepted,
    ServiceUpdated,
    TimelockSet,
    PendingScheduled,
    PendingCancelled,
])]
mod atlas {
    use alloc::collections::BTreeMap;
    use alloc::string::String;

    use dusk_bytes::Serializable;
    use dusk_core::abi::{self, ContractId, block_height};
    use dusk_core::signatures::bls::PublicKey as BlsPublicKey;

    use atlas_encoding::call_types::{
        Account, InitArgs, PendingChange, PendingView, SetServiceArgs,
    };
    use atlas_encoding::events::{
        GuardianAccepted, GuardianSet, PendingCancelled, PendingScheduled, ServiceUpdated,
        TimelockSet,
    };

    /// Per-project registry. One Atlas per deployment. Never upgraded.
    pub struct AtlasState {
        services: BTreeMap<String, ContractId>,
        guardian: Option<Account>,
        /// Blocks to wait before a guardian replacement or a delay change.
        timelock_blocks: u64,
        pending: Option<(PendingChange, u64)>,
        /// The incoming guardian of a pending guardian change has called
        /// `accept_guardian`. Always false for a timelock change.
        pending_accepted: bool,
    }

    impl AtlasState {
        /// 90 days of 10-second Dusk blocks. A larger delay freezes later schedules.
        const MAX_TIMELOCK_BLOCKS: u64 = 777_600;

        pub const fn new() -> Self {
            Self {
                services: BTreeMap::new(),
                guardian: None,
                timelock_blocks: 0,
                pending: None,
                pending_accepted: false,
            }
        }

        /// Deploy-owner bootstrap. Sets the guardian and the initial delay.
        /// Call once, after deploy. The delay applies immediately because no
        /// guardian exists yet.
        ///
        /// Not named `init`: Piecrust reserves that export for the deploy
        /// constructor and rejects later calls to it.
        pub fn init_guardian(&mut self, args: InitArgs) {
            Self::require_deploy_owner();
            if self.guardian.is_some() {
                panic!("atlas already initialized");
            }
            Self::require_timelock(args.timelock_blocks);
            Self::require_usable_account(&args.guardian);
            self.guardian = Some(args.guardian.clone());
            self.timelock_blocks = args.timelock_blocks;
            abi::emit(
                "guardian_set",
                GuardianSet {
                    guardian: args.guardian,
                },
            );
            abi::emit(
                "timelock_set",
                TimelockSet {
                    blocks: args.timelock_blocks,
                },
            );
        }

        pub fn resolve(&self, name: String) -> Option<ContractId> {
            self.services.get(&name).copied()
        }

        pub fn guardian(&self) -> Option<Account> {
            self.guardian.clone()
        }

        pub fn timelock_blocks(&self) -> u64 {
            self.timelock_blocks
        }

        pub fn pending(&self) -> Option<PendingView> {
            self.pending
                .as_ref()
                .map(|(change, execute_at)| PendingView {
                    change: change.clone(),
                    execute_at: *execute_at,
                })
        }

        /// Whether the incoming guardian of the pending guardian change has
        /// accepted it. False when nothing is pending or the change is a delay.
        pub fn pending_accepted(&self) -> bool {
            self.pending_accepted
        }

        /// Immediate. A guardian that wants a delay enforces it before this call.
        /// Empty names are rejected. Names longer than 64 bytes are rejected.
        /// An all-zero id is rejected, as on EvmAtlas.
        /// An id already stored under that name is rejected, so a repeat does
        /// not emit. Instances deployed before 0.4.0 keep whatever they
        /// already stored; the unchanged check is 0.6.0.
        pub fn set_service(&mut self, args: SetServiceArgs) {
            self.require_guardian();
            if args.name.is_empty() {
                panic!("name empty");
            }
            if args.name.len() > 64 {
                panic!("name longer than 64 bytes");
            }
            if args.id == Self::zero_contract_id() {
                panic!("service id zero");
            }
            if self.services.get(&args.name) == Some(&args.id) {
                panic!("service unchanged");
            }
            self.services.insert(args.name.clone(), args.id);
            abi::emit(
                "service_updated",
                ServiceUpdated {
                    name: args.name,
                    id: args.id,
                },
            );
        }

        /// Timelocked replacement of the guardian. The current guardian stays
        /// in force until the delay has passed AND the incoming guardian has
        /// called `accept_guardian`. A key that was mistyped, or a contract that
        /// never calls Atlas, cannot accept, so it can never take the slot; the
        /// current guardian cancels the stuck change.
        pub fn set_guardian(&mut self, next: Account) {
            self.require_guardian();
            Self::require_usable_account(&next);
            if self.guardian.as_ref() == Some(&next) {
                panic!("guardian unchanged");
            }
            self.schedule(PendingChange::Guardian(next));
        }

        /// Timelocked change of the delay. Raising and lowering both wait out
        /// the current value, so a guardian cannot zero the delay and rotate
        /// in the same transaction.
        pub fn set_timelock(&mut self, blocks: u64) {
            self.require_guardian();
            Self::require_timelock(blocks);
            if self.timelock_blocks == blocks {
                panic!("timelock unchanged");
            }
            self.schedule(PendingChange::Timelock(blocks));
        }

        fn require_timelock(blocks: u64) {
            if blocks > Self::MAX_TIMELOCK_BLOCKS {
                panic!("timelock above maximum");
            }
        }

        fn zero_contract_id() -> ContractId {
            ContractId::from_bytes([0u8; 32])
        }

        /// Reject a guardian that cannot act, or that anyone can be.
        ///
        /// A contract guardian is matched against `abi::caller()`. The zero id
        /// never matches, so it locks the slot for good. A genesis-style id
        /// (`[n, 0, ..., 0]`) is a protocol contract: the transfer contract is
        /// the caller of every Moonlight transaction, so naming it makes every
        /// account the guardian. Atlas never calls out, so its own id never
        /// matches either. A key is rejected unless its bytes decode to a
        /// valid curve point; the archived type does not check that on its own.
        fn require_usable_account(account: &Account) {
            match account {
                Account::Contract(id) => {
                    if *id == Self::zero_contract_id() {
                        panic!("guardian contract id zero");
                    }
                    if id.to_bytes()[1..].iter().all(|b| *b == 0) {
                        panic!("guardian contract id reserved");
                    }
                    if *id == abi::self_id() {
                        panic!("guardian cannot be atlas itself");
                    }
                }
                Account::External(key) => {
                    if BlsPublicKey::from_bytes(&key.to_bytes()).is_err() {
                        panic!("guardian key invalid");
                    }
                }
            }
        }

        /// Cancel the pending change. Allowed at any time, also after
        /// `execute_at`: until someone calls `execute_pending` (or the
        /// incoming guardian accepts after the delay), the change is still
        /// pending and the guardian can withdraw it. At `execute_at` the two
        /// race and transaction order decides.
        pub fn cancel_pending(&mut self) {
            self.require_guardian();
            let (change, execute_at) = self
                .pending
                .take()
                .unwrap_or_else(|| panic!("no pending change"));
            self.pending_accepted = false;
            abi::emit("pending_cancelled", PendingCancelled { change, execute_at });
        }

        /// Called by the incoming guardian of a pending guardian change, with
        /// the same authentication as a guardian call (a direct call from the
        /// key, or `caller` equal to the contract id). It proves the new
        /// account can act before it takes the slot. Emits `guardian_accepted`
        /// naming the account that accepted. If the delay has already passed
        /// the change is applied in this call (`guardian_set` follows).
        pub fn accept_guardian(&mut self) {
            let (change, execute_at) = self
                .pending
                .clone()
                .unwrap_or_else(|| panic!("no pending change"));
            let PendingChange::Guardian(incoming) = change else {
                panic!("the pending change is not a guardian change");
            };
            Self::require_account(&incoming, "incoming guardian");
            self.pending_accepted = true;
            abi::emit(
                "guardian_accepted",
                GuardianAccepted {
                    guardian: incoming,
                    execute_at,
                },
            );
            if block_height() >= execute_at {
                self.execute_pending();
            }
        }

        /// Apply a pending change after the timelock window. Permissionless.
        /// A guardian change also needs the incoming guardian's acceptance.
        pub fn execute_pending(&mut self) {
            let (change, execute_at) = self
                .pending
                .clone()
                .unwrap_or_else(|| panic!("no pending change"));
            if block_height() < execute_at {
                panic!("timelock not elapsed");
            }
            if matches!(change, PendingChange::Guardian(_)) && !self.pending_accepted {
                panic!("incoming guardian has not accepted");
            }
            // Clear first so a re-entrant guardian check sees no pending change.
            self.pending = None;
            self.pending_accepted = false;
            match change {
                PendingChange::Guardian(guardian) => {
                    self.guardian = Some(guardian.clone());
                    abi::emit("guardian_set", GuardianSet { guardian });
                }
                PendingChange::Timelock(blocks) => {
                    self.timelock_blocks = blocks;
                    abi::emit("timelock_set", TimelockSet { blocks });
                }
            }
        }

        fn schedule(&mut self, change: PendingChange) {
            if self.pending.is_some() {
                panic!("a pending change already exists; cancel or execute it first");
            }
            // Unreachable while `MAX_TIMELOCK_BLOCKS` holds: the delay is capped
            // on every write, far below `u64::MAX`. Kept as a second guard.
            let execute_at = block_height()
                .checked_add(self.timelock_blocks)
                .expect("timelock overflow");
            let scheduled = PendingScheduled {
                change: change.clone(),
                execute_at,
            };
            let applies_at_once = matches!(change, PendingChange::Timelock(_));
            self.pending = Some((change, execute_at));
            self.pending_accepted = false;
            abi::emit("pending_scheduled", scheduled);
            // Zero timelock: a delay change applies immediately (lab, and the
            // first raise from 0). A guardian change still waits for the
            // incoming guardian to accept.
            if self.timelock_blocks == 0 && applies_at_once {
                self.execute_pending();
            }
        }

        /// Genesis transfer contract (`dusk_core::transfer::TRANSFER_CONTRACT`).
        /// Every Moonlight transaction enters through `spend_and_execute`, so
        /// this id is the caller of a direct wallet call.
        fn transfer_contract_id() -> ContractId {
            let mut bytes = [0u8; 32];
            bytes[0] = 1;
            ContractId::from_bytes(bytes)
        }

        /// Bare session call (empty call stack) or a Moonlight transaction
        /// whose only frame below Atlas is the transfer contract. Any other
        /// caller is a contract using the sender's key.
        ///
        /// The depth matters as much as the id. The transfer contract's
        /// `contract_to_contract` lets any contract make the transfer
        /// contract call Atlas inside a transaction the key signed; `caller`
        /// is then the transfer contract too, but the stack is transfer →
        /// that contract → transfer (three frames). A direct Moonlight call
        /// has exactly one.
        fn is_direct_account_call() -> bool {
            match abi::callstack().as_slice() {
                [] => true,
                [only] => *only == Self::transfer_contract_id(),
                _ => false,
            }
        }

        /// Deploy-time owner, direct account call only, for `init_guardian`.
        fn require_deploy_owner() {
            if !Self::is_direct_account_call() {
                panic!("Only the deploy owner may init_guardian");
            }
            let sender = abi::public_sender();
            let owner = abi::self_owner();
            if sender != Some(owner) {
                panic!("Only the deploy owner may init_guardian");
            }
        }

        /// External: direct account call from the key. Contract: `caller` equals the id.
        /// No outbound call.
        fn require_guardian(&self) {
            let guardian = self
                .guardian
                .as_ref()
                .unwrap_or_else(|| panic!("atlas not initialized: call init_guardian first"));
            Self::require_account(guardian, "guardian");
        }

        /// Authenticate the caller as `account`. `label` names the role in
        /// the panic messages.
        fn require_account(account: &Account, label: &str) {
            match account {
                Account::External(key) => {
                    if !Self::is_direct_account_call() {
                        panic!("External {label}: direct call required");
                    }
                    if abi::public_sender() != Some(*key) {
                        panic!("Only the atlas {label} may perform this action");
                    }
                }
                Account::Contract(id) => {
                    if abi::caller() != Some(*id) {
                        panic!("Contract {label}: caller must be the {label} contract");
                    }
                }
            }
        }
    }
}
