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
         start_race/2
        ]).

-define(BUCKET, "default").
-define(TIMEOUT, 5000).

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
    ok = kvstore:put(integer_to_list(Pid), {speed, 0}),
    io:format("~p~n", [Var]),
    beb_loop(Var, Pid),
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
                            decision={speed, 0},
                            nbrofplayers=N,
                            position=0,
                            distancetocover=100,
                            energy=112,
                            speed=0,
                            roundlength=10
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
    io:format("Round length: ~p~n", [State#state.roundlength]),
    io:format("----------------------------------------------------------~n").

wait_for_all_decisions() ->
    receive
        {ok,coucou} ->
            io:format("ok, coucou.")
    end.

beb_loop(ListOfStates, Pid) ->
    io:format("Current state of race:~n"),
    print_state(lists:nth(Pid, ListOfStates)),
    % Display the list sorted by the position in descending order.
    display(lists:reverse(lists:sort(fun(State1, State2) -> State1#state.position =< State2#state.position end, ListOfStates))),
    erlang:send_after(25000, self(), {ok, coucou}),
    NewDecision = user_input_decision(),
    io:format("Putting ~p at key: ~p~n", [NewDecision, Pid]),
    kvstore:put(integer_to_list(Pid), NewDecision),
    wait_for_all_decisions(),
    StatesWithDecision = update_states_decision(ListOfStates), % update the field decision in all states
    StatesUpdated = update_states(StatesWithDecision), % update the other fields of the states based on the decision
    beb_loop(StatesUpdated, Pid).

%% @doc From ListOfStates, gets the decision stored in the DHT and set it in
%% the list, then returns the updated list of states.
update_states_decision(ListOfStates) ->
    case ListOfStates of
        [] -> [];
        [H | T] ->
            Pid = H#state.pid,
            case kvstore:get(integer_to_list(Pid)) of
                {ok, not_found} -> Decision={speed, 0};
                {ok, Decision} -> ok
            end,
            NewState = #state { pid= Pid,
                        roundnbr=H#state.roundnbr,
                        decision=Decision,
                        nbrofplayers=H#state.nbrofplayers,
                        position=H#state.position,
                        distancetocover=H#state.distancetocover,
                        energy=H#state.energy,
                        speed=H#state.speed,
                        roundlength=H#state.roundlength
                    },
            lists:flatten([NewState | lists:flatten(update_states_decision(T))])
    end.

update_states(ListOfStates) ->
    case ListOfStates of
        [] -> [];
        [H | T] ->
            lists:flatten([calculate_new_state(H, ListOfStates) | lists:flatten(update_states(T))])
    end.

calculate_new_state(State, ListOfStates) ->
    OldRoundNbr = State#state.roundnbr,
    Decision = State#state.decision,
    OldPosition = State#state.position,
    OldEnergy = State#state.energy,
    OldSpeed = State#state.speed,
    case Decision of
        {boost} ->
            NewSpeed = OldSpeed,
            NewPosition = OldPosition + OldSpeed,
            NewEnergy = 0;
        {speed, OldSpeedChoice} ->
            NewSpeed = OldSpeedChoice,
            NewPosition = OldPosition + OldSpeedChoice,
            NewEnergy = OldEnergy - 0.12 * OldSpeedChoice * OldSpeedChoice;
        {behind, OldPlayerChoice} ->
            NewSpeed = (lists:nth(OldPlayerChoice, ListOfStates))#state.speed,
            % FIXME how to implement the position
            NewPosition = (lists:nth(OldPlayerChoice, ListOfStates))#state.position + (lists:nth(OldPlayerChoice, ListOfStates))#state.speed,
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
        [H | T] ->
            io:format("~p at position ~p~n", [H#state.pid, H#state.position]),
            display(T)
    end.

user_input_decision() ->
    case io:read("Please enter a strategy: [boost,speed,behind] ") of
        {ok, Input} ->
            case Input of
                boost ->
                    {boost};
                speed ->
                    case io:read("Please enter a speed: ") of
                        {ok, Speed} ->
                            {speed, Speed};
                        _ ->
                            {speed, 0}
                    end;
                behind ->
                    case io:read("Please enter a player id: ") of
                        {ok, Player} ->
                            {behind, Player};
                        _ ->
                            {speed, 0}
                    end;
                error ->
                    {speed, 0}
            end;
        _ ->
            {speed, 0}
    end.
