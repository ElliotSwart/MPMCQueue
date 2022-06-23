-------------------------------- MODULE MPMC --------------------------------
EXTENDS Naturals, Sequences, FiniteSets

\* Must be set to a model value
CONSTANT EMPTY

CONSTANT CAPACITY

CONSTANTS 
    VALUES, \* Set of model values
    THREADS \* Set of model values

VARIABLES
    queue,
    operations,
    threadStates

vars == <<queue, operations, threadStates>>


SLOT_IDS == 1..CAPACITY

SlotValues == VALUES \union {EMPTY}


Slot == [turn: Nat, value: SlotValues]

InactiveState == [state: {"inactive"}]
EnqueueState == [
                 state: {"started_enqueue", "fetched_and_incremented_head"}, 
                 head: Nat, 
                 value: VALUES,
                 
                 \* Observability
                 startTime: Nat
                ]

TryEnqueueState == [
                    state: {"started_try_enqueue", "retrying_get_head", "compare_and_swap_head_failed"}, 
                    head: Nat,
                    value: VALUES,
                    
                    \* Observability
                    startTime: Nat
                   ]

DequeueState == [
                 state: {"started_dequeue", "fetched_and_incremented_tail"}, 
                 tail: Nat,
                 \* Observability
                 startTime: Nat
                ]
TryDequeueState == [
                    state: {"started_try_dequeue", "retrying_get_tail", "compare_and_swap_tail_failed"}, 
                    tail: Nat,
                    \* Observability
                    startTime: Nat
                 ]

ThreadState == InactiveState \union
               EnqueueState \union
               TryEnqueueState \union
               DequeueState \union
               TryDequeueState


Operation == [
    type: {"enqueue_started", "dequeue_started", "enqueue_returned", "dequeue_returned"},
    value: SlotValues,
    startTime: Nat
]

TypeOk ==
    /\ /\ CAPACITY \in Nat
       /\ CAPACITY >= 1
    /\ queue.slots \in [SLOT_IDS -> Slot]
    /\ queue.head \in Nat
    /\ queue.tail \in Nat
    /\ threadStates \in [THREADS -> ThreadState]
    /\ operations \in Seq(Operation)



Index(i) == (i % CAPACITY) + 1 \* +1 because sequence is 1 indexed

Turn(i) == i \div CAPACITY

Now == Len(operations)

StartEnqueue(t) ==
    /\ threadStates[t].state = "inactive"
    /\ \E v \in VALUES: \* Value to enqueue
        /\ threadStates' = 
                [threadStates EXCEPT
                    ![t] = [state |-> "started_enqueue", 
                            head |-> 0,
                            value |-> v,
                            startTime |-> Now
                           ]
                ]
        /\ operations' = Append(operations, [
                                                type |-> "enqueue_started", 
                                                value |-> v,
                                                startTime |-> Now
                                            ])
    /\ UNCHANGED <<queue>>

EnqueueFetchAndIncrementHead(t) ==
    /\ threadStates[t].state = "started_enqueue"
    \* Atomic Fetch and Add
    /\ threadStates' = 
            [threadStates EXCEPT
                ![t].state = "fetched_and_incremented_head", 
                ![t].head = queue.head
            ]
    /\ queue' =
            [queue EXCEPT
                !["head"] = queue.head + 1
            ]
    /\ UNCHANGED <<operations>>
    
EnqueueStoreValue(t) ==
    LET value == threadStates[t].value IN
    LET head == threadStates[t].head IN
    LET slotIndex == Index(head) IN
    LET slot == queue.slots[slotIndex] IN
    LET ticket == Turn(head) * 2 IN
    /\ threadStates[t].state = "fetched_and_incremented_head"
    \* Waiting for write ticket precondition
    /\ ticket = slot.turn
    /\ threadStates' = 
        [threadStates EXCEPT
            ![t] = [state |-> "inactive"]
        ]
    /\ queue' = [queue EXCEPT
                    !["slots"][slotIndex].value = value,
                    !["slots"][slotIndex].turn = Turn(head) * 2 + 1
                ]
    /\ operations' = Append(operations, [
                                            type |-> "enqueue_started", 
                                            value |-> value,
                                            startTime |-> threadStates[t].startTime
                                        ])
    /\ UNCHANGED <<>>
    
