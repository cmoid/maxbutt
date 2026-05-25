%% SPDX-License-Identifier: GPL-2.0-only
%%
%% Copyright (C) 2026 Charles Moid
%%
%% RPC bridge between the maxbutt Emacs client and a running erlbutt node.
%% Functions here are designed to return simple terms that serialise cleanly
%% over the Erlang distribution protocol and are easy to destructure in elisp.
-module(maxbutt).

-include("../erlbutt/apps/ssb/include/ssb.hrl").

-export([browse_feed/2,
         my_id/0]).

%% Return the last Limit messages from FeedId as a list of
%% {Seq, Author, ContentJson} tuples, newest first.
%% Returns {error, feed_not_found} if the feed is unknown.
browse_feed(FeedId, Limit) ->
    Pid = utils:find_or_create_feed_pid(FeedId),
    case Pid of
        bad ->
            {error, feed_not_found};
        _ ->
            Msgs = ssb_feed:foldl(Pid,
                fun(MsgData, Acc) ->
                    try
                        #message{sequence = Seq,
                                 author   = Author,
                                 content  = Content} = message:decode(MsgData, false),
                        case is_post(Content) of
                            true ->
                                ContentJson = iolist_to_binary(utils:encode_rec(Content)),
                                [{Seq, Author, ContentJson} | Acc];
                            false ->
                                Acc
                        end
                    catch _:_ ->
                        Acc
                    end
                end,
                []),
            %% foldl builds newest-first via cons; sublist takes the first Limit
            lists:sublist(Msgs, Limit)
    end.

%% Return the local node's public feed ID (the @key=.ed25519 display form).
my_id() ->
    keys:pub_key_disp().

is_post({Props}) when is_list(Props) ->
    proplists:get_value(~"type", Props) =:= ~"post";
is_post(_) -> false.
