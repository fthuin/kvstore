-module(kvstore).
-include("kvstore.hrl").
-include_lib("../deps/riak_core/include/riak_core_vnode.hrl").

-export([
         ping/0,
		 get_partitions/0,
         get/1,
         put/2,
         incr/1,
         incrby/2,
         start_race/2,
         user_input_decision/1
        ]).

-define(BUCKET, "default").
-define(TIMEOUT, 5000).
-define(ROUNDLENGTH, 10000).
-define(DISTANCETOCOVER, 100).

-record(state, {pid, roundnbr, decision, nbrofplayers, position, distancetocover, energy, speed, roundlength}).


%% Public API

%% @doc Pings a random vnode to make sure communication is functional
ping() ->
    DocIdx = riak_core_util:chash_key({<<"ping">>, term_to_binary(now())}),
    PrefList = riak_core_apl:get_primary_apl(DocIdx, 1, kvstore),
    [{IndexNode, _Type}] = PrefList,
    riak_core_vnode_master:sync_spawn_command(IndexNode, ping, kvstore_vnode_master).

get_partitions() ->
	?PRINT(riak_core_nodeid:get()),
	{ok, CHBin} = riak_core_ring_manager:get_chash_bin(),
    chashbin:to_list(CHBin).

%% @doc Get a key's value.
get(KeyName) ->
    {ok, ReqID} = kvstore_get_fsm:get(?BUCKET, KeyName),
    wait_for_reqid(ReqID, ?TIMEOUT).

%% @doc Put a key's value, replacing the current value.
put(KeyName, Val) ->
   do_write(KeyName, put, Val).

%% @doc Increment the key's value by 1.
incr(KeyName) ->
    do_write(KeyName, incr).

%% @doc Increment the key's value by Val.
incrby(KeyName, Val) ->
    do_write(KeyName, incrby, Val).

start_race(Pid, N) ->
    %% @doc: Pid is the given PID for this node and N is the total number of nodes
    io:format("PID:N --- ~p:~p ~n", [Pid, N]),
    Var = init_game_state(N,N,[]),
    ok = kvstore:put(integer_to_list(Pid), {0, {speed, 0}}),
    io:format("~p~n", [Var]),
    beb_loop(Var, Pid, 0),
    {ok, start_race}.

%%%===================================================================
%%% Internal Functions
%%%===================================================================

wait_for_reqid(ReqId, Timeout) ->
	receive
		{ReqId, ok} -> ok;
		{ReqId, ok, Val} -> {ok,Val}
	after Timeout ->
		{error, timeout}
	end.

do_write(KeyName, Op) ->
	{ok, ReqID} = kvstore_modify_fsm:modify(?BUCKET, KeyName, Op),
	wait_for_reqid(ReqID, ?TIMEOUT).

do_write(KeyName, Op, Val) ->
	{ok, ReqID} = kvstore_modify_fsm:modify(?BUCKET, KeyName, Op, Val),
	wait_for_reqid(ReqID, ?TIMEOUT).

init_game_state(I, N, Acc) ->
    case I of
        0 -> Acc;
        _ -> Var = #state { pid=I,
                            roundnbr=0,
                            decision={0, {speed, 0}},
                            nbrofplayers=N,
                            position=0,
                            distancetocover=?DISTANCETOCOVER,
                            energy=112,
                            speed=0,
                            roundlength=?ROUNDLENGTH
                            },
            init_game_state(I-1, N, [Var | Acc])
    end.


