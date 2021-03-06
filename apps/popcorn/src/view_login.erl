-module(view_login).
-author('marc.e.campbell@gmail.com').
-behaviour(view_generic).

-include("include/popcorn.hrl").

-export([username/1,
         avatar_path/1,
         head_includes/1]).

-spec username(dict()) -> string().
username(Context) ->
  mustache:get(username, Context).

-spec avatar_path(dict()) -> string().
avatar_path(Context) ->
  "http://www.gravatar.com/avatar/" ++ popcorn_util:md5_hex(mustache:get(username, Context)).

-spec head_includes(dict()) -> list().
head_includes(_) ->
  popcorn_util:head_includes().
