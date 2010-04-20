%%%-------------------------------------------------------------------
%%% File    : babysitter.erl
%%% Author  : Ari Lerner
%%% Description : 
%%%
%%% Created :  Thu Dec 24 15:10:38 PST 2009
%%%-------------------------------------------------------------------

-module (babysitter).
-behaviour(gen_server).

%% API
-export ([
  spawn_new/2, stop_process/1,
  list/0
]).

-export([start_link/0, start_link/1, stop/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

% only for tests
-export ([
  build_exec_opts/2,
  build_port_command/1
]).

-define(SERVER, ?MODULE).
-define (PID_MONITOR_TABLE, 'babysitter_mon').

-record(state, {
  port,
  last_trans  = 0,            % Last transaction number sent to port
  trans       = queue:new(),  % Queue of outstanding transactions sent to port
  registry    = ets:new(?PID_MONITOR_TABLE, [protected,named_table]), % Pids to notify when an OsPid exits
  debug       = false
}).

%%====================================================================
%% API
%%====================================================================
spawn_new(Command, Options) -> 
  gen_server:call(?SERVER, {port, {run, Command, Options}}).

stop_process(Arg) ->
  handle_stop_process(Arg).

list() ->
  gen_server:call(?SERVER, {port, {list}}).
  
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
start_link() ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

start_link(Options) ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [Options], []).

stop() ->
  gen_server:call(?SERVER, stop).
%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%                         {ok, State, Timeout} |
%%                         ignore               |
%%                         {stop, Reason}
%% Description: Initiates the server
%%--------------------------------------------------------------------
init([Options]) ->
  process_flag(trap_exit, true),  
  Exe   = build_port_command(Options),
  Debug = proplists:get_value(verbose, Options, default(verbose)),
  try
    debug(Debug, "exec: port program: ~s\n", [Exe]),
    Port = erlang:open_port({spawn, Exe}, [binary, exit_status, {packet, 2}, nouse_stdio, hide]),
    {ok, #state{port=Port, debug=Debug}}
  catch _:Reason ->
    {stop, io:format("Error starting port '~p': ~200p", [Exe, Reason])}
  end.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call({port, {run, _Command, _Options} = T}, From, #state{last_trans=_Last} = State) -> handle_port_call(T, From, State);
handle_call({port, {kill, _Command, _Options} = T}, From, #state{last_trans=_Last} = State) -> handle_port_call(T, From, State);
handle_call(_Request, _From, State) ->
  Reply = ok,
  {reply, Reply, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
  {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info({Port, {data, Bin}}, #state{port=Port, debug=Debug, trans = Trans} = State) ->
  Term = erlang:binary_to_term(Bin),
  case Term of
    {0, {exit_status, OsPid, Status}} ->
        debug(Debug, "Pid ~w exited with status: {~w,~w}\n", [OsPid, (Status band 16#FF00 bsr 8), Status band 127]),
        erlang:display(OsPid),
        notify_ospid_owner(OsPid, Status),
        {noreply, State};
    {N, Reply} when N =/= 0 ->
      case get_transaction(Trans, N) of
        {true, {Pid,_} = From, Q} ->
          NewReply = add_monitor(Reply, Pid, Debug),
          gen_server:reply(From, NewReply);
        {false, Q} ->
          erlang:display("erp"),
          ok
      end,
      {noreply, State#state{trans=Q}};
    Else ->
      erlang:display("Else: ~p~n", Else)
  end;
handle_info({'EXIT', Pid, Reason}, State) ->
    % OsPid's Pid owner died. Kill linked OsPid.
    erlang:display("died"),
    do_unlink_ospid(Pid, Reason, State),
    {noreply, State};
handle_info(Info, State) ->
  erlang:display("Other info: " ++ Info),
  {noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
  ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------
handle_port_call(T, From, #state{last_trans = LastTrans, trans = OldTransQ} = State) ->
  try
    TransId = next_trans(LastTrans),
    erlang:port_command(State#state.port, term_to_binary({TransId, T})),
    {noreply, State#state{trans = queue:in({TransId, From}, OldTransQ)}}
  catch _:{error, Why} ->
    {reply, {error, Why}, State}
  end.
  
handle_stop_process(Pid) when is_pid(Pid) ->
  ok.

%% Add a link for Pid to OsPid if requested.
add_monitor({ok, OsPid}, Pid, Debug) when is_integer(OsPid) ->
  % This is a reply to a run/run_link command. The port program indicates
  % of creating a new OsPid process.
  % Spawn a light-weight process responsible for monitoring this OsPid
  Self = self(),
  Process = spawn_link(fun() -> ospid_init(Pid, OsPid, Self, Debug) end),
  ets:insert(?PID_MONITOR_TABLE, [{OsPid, Process}, {Process, OsPid}]),
  {ok, Process, OsPid};
add_monitor(Reply, _Pid, _Debug) ->
  Reply.

%%----------------------------------------------------------------------
%% @spec (Pid, OsPid::integer(), LinkType, Parent, Debug::boolean()) -> void()
%% @doc Every OsPid is associated with an Erlang process started with
%%      this function. The `Parent' is the ?MODULE port manager that
%%      spawned this process and linked to it. `Pid' is the process
%%      that ran an OS command associated with OsPid. If that process
%%      requested a link (LinkType = 'link') we'll link to it.
%% @end
%% @private
%%----------------------------------------------------------------------
ospid_init(Pid, OsPid, Parent, Debug) ->
  process_flag(trap_exit, true),
  link(Pid),
  ospid_loop({Pid, OsPid, Parent, Debug}).

ospid_loop({Pid, OsPid, Parent, Debug} = State) ->
  receive
    {{From, Ref}, ospid} ->
      From ! {Ref, {ok, OsPid}},
      ospid_loop(State);
    {'DOWN', OsPid, {exit_status, Status}} ->
      debug(Debug, "~w ~w got down message (~w)\n", [self(), OsPid, status(Status)]),
      % OS process died
      exit({exit_status, Status});
    {'EXIT', Pid, Reason} ->
      % Pid died
      debug(Debug, "~w ~w got exit from linked ~w: ~p\n", [self(), OsPid, Pid, Reason]),
      exit({owner_died, Reason});
    {'EXIT', Parent, Reason} ->
      % Port program died
      debug(Debug, "~w ~w got exit from parent ~w: ~p\n", [self(), OsPid, Parent, Reason]),
      exit({port_closed, Reason});
    Other ->
      error_logger:warning_msg("~w - unknown msg: ~p\n", [self(), Other]),
      ospid_loop(State)
  end.

notify_ospid_owner(OsPid, Status) ->
  % See if there is a Pid owner of this OsPid. If so, sent the 'DOWN' message.
  case ets:lookup(?PID_MONITOR_TABLE, OsPid) of
    [{_OsPid, Pid}] ->
      unlink(Pid),
      Pid ! {'DOWN', OsPid, {exit_status, Status}},
      ets:delete(?PID_MONITOR_TABLE, {Pid, OsPid}),
      ets:delete(?PID_MONITOR_TABLE, {OsPid, Pid});
    [] ->
      %error_logger:warning_msg("Owner ~w not found\n", [OsPid]),
      ok
  end.

do_unlink_ospid(Pid, _Reason, State) ->
  case ets:lookup(?PID_MONITOR_TABLE, Pid) of
    [{_Pid, OsPid}] when is_integer(OsPid) ->
      debug(State#state.debug, "Pid ~p died. Killing linked OsPid ~w\n", [Pid, OsPid]),
      ets:delete(?PID_MONITOR_TABLE, {Pid, OsPid}),
      ets:delete(?PID_MONITOR_TABLE, {OsPid, Pid}),
      erlang:port_command(State#state.port, term_to_binary({0, {stop, OsPid}}));
    _ ->
      ok 
  end.

status(Status) when is_integer(Status) ->
    case {Status band 16#FF00 bsr 8, (Status band 128) =:= 128, Status band 127} of
    {Stat, _, 0}      -> {status, Stat};
    {_, Core, Signal} -> {signal, Signal, Core}
    end.


get_transaction(Q, I) -> get_transaction(Q, I, Q).
get_transaction(Q, I, OldQ) ->
  case queue:out(Q) of
    {{value, {I, From}}, Q2} ->
      {true, From, Q2};
    {empty, _} ->
      erlang:display("empty q"),
      {false, OldQ};
    {_E, Q2} ->
      get_transaction(Q2, I, OldQ)
    end.


%%-------------------------------------------------------------------------
%% @spec () -> Default::exec_options()
%% @doc Provide default value of a given option.
%% @end
%%-------------------------------------------------------------------------
default() -> 
    [{debug, false},    % Debug mode of the port program. 
     {verbose, false},  % Verbose print of events on the Erlang side.
     {port_program, default(port_program)}].

default(port_program) -> 
    % Get architecture (e.g. i386-linux)
    Dir = filename:dirname(filename:dirname(code:which(?MODULE))),
    filename:join([Dir, "..", "priv", "bin", "babysitter"]);
default(Option) ->
  search_for_application_value(Option).

% Look for it at the environment level first
search_for_application_value(Param) ->
  case application:get_env(babysitter, Param) of
    undefined         -> search_for_application_value_from_environment(Param);
    {ok, undefined}   -> search_for_application_value_from_environment(Param);
    {ok, V}    -> V
  end.

search_for_application_value_from_environment(Param) ->
  EnvParam = string:to_upper(erlang:atom_to_list(Param)),
  case os:getenv(EnvParam) of
    false -> proplists:get_value(Param, default());
    E -> E
  end.


% Build the port process command
build_port_command(Opts) ->
  Args = build_port_command1(Opts, []),
  proplists:get_value(port_program, Opts, default(port_program)) ++ lists:flatten([" -n"|Args]).

% Fold down the option list and collect the options for the port program
build_port_command1([], Acc) -> Acc;
build_port_command1([{verbose, _V} = T | Rest], Acc) -> build_port_command1(Rest, [port_command_option(T) | Acc]);
build_port_command1([{debug, X} = T|Rest], Acc) when is_integer(X) -> 
  build_port_command1(Rest, [port_command_option(T) | Acc]);
build_port_command1([_H|Rest], Acc) -> build_port_command1(Rest, Acc).

% Purely to clean this up
port_command_option({debug, X}) when is_integer(X) -> io:fwrite(" --debug ~w", [X]);
port_command_option({debug, _Else}) -> " -- debug 4";
port_command_option(_) -> "".

% Accept only know execution options
% Throw the rest away
build_exec_opts([], Acc) -> Acc;
build_exec_opts([{cd, _V}=T|Rest], Acc) -> build_exec_opts(Rest, [T|Acc]);
build_exec_opts([{env, _V}=T|Rest], Acc) -> build_exec_opts(Rest, [T|Acc]);
build_exec_opts([{nice, _V}=T|Rest], Acc) -> build_exec_opts(Rest, [T|Acc]);
build_exec_opts([{stdout, _V}=T|Rest], Acc) -> build_exec_opts(Rest, [T|Acc]);
build_exec_opts([{stderr, _V}=T|Rest], Acc) -> build_exec_opts(Rest, [T|Acc]);
build_exec_opts([_Else|Rest], Acc) -> build_exec_opts(Rest, Acc).

% Fetch values and defaults
% fetch_value(env, Opts) -> opt_or_default(env, [], Opts);
% fetch_value(cd, Opts) -> opt_or_default(cd, undefined, Opts);
% fetch_value(skel, Opts) -> opt_or_default(skel, undefined, Opts);
% fetch_value(start_command, Opts) -> opt_or_default(start_command, "thin -- -R config.ru start", Opts).

% opt_or_default(Param, Default, Opts) ->
%   case proplists:get_value(Param, Opts) of
%     undefined -> Default;
%     V -> V
%   end.

% PRIVATE
debug(false, _, _) ->     ok;
debug(true, Fmt, Args) -> io:format(Fmt, Args).

% Check if the call is a legal maneuver
% is_port_command({start, {run, _Cmd, Options} = T, Link}, State) ->
%   check_cmd_options(Options, State),
%   {ok, T, Link};
% is_port_command({list} = T, _State) -> 
%   {ok, T, undefined};
% is_port_command({stop, OsPid}=T, _State) when is_integer(OsPid) -> 
%   {ok, T, undefined};
% is_port_command({stop, Pid}, _State) when is_pid(Pid) ->
%   case ets:lookup(exec_mon, Pid) of
%     [{Pid, OsPid}]  -> {ok, {stop, OsPid}, undefined};
%     []              -> throw({error, no_process})
%   end;
% is_port_command({kill, OsPid, Sig}=T, _State) when is_integer(OsPid),is_integer(Sig) -> 
%   {ok, T, undefined};
% is_port_command({kill, Pid, Sig}, _State) when is_pid(Pid),is_integer(Sig) -> 
%   case ets:lookup(exec_mon, Pid) of
%     [{Pid, OsPid}]  -> {ok, {kill, OsPid, Sig}, undefined};
%     []              -> throw({error, no_process})
%   end.
% 
% % Check on the command options
% check_cmd_options([{cd, Dir}|T], State) when is_list(Dir) ->
%   check_cmd_options(T, State);
% check_cmd_options([{env, Env}|T], State) when is_list(Env) ->
%   check_cmd_options(T, State);
% check_cmd_options([{do_before, Cmd}|T], State) when is_list(Cmd) ->
%   check_cmd_options(T, State);
% check_cmd_options([{do_after, Cmd}|T], State) when is_list(Cmd) ->
%   check_cmd_options(T, State);
% check_cmd_options([{nice, I}|T], State) when is_integer(I), I >= -20, I =< 20 ->
%   check_cmd_options(T, State);
% check_cmd_options([{Std, I}|T], State) when Std=:=stderr, I=/=Std; Std=:=stdout, I=/=Std ->
%   if I=:=null; I=:=stderr; I=:=stdout; is_list(I); 
%     is_tuple(I), tuple_size(I)=:=2, element(1,I)=:="append", is_list(element(2,I)) ->  
%       check_cmd_options(T, State);
%   true -> 
%     throw({error, io:format("Invalid ~w option ~p", [Std, I])})
%   end;
% check_cmd_options([Other|_], _State) -> throw({error, {invalid_option, Other}});
% check_cmd_options([], _State)        -> ok.


% So that we can get a unique id for each communication
next_trans(I) when I < 268435455 -> I+1;
next_trans(_) -> 1.
