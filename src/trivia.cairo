use starknet::ContractAddress;

#[starknet::interface]
trait ITrivia<TContractState> {
    fn determine_winners(
        ref self: TContractState, trivia_id: u32, participants: Array<ContractAddress>
    );
    fn get_winners(
        self: @TContractState, trivia_id: u32
    ) -> (ContractAddress, ContractAddress, ContractAddress);
    fn get_trivia_details(self: @TContractState, trivia_id: u32) -> TriviaDetails;
    fn get_prize_details(self: @TContractState, trivia_id: u32) -> PrizeDetails;
    fn start_trivia(ref self: TContractState, trivia_id: u32) -> bool;
    fn add_question(ref self: TContractState, trivia_id: u32, question: Question);
    fn get_question(self: @TContractState, trivia_id: u32, question_number: u32) -> Question;
    fn submit_answer(
        ref self: TContractState,
        trivia_id: u32,
        question_number: u32,
        participant: ContractAddress,
        answer: felt252
    ) -> bool;
    fn check_registration_deadline(self: @TContractState, trivia_id: u32) -> bool;
}

#[derive(Copy, Drop, Serde, starknet::Store)]
enum TriviaStatus {
    NotStarted,
    Active,
    Completed
}

#[derive(Copy, Drop, Serde, starknet::Store)]
pub struct TriviaDetails {
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
pub struct PrizeDetails {
    entry_fee: u256,
    total_prize_pool: u256,
    current_participants: u32,
    first_place_percentage: u8,
    second_place_percentage: u8,
    third_place_percentage: u8
}

#[derive(Copy, Drop, Serde, starknet::Store)]
pub struct Question {
    question_text: felt252,
    answer_a: felt252,
    answer_b: felt252,
    answer_c: felt252,
    answer_d: felt252,
    correct_answer: felt252 // Will store 'A', 'B', 'C', or 'D'
}

#[starknet::contract]
mod trivia {    

    use core::starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess
    };
    use starknet::{
        ContractAddress,
        get_caller_address,
        get_block_timestamp
    };

    #[storage]
    struct Storage {
        trivia_winners: Map<u32, (ContractAddress, ContractAddress, ContractAddress)>,
        trivia_details: Map<u32, TriviaDetails>,
        prize_details: Map<u32, PrizeDetails>,
        questions: Map<(u32, u32), Question>,
        questions_count: Map<u32, u32>,
        participant_scores: Map<(u32, ContractAddress), (u32, u64)>,
        participant_answers: Map<(u32, ContractAddress, u32), u64>
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        TriviaStarted: TriviaStarted,
        QuestionAdded: QuestionAdded,
        AnswerSubmitted: AnswerSubmitted,
        RoundAdvanced: RoundAdvanced
    }

        #[derive(Drop, starknet::Event)]
        struct TriviaStarted {
            #[key]
            trivia_id: u32,
            registration_deadline: u64
        }

    #[derive(Drop, starknet::Event)]
    struct QuestionAdded {
        #[key]
        trivia_id: u32,
        question_number: u32
    }

    #[derive(Drop, starknet::Event)]
    struct AnswerSubmitted {
        #[key]
        trivia_id: u32,
        #[key]
        participant: ContractAddress,
        question_number: u32
    }

    #[derive(Drop, starknet::Event)]
    struct RoundAdvanced {
        #[key]
        trivia_id: u32,
        new_round: u32
    }

    #[abi(embed_v0)]
    impl Trivia of super::ITrivia<ContractState> {
        fn determine_winners(
            ref self: ContractState,
            trivia_id: u32,
            participants: Array<ContractAddress>
        ) {
            let mut best_score: u32 = 0;
            let mut best_time: u64 = 0;
            let mut winner: ContractAddress = participants.at(0);

            let mut i: u32 = 0;
            loop {
                if i >= participants.len() {
                    break;
                }
                let participant = *participants.at(i);
                let participant_data = self.participant_scores.read((trivia_id, participant));
                let (current_score, current_time) = participant_data;
                
                if current_score > best_score || (current_score == best_score && current_time < best_time) {
                    best_score = current_score;
                    best_time = current_time;
                    winner = participant;
                }
                i += 1;
            }

            // Store winners for this specific trivia
            self.trivia_winners.write(trivia_id, (winner, winner, winner));
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

        fn add_question(ref self: ContractState, trivia_id: u32, question: Question) {
            let current_count = self.questions_count.read(trivia_id);
            self.questions.write((trivia_id, current_count), question);
            self.questions_count.write(trivia_id, current_count + 1);

            // Update total_rounds in trivia_details
            let mut trivia_details = self.trivia_details.read(trivia_id);
            trivia_details.total_rounds = current_count + 1;
            self.trivia_details.write(trivia_id, trivia_details);
        }

        fn get_question(self: @ContractState, trivia_id: u32, question_number: u32) -> Question {
            assert(
                question_number < self.questions_count.read(trivia_id), 'Invalid question number'
            );
            self.questions.read((trivia_id, question_number))
        }

        fn submit_answer(
            ref self: ContractState,
            trivia_id: u32,
            question_number: u32,
            participant: ContractAddress,
            answer: felt252
        ) -> bool {
            // Get current question
            let question = self.questions.read((trivia_id, question_number));

            // Get current timestamp
            let current_time = starknet::get_block_timestamp();

            // Store answer timestamp
            self.participant_answers.write((trivia_id, participant, question_number), current_time);

            // Check if answer is correct
            let is_correct = question.correct_answer == answer;

            // Update participant's score and time
            let (current_score, total_time) = self
                .participant_scores
                .read((trivia_id, participant));

            if is_correct {
                // Increment score by 1 and update total time
                self
                    .participant_scores
                    .write(
                        (trivia_id, participant), (current_score + 1, total_time + current_time)
                    );
            }

            is_correct
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