StartTryEnqueue(t) == UNCHANGED vars

StartDequeue(t) ==
    /\ threadStates[t].state = "inactive"
    /\ threadStates' = 
                [threadStates EXCEPT
                    ![t] = [state |-> "started_dequeue", 
                            tail |-> 0,
                            startTime |-> Now
                           ]
                ]
    /\ operations' = Append(operations, [
                                            type |-> "dequeue_started", 
                                            value |-> EMPTY,
                                            startTime |-> Now
                                        ])
    /\ UNCHANGED <<queue>>

DequeueFetchAndIncrementTail(t) ==
    /\ threadStates[t].state = "started_dequeue"
    /\ threadStates' = 
            [threadStates EXCEPT
                ![t].state = "fetched_and_incremented_tail", 
                ![t].tail = queue.tail
            ]
    /\ queue' =
        [queue EXCEPT
            !["tail"] = queue.tail + 1
        ]
    /\ UNCHANGED <<operations>>
    
DequeueReturnValue(t) ==
    LET tail == threadStates[t].tail IN
    LET slotIndex == Index(tail) IN
    LET slot == queue.slots[slotIndex] IN
    LET ticket == Turn(tail) * 2 + 1 IN
    /\ threadStates[t].state = "fetched_and_incremented_tail"
    \* Waiting for read ticket precondition
    /\ ticket = slot.turn
    /\ threadStates' = 
        [threadStates EXCEPT
            ![t] = [state |-> "inactive"]
        ]
    \* Dequeue and update turns
    /\ queue' = [queue EXCEPT
                    !["slots"][slotIndex].value = EMPTY,
                    !["slots"][slotIndex].turn = Turn(tail) * 2 + 2
                ]
    /\ operations' = Append(operations, [
                                        type |-> "dequeue_returned", 
                                        value |-> slot.value,
                                        startTime |-> threadStates[t].startTime
                                    ])
    /\ UNCHANGED <<>>

StartTryDequeue(t) == UNCHANGED vars


Init ==
    /\ queue = [
            \* Slots are alocated at init
            slots |-> [s \in SLOT_IDS |-> [turn |-> 0, value |-> EMPTY]],
            \* Head and tail start at 0
            head |-> 0,
            tail |-> 0
       ]
    /\ threadStates = [t \in THREADS |-> [state |-> "inactive"]]
    /\ operations = <<>>

Next == 
    \E t \in THREADS:
        \* Enqueue
        \/ StartEnqueue(t)
        \/ EnqueueFetchAndIncrementHead(t)
        \/ EnqueueStoreValue(t)
        \* Dequeue
        \/ StartDequeue(t)
        \/ DequeueFetchAndIncrementTail(t)
        \/ DequeueReturnValue(t)

Spec == Init /\ [][Next]_vars


StateConstraint == Len(operations) < 8


EveryEnqueuedItemIsDequeuedOrInQueue ==
    \* There does not exist
    ~\E i \in 1..Len(operations):
        \* a successful enqueue operation 
        /\ operations[i].type = "enqueue_returned"
        \* that is not in the queue
        /\ ~\E j \in SLOT_IDS:
              queue.slots[j].value = operations[i].value
        \* and has not been returned with dequeue
        /\ ~\E j \in i..Len(operations):
                /\ operations[j].type = "dequeue_returned"
                /\ operations[j].value = operations[i].value


=============================================================================
\* Modification History
\* Last modified Thu Jun 23 18:25:53 MST 2022 by elliotswart
\* Created Thu Jun 23 12:45:09 MST 2022 by elliotswart
