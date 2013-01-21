%%%
%%% Copyright 2012
%%%
%%% Licensed under the Apache License, Version 2.0 (the "License");
%%% you may not use this file except in compliance with the License.
%%% You may obtain a copy of the License at
%%%
%%%     http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing, software
%%% distributed under the License is distributed on an "AS IS" BASIS,
%%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%% See the License for the specific language governing permissions and
%%% limitations under the License.
%%%


%%%-------------------------------------------------------------------
%%% File:      node_fsm.erl
%%% @author    Marc Campbell <marc.e.campbell@gmail.com>
%%% @doc
%%% @end
%%%-----------------------------------------------------------------

%%%
%%% IMPORTANT
%%% ---------
%%%
%%% A node_fsm can be a busy fsm, and making synchronous calls into it is highly
%%% discouraged.  It's better to leave this process alone to collect log messages
%%% and move other reading logic out
%%%

-module(node_fsm).
-author('marc.e.campbell@gmail.com').
-behavior(gen_fsm).

-define(COUNTER_WRITE_INTERVAL, 5000).

-include("include/popcorn.hrl").
-include_lib("stdlib/include/ms_transform.hrl").

-export([start_link/0]).

-export([init/1,
         handle_event/3,
         handle_sync_event/4,
         handle_info/3,
         terminate/3,
         code_change/4]).

-export([
    'LOGGING'/2,
    'LOGGING'/3]).

-record(state, {most_recent_version   :: string(),
                popcorn_node          :: #popcorn_node{},
                event_counter         :: number(),
                track_rps             :: boolean()}).

start_link() -> gen_fsm:start_link(?MODULE, [], []).

init([]) ->
    process_flag(trap_exit, true),

    erlang:send_after(?COUNTER_WRITE_INTERVAL, self(), write_counter),

    {ok, Rps_Options} = case application:get_env(popcorn, rps_tracking) of
                            undefined ->  {ok, [{enabled, false}]};
                            Rps_Config -> Rps_Config
                        end,

    {ok, 'LOGGING', #state{event_counter = 0,
                           track_rps     = proplists:get_value(enabled, Rps_Options)}}.

'LOGGING'({log_message, Popcorn_Node, Log_Message}, State) ->
    try
        %%?POPCORN_DEBUG_MSG("State#state.track_rps = ~p", [State#state.track_rps]),
        case State#state.track_rps of
            true  -> rps:incr(storage);
            false -> ok
        end,

        Pid = pg2:get_closest_pid('storage'),

        %% log the message
        gen_server:cast(Pid, {new_log_message, Log_Message}),

        %% increment the total event counter
        ?INCREMENT_COUNTER_LATER(?TOTAL_EVENT_COUNTER),

        %% Notify any streams connected
        log_stream_manager:new_log_message(Log_Message)
    catch
        _:Error ->
            io:format("Couldn't log message:~nMessage: ~p~nNode: ~p~nError: ~p~nStack: ~p~n",
                        [Log_Message, Popcorn_Node, Error, erlang:get_stacktrace()])
    end,
    {next_state, 'LOGGING', State#state{event_counter = State#state.event_counter + 1}}.

'LOGGING'({deserialize_popcorn_node, Popcorn_Node}, _From, State) ->
    Node_Name        = Popcorn_Node#popcorn_node.node_name,
    Prefix           = <<"raw_logs__">>,

    ets:insert(current_roles, {Popcorn_Node#popcorn_node.role, self()}),

    {reply, ok, 'LOGGING', State#state{popcorn_node          = Popcorn_Node}};

'LOGGING'({set_popcorn_node, Popcorn_Node}, _From, State) ->
    gen_server:cast(?STORAGE_PID, {add_node, Popcorn_Node}),

    Node_Name        = Popcorn_Node#popcorn_node.node_name,
    Prefix           = <<"raw_logs__">>,

    %% add this node to the "roles" tets table
    ets:insert(current_roles, {Popcorn_Node#popcorn_node.role, self()}),

    {reply, ok, 'LOGGING', State#state{popcorn_node          = Popcorn_Node}}.

handle_event(decrement_counter, State_Name, State) ->
    {next_state, State_Name, State#state{event_counter = State#state.event_counter - 1}};

handle_event(Event, StateName, State)                 -> {stop, {StateName, undefined_event, Event}, State}.
handle_sync_event(Event, _From, StateName, State)     -> {stop, {StateName, undefined_event, Event}, State}.

handle_info(write_counter, State_Name, State) ->
    Popcorn_Node = State#state.popcorn_node,
    gen_server:cast(?STORAGE_PID, {increment_counter, ?NODE_EVENT_COUNTER(Popcorn_Node#popcorn_node.node_name), State#state.event_counter}),
    erlang:send_after(?COUNTER_WRITE_INTERVAL, self(), write_counter),

    {next_state, State_Name, State#state{event_counter = 0}};

handle_info(_Info, StateName, State)                  -> {next_state, StateName, State}.
terminate(_Reason, _StateName, State)                 -> ok.
code_change(_OldVsn, StateName, StateData, _Extra)    -> {ok, StateName, StateData}.
