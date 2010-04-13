%%%-------------------------------------------------------------------
%%% File    : babysitter_app.erl
%%% Author  : Ari Lerner
%%% Description : 
%%%
%%% Created :  Thu Dec 24 15:07:11 PST 2009
%%%-------------------------------------------------------------------

-module (babysitter_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_Type, Args) -> 
  io:format("Args: ~p~n", [Args]),
  lists:map(fun(A) ->
    io:format("Starting ~p...~n", [A]),
    A:start_link([{config, "./docs/apps"}, {debug, true}])
  end, [babysitter_port]),
  io:format("Starting babysitter~n"),
  babysitter_sup:start_link().

stop(_State) -> 
  io:format("Stopping babysitter_app...~n"),
  ok.
