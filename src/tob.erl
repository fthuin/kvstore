-module(tob).
-include("biker.hrl").

-export([
        tob_loop/3
    ]).

%% @doc main loop to perform a total order broadcast for the biker race.
tob_loop(ListOfStates, Pid, RoundNbr) ->
    io:format("Current state of race:~n"),
    biker:print_state(lists:nth(Pid, ListOfStates)),
    % Display the list sorted by the position in descending order.
    biker:display(lists:reverse(lists:sort(fun(State1, State2) -> State1#state.position =< State2#state.position end, ListOfStates))),
    %erlang:send_after(?ROUNDLENGTH, self(), {ok, coucou}),
    InputPid = spawn(biker, user_input_decision, [self()]),
    {ok, TRef} = timer:kill_after(timer:seconds(10), InputPid),
    NewDecision = biker:round_timeout((lists:nth(Pid, ListOfStates))#state.decision, TRef),
    io:format("Putting {~p,~p} at key: ~p~n", [RoundNbr+1, NewDecision, Pid]),
    biker:put(integer_to_list(Pid), {RoundNbr+1, NewDecision}),
    wait_for_all_decisions(length(ListOfStates), RoundNbr+1),
    StatesWithDecision = biker:update_states_decision(ListOfStates), % update the field decision in all states
    case contains_cycle(create_behind_list(StatesWithDecision)) of
        false -> StatesUpdated = biker:update_states(StatesWithDecision); % update the other fields of the states based on the decision;
        {OldPid, true} -> io:format("Conflict in behind...~n"),
                StatesUpdated=biker:update_states(
                    lists:map(  fun(X) ->
                            if
                                OldPid == X#state.pid ->
                                    #state { pid=X#state.pid,
                                                roundnbr=X#state.roundnbr,
                                                decision={X#state.roundnbr+1, {speed, X#state.speed}},
                                                nbrofplayers=X#state.nbrofplayers,
                                                position=X#state.position,
                                                distancetocover=X#state.distancetocover,
                                                energy=X#state.energy,
                                                speed=X#state.speed,
                                                roundlength=X#state.roundlength
                                            };
                                OldPid =/= X#state.pid ->
                                    X
                            end
                        end,
                        StatesWithDecision))
    end,
    MyNewState = lists:nth(Pid, StatesUpdated),
    case MyNewState of
        _ when MyNewState#state.position >= ?DISTANCETOCOVER ->
            io:format("You finished the race!~n"),
            dummy_tob_loop(StatesUpdated, Pid, RoundNbr+1);
        _ when MyNewState#state.energy =< 0 ->
            io:format("You are out of energy!~n"),
            dummy_tob_loop(StatesUpdated, Pid, RoundNbr+1);
        _ when MyNewState#state.position < ?DISTANCETOCOVER andalso MyNewState#state.energy > 0 ->
            tob_loop(StatesUpdated, Pid, RoundNbr+1)
    end.

%% @doc waits that all decisions are put in the kvstore
wait_for_all_decisions(N, RoundNbr) ->
    case N of
        0 -> ok;
        _ ->
            case biker:get(integer_to_list(N)) of
                {ok, {RoundNbr, {_,_}}} ->
                    io:format("Decision of ~p received~n", [N]),
                    wait_for_all_decisions(N-1, RoundNbr);
                {ok, {RoundNbr, {boost}}} ->
                    io:format("Decision of ~p received~n", [N]),
                    wait_for_all_decisions(N-1, RoundNbr);
                {ok, _} ->
                    timer:sleep(500),
                    wait_for_all_decisions(N, RoundNbr)
            end
    end.

create_behind_list(ListOfStates) ->
    create_behind_list(ListOfStates, []).

create_behind_list(ListOfStates, ListOfBehind) ->
    case ListOfStates of
        [] -> ListOfBehind;
        [H | T] ->
            case H#state.decision of
                {_, {behind, PlayerNbr}} ->
                    NewListOfBehind = lists:flatten([ListOfBehind | [ {H#state.pid, PlayerNbr}] ]),
                    create_behind_list(T, NewListOfBehind);
                _ ->
                    create_behind_list(T, ListOfBehind)
            end
    end.



contains_cycle(ListOfBehind) ->
    contains_cycle(ListOfBehind, ListOfBehind).

contains_cycle(List, ListOfBehind) ->
    io:format("contains_cycle? ~p~n", [ListOfBehind]),
    case List of
        [] -> false;
        [H | T] ->
            case H of
                {Pid, Pid2} ->
                    case check_cycle(Pid, Pid2, Pid2, ListOfBehind) of
                        {OldPid, true} -> {OldPid, true};
                        false -> contains_cycle(T, ListOfBehind)
                    end
            end
    end.

check_cycle(Pid, Pid2, OldPid, ListOfTuples) ->
    case ListOfTuples of
        [] ->
            io:format("check_cycle finished ~p ~p ~p ~p", [Pid, Pid2, OldPid, ListOfTuples]),
            if
                Pid == Pid2 -> {OldPid, true};
                Pid =/= Pid2 -> false
            end;
        [H | T] ->
            case H of
                {Pid2, Nbr} ->
                    check_cycle(Pid, Nbr, Pid2, T);
                _ ->
                    check_cycle(Pid, Pid2, Pid2, T)
            end
    end.

%% @doc total order broadcast loop that doesn't ask for an user input (used
%% when the node has finished the race)
dummy_tob_loop(ListOfStates, Pid, RoundNbr) ->
    io:format("You can't play anymore. You can see the race:~n"),
    biker:display(lists:reverse(lists:sort(fun(State1, State2) -> State1#state.position =< State2#state.position end, ListOfStates))),
    case check_finished(ListOfStates) of
        true ->
            race_finished;
        false ->
            timer:sleep(?ROUNDLENGTH),
            io:format("Putting {~p,~p} at key: ~p~n", [RoundNbr+1, {speed, 0}, Pid]),
            biker:put(integer_to_list(Pid), {RoundNbr+1, {speed, 0}}),
            wait_for_all_decisions(length(ListOfStates), RoundNbr+1),
            StatesWithDecision = biker:update_states_decision(ListOfStates), % update the field decision in all states
            case contains_cycle(create_behind_list(StatesWithDecision)) of
                false -> StatesUpdated = biker:update_states(StatesWithDecision); % update the other fields of the states based on the decision;
                {OldPid, true} -> io:format("Conflict in behind...~n"),
                        StatesUpdated=biker:update_states(
                            lists:map(  fun(X) ->
                                    if
                                        OldPid == X#state.pid ->
                                            #state { pid=X#state.pid,
                                                        roundnbr=X#state.roundnbr,
                                                        decision={X#state.roundnbr+1, {speed, X#state.speed}},
                                                        nbrofplayers=X#state.nbrofplayers,
                                                        position=X#state.position,
                                                        distancetocover=X#state.distancetocover,
                                                        energy=X#state.energy,
                                                        speed=X#state.speed,
                                                        roundlength=X#state.roundlength
                                                    };
                                        OldPid =/= X#state.pid ->
                                            X
                                    end
                                end,
                                StatesWithDecision))
            end,
            dummy_tob_loop(StatesUpdated, Pid, RoundNbr+1)
    end.

check_finished(ListOfStates) ->
    case ListOfStates of
        [] ->
            true;
        [H | T] ->
            Position = H#state.position,
            Energy = H#state.energy,
            if
                Position >= ?DISTANCETOCOVER orelse Energy =< 0 -> check_finished(T);
                Position < ?DISTANCETOCOVER andalso Energy > 0 -> false
            end
    end.
