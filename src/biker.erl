-module(biker).
-include("kvstore.hrl").
-include("biker.hrl").
-include_lib("../deps/riak_core/include/riak_core_vnode.hrl").

-export([
         ping/0,
		 get_partitions/0,
         get/1,
         put/2,
         incr/1,
         incrby/2,
         start_race/2,
         user_input_decision/1,
         print_state/1,
         round_timeout/2,
         update_states_decision/1,
         update_states/1,
         display/1
        ]).

-define(BUCKET, "default").
-define(TIMEOUT, 5000).

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
    ok = biker:put(integer_to_list(Pid), {0, {speed, 0}}),
    io:format("~p~n", [Var]),
    %beb:beb_loop(Var, Pid, 0),
    tob:tob_loop(Var, Pid, 0),
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
            case biker:get(integer_to_list(Pid)) of
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
