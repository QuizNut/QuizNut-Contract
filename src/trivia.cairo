#[starknet::interface]
pub trait ITrivia<T> {
    fn determine_winners(
        ref self: T,
        trivia_id: u32,
        participants: Array<ContractAddress>,
        participant_scores: LegacyMap<ContractAddress, (u32, u64)>
    );
    fn get_winners(self: @T, trivia_id: u32) -> (ContractAddress, ContractAddress, ContractAddress);
    fn get_trivia_details(self: @T, trivia_id: u32) -> TriviaDetails;
    fn get_prize_details(self: @T, trivia_id: u32) -> PrizeDetails;
    fn start_trivia(ref self: T, trivia_id: u32) -> bool;
}

#[derive(Copy, Drop, Serde, starknet::Store)]
struct TriviaDetails {
    name: felt252,
    description: felt252,
    registration_deadline: u64,
    start_time: u64,
    min_participants: u32,
    status: TriviaStatus,
    total_rounds: u32,
    current_round: u32
}

#[derive(Copy, Drop, Serde, starknet::Store)]
struct PrizeDetails {
    entry_fee: u256,
    total_prize_pool: u256,
    current_participants: u32,
    first_place_percentage: u8,
    second_place_percentage: u8,
    third_place_percentage: u8
}

#[starknet::contract]
pub mod trivia {
    use super::{TriviaDetails, PrizeDetails};
    use starknet::ContractAddress;

    #[storage]
    struct Storage {
        // Store winners for each trivia game
        trivia_winners: LegacyMap<u32, (ContractAddress, ContractAddress, ContractAddress)>,
        trivia_details: LegacyMap<u32, TriviaDetails>,
        prize_details: LegacyMap<u32, PrizeDetails>,
    }

    #[external(v0)]
    impl Trivia of super::ITrivia<ContractState> {
        fn determine_winners(
            ref self: ContractState,
            trivia_id: u32,
            participants: Array<ContractAddress>,
            participant_scores: LegacyMap<ContractAddress, (u32, u64)>
        ) {
            let mut first_place: ContractAddress = starknet::contract_address_const::<0>();
            let mut second_place: ContractAddress = starknet::contract_address_const::<0>();
            let mut third_place: ContractAddress = starknet::contract_address_const::<0>();

            let mut best_score: u32 = 0;
            let mut best_time: u64 = 0;

            // Iterate through participants array
            let mut i: u32 = 0;
            loop {
                if i >= participants.len() {
                    break;
                }

                let participant = *participants.at(i);
                let (score, time) = participant_scores.read(participant);

                if score > best_score || (score == best_score && time < best_time) {
                    third_place = second_place;
                    second_place = first_place;
                    first_place = participant;
                    best_score = score;
                    best_time = time;
                }

                i += 1;
            };

            // Store winners for this specific trivia
            self.trivia_winners.write(trivia_id, (first_place, second_place, third_place));
        }

        // To be used by the frontend or other contracts to display past winners
        fn get_winners(
            self: @ContractState, trivia_id: u32
        ) -> (ContractAddress, ContractAddress, ContractAddress) {
            self.trivia_winners.read(trivia_id)
        }

        fn get_trivia_details(self: @ContractState, trivia_id: u32) -> TriviaDetails {
            self.trivia_details.read(trivia_id)
        }

        fn get_prize_details(self: @ContractState, trivia_id: u32) -> PrizeDetails {
            self.prize_details.read(trivia_id)
        }

        fn start_trivia(ref self: ContractState, trivia_id: u32) -> bool {
            // Get current trivia details
            let mut trivia_details = self.trivia_details.read(trivia_id);

            // Ensure trivia hasn't started yet
            assert(trivia_details.status == TriviaStatus::NotStarted, 'Trivia already started');

            // Get prize details to check current participants
            let prize_details = self.prize_details.read(trivia_id);

            // Check if minimum participants requirement is met
            if prize_details.current_participants < trivia_details.min_participants {
                return false;
            }

            // Update status to Active
            trivia_details.status = TriviaStatus::Active;
            self.trivia_details.write(trivia_id, trivia_details);

            true
        }

        fn check_registration_deadline(self: @ContractState, trivia_id: u32) -> bool {
            let trivia_details = self.trivia_details.read(trivia_id);
            let current_time = starknet::get_block_timestamp();
            current_time <= trivia_details.registration_deadline
        }

        fn advance_round(ref self: ContractState, trivia_id: u32) {
            let mut trivia_details = self.trivia_details.read(trivia_id);
            assert(
                trivia_details.current_round < trivia_details.total_rounds, 'All rounds completed'
            );

            trivia_details.current_round += 1;
            self.trivia_details.write(trivia_id, trivia_details);
        }

        fn get_current_round(self: @ContractState, trivia_id: u32) -> u32 {
            let trivia_details = self.trivia_details.read(trivia_id);
            trivia_details.current_round
        }
    }

    // Add constructor or initialization function
    #[constructor]
    fn constructor(
        ref self: ContractState,
        trivia_id: u32,
        name: felt252,
        description: felt252,
        start_time: u64,
        min_participants: u32,
        entry_fee: u256,
        first_place_percentage: u8,
        second_place_percentage: u8,
        third_place_percentage: u8
    ) {
        // Validate percentages add up to 100
        assert(
            first_place_percentage + second_place_percentage + third_place_percentage == 100,
            'Invalid prize distribution'
        );

        let trivia_details = TriviaDetails {
            name: name,
            description: description,
            registration_deadline: 0,
            start_time: start_time,
            min_participants: min_participants,
            status: TriviaStatus::NotStarted,
            total_rounds: 0,
            current_round: 0
        };

        let prize_details = PrizeDetails {
            entry_fee: entry_fee,
            total_prize_pool: 0,
            current_participants: 0,
            first_place_percentage: first_place_percentage,
            second_place_percentage: second_place_percentage,
            third_place_percentage: third_place_percentage
        };

        self.trivia_details.write(trivia_id, trivia_details);
        self.prize_details.write(trivia_id, prize_details);
    }
}

#[derive(Copy, Drop, Serde, starknet::Store)]
enum TriviaStatus {
    NotStarted,
    Active,
    Completed,
}