print_state(State) ->
    io:format("----------- State of node ~p during round ~p -----------~n", [State#state.pid, State#state.roundnbr]),
    io:format("Decision: ~p~n", [State#state.decision]),
    io:format("Nbr of players: ~p~n", [State#state.nbrofplayers]),
    io:format("Position: ~p~n", [State#state.position]),
    io:format("Distance to cover: ~p~n", [State#state.distancetocover]),
    io:format("Energy: ~p~n", [State#state.energy]),
    io:format("Speed: ~p~n", [State#state.speed]),
    io:format("----------------------------------------------------------~n").

wait_for_all_decisions(I, N, Acc, RoundNbr) ->
    case I of
        _ when Acc == N -> ok;
        _ ->
            case kvstore:get(integer_to_list(I)) of
                {ok, {RoundNbr, {_,_}}} ->
                    io:format("Decision of ~p received~n", [I]),
                    wait_for_all_decisions((I rem N)+1, N, Acc+1, RoundNbr);
                {ok, {RoundNbr, {boost}}} ->
                    io:format("Decision of ~p received~n", [I]),
                    wait_for_all_decisions((I rem N)+1, N, Acc+1, RoundNbr);
                {ok, _} ->
                    timer:sleep(500),
                    wait_for_all_decisions(I, N, Acc, RoundNbr)
            end
    end.

create_behind_list_from_id(ListOfStates, Pid) ->
    StatesNotMe = lists:filter(fun(State) -> State#state.pid =/= Pid end,ListOfStates),
    StatesMeFirst = lists:flatten([lists:nth(Pid, ListOfStates) | StatesNotMe]),
    create_behind_list(StatesMeFirst).

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

beb_loop(ListOfStates, Pid, RoundNbr) ->
    io:format("Current state of race:~n"),
    print_state(lists:nth(Pid, ListOfStates)),
    % Display the list sorted by the position in descending order.
    display(lists:reverse(lists:sort(fun(State1, State2) -> State1#state.position =< State2#state.position end, ListOfStates))),
    %erlang:send_after(?ROUNDLENGTH, self(), {ok, coucou}),
    InputPid = spawn(?MODULE, user_input_decision, [self()]),
    {ok, TRef} = timer:kill_after(timer:seconds(10), InputPid),
    NewDecision = round_timeout((lists:nth(Pid, ListOfStates))#state.decision, TRef),
    io:format("Putting {~p,~p} at key: ~p~n", [RoundNbr+1, NewDecision, Pid]),
    kvstore:put(integer_to_list(Pid), {RoundNbr+1, NewDecision}),
    wait_for_all_decisions(Pid, length(ListOfStates), 0, RoundNbr+1),
    StatesWithDecision = update_states_decision(ListOfStates), % update the field decision in all states
    case contains_cycle(create_behind_list_from_id(StatesWithDecision, Pid)) of
        false -> StatesUpdated = update_states(StatesWithDecision); % update the other fields of the states based on the decision;
        {OldPid, true} -> io:format("Conflict in behind...~n"),
                StatesUpdated=update_states(
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
            dummy_beb_loop(StatesUpdated, Pid, RoundNbr+1);
        _ when MyNewState#state.energy =< 0 ->
            io:format("You are out of energy!~n"),
            dummy_beb_loop(StatesUpdated, Pid, RoundNbr+1);
        _ when MyNewState#state.position < ?DISTANCETOCOVER andalso MyNewState#state.energy > 0 ->
            beb_loop(StatesUpdated, Pid, RoundNbr+1)
    end.

dummy_beb_loop(ListOfStates, Pid, RoundNbr) ->
    io:format("You can't play anymore. You can see the race:~n"),
    display(lists:reverse(lists:sort(fun(State1, State2) -> State1#state.position =< State2#state.position end, ListOfStates))),
    case check_finished(ListOfStates) of
        true ->
            race_finished;
        false ->
            timer:sleep(?ROUNDLENGTH),
            io:format("Putting {~p,~p} at key: ~p~n", [RoundNbr+1, {speed, 0}, Pid]),
            kvstore:put(integer_to_list(Pid), {RoundNbr+1, {speed, 0}}),
            wait_for_all_decisions(Pid, length(ListOfStates), 0, RoundNbr+1),
            StatesWithDecision = update_states_decision(ListOfStates), % update the field decision in all states
            StatesUpdated = update_states(StatesWithDecision), % update the other fields of the states based on the decision
            dummy_beb_loop(StatesUpdated, Pid, RoundNbr+1)
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

round_timeout(OldDecision, TRef) ->
    receive
        {decision, Decision} ->
            timer:cancel(TRef),
            Decision
    after
        ?ROUNDLENGTH ->
            io:format("The round has timed out. Old decision: ~p~n", [OldDecision]),
            case OldDecision of
                {RoundNbr, {speed, Nbr}} when RoundNbr >= 0 ->
                    Decision = {speed, Nbr};
                {RoundNbr, {behind, Nbr}} when RoundNbr >= 0 ->
                    Decision = {behind, Nbr};
                {RoundNbr, {boost}} when RoundNbr >= 0 ->
                    Decision = {boost}
            end,
            Decision
    end.

%% @doc From ListOfStates, gets the decision stored in the DHT and set it in
%% the list, then returns the updated list of states.
update_states_decision(ListOfStates) ->
    case ListOfStates of
        [] -> [];
        [H | T] ->
            Pid = H#state.pid,
            case kvstore:get(integer_to_list(Pid)) of
                {ok, not_found} -> Decision={0, {speed, 0}};
                {ok, Decision} -> ok
            end,
            case Decision of
                {_, {speed, Speed}} -> ok;
                _ -> Speed=H#state.speed
            end,
            NewState = #state { pid= Pid,
                        roundnbr=H#state.roundnbr,
                        decision=Decision,
                        nbrofplayers=H#state.nbrofplayers,
                        position=H#state.position,
                        distancetocover=H#state.distancetocover,
                        energy=H#state.energy,
                        speed=Speed,
                        roundlength=H#state.roundlength
                    },
            lists:flatten([NewState | lists:flatten(update_states_decision(T))])
    end.

update_states(ListOfStates) ->
    update_states(ListOfStates, ListOfStates).

update_states(List, ListOfStates) ->
    case List of
        [] -> [];
        [H | T] ->
            lists:flatten([calculate_new_state(H, ListOfStates) | lists:flatten(update_states(T, ListOfStates))])
    end.

calculate_new_state(State, ListOfStates) ->
    OldRoundNbr = State#state.roundnbr,
    Decision = State#state.decision,
    OldPosition = State#state.position,
    OldEnergy = State#state.energy,
    OldSpeed = State#state.speed,
    case Decision of
        {_, {boost}} ->
            NewSpeed = OldSpeed,
            if
                OldPosition + OldSpeed >= ?DISTANCETOCOVER ->
                    NewPosition = ?DISTANCETOCOVER;
                OldPosition + OldSpeed < ?DISTANCETOCOVER ->
                    NewPosition = OldPosition + OldSpeed
            end,
            NewEnergy = 0;
        {_, {speed, OldSpeedChoice}} ->
            NewSpeed = OldSpeedChoice,
            if
                 OldPosition + OldSpeedChoice >= ?DISTANCETOCOVER ->
                    NewPosition = ?DISTANCETOCOVER;
                 OldPosition + OldSpeedChoice < ?DISTANCETOCOVER ->
                    NewPosition =  OldPosition + OldSpeedChoice
            end,
            NewEnergy = OldEnergy - 0.12 * OldSpeedChoice * OldSpeedChoice;
        {_, {behind, OldPlayerChoice}} ->
            NewSpeed = (lists:nth(OldPlayerChoice, ListOfStates))#state.speed,
            % FIXME how to implement the position
            io:format("~p behind ~p. Position : ~p ; speed : ~p ~n", [State#state.pid, OldPlayerChoice, (lists:nth(OldPlayerChoice, ListOfStates))#state.position, (lists:nth(OldPlayerChoice, ListOfStates))#state.speed]),
            OtherPosition = (lists:nth(OldPlayerChoice, ListOfStates))#state.position + (lists:nth(OldPlayerChoice, ListOfStates))#state.speed,
            if
                 OtherPosition >= ?DISTANCETOCOVER ->
                    NewPosition = ?DISTANCETOCOVER;
                 OtherPosition < ?DISTANCETOCOVER ->
                    NewPosition =  OtherPosition
            end,
            NewEnergy = OldEnergy - 0.06 * (lists:nth(OldPlayerChoice, ListOfStates))#state.speed * (lists:nth(OldPlayerChoice, ListOfStates))#state.speed
    end,
    #state { pid=State#state.pid,
                roundnbr=OldRoundNbr+1,
                decision=Decision,
                nbrofplayers=State#state.nbrofplayers,
                position=NewPosition,
                distancetocover=State#state.distancetocover,
                energy=NewEnergy,
                speed=NewSpeed,
                roundlength=State#state.roundlength
            }.

display(ListOfStates) ->
    case ListOfStates of
        [] -> ok;
        [H|T] ->
            case H#state.decision of
                {_, {behind, X}} ->
                    io:format("{~p,~p} at position ~p~n", [H#state.pid, X,  H#state.position]);
                {_, {speed, _}} ->
                     io:format("~p at position ~p~n", [H#state.pid, H#state.position]);
                {_, {boost}} ->
                    io:format("~p at position ~p~n", [H#state.pid, H#state.position])
            end,
            display(T)
    end.



user_input_decision(PPid) ->
    case io:read("Please enter a strategy: [boost,speed,behind] ") of
        {ok, Input} ->
            case Input of
                boost ->
                    PPid ! {decision, {boost}};
                speed ->
                    case io:read("Please enter a speed: ") of
                        {ok, Speed} ->
                            PPid ! {decision, {speed, Speed}};
                        _ ->
                            PPid ! {decision, {speed, 0}}
                    end;
                behind ->
                    case io:read("Please enter a player id: ") of
                        {ok, Player} ->
                            PPid ! {decision, {behind, Player}};
                        _ ->
                            PPid ! {decision, {speed, 0}}
                    end;
                error ->
                    PPid ! {decision, {speed, 0}}
            end;
        _ ->
            PPid ! {decision, {speed, 0}}
    end.
