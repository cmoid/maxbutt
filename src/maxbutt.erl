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
         my_id/0,
         thread/1,
         thread_from/2]).

%% Return the last Limit messages from FeedId as a list of
%% {Seq, Key, Author, ContentJson} tuples, newest first.
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
                        #message{id       = Key,
                                 sequence = Seq,
                                 author   = Author,
                                 content  = Content} = message:decode(MsgData, false),
                        case is_post(Content) of
                            true ->
                                ContentJson = iolist_to_binary(utils:encode_rec(Content)),
                                [{Seq, Key, Author, ContentJson} | Acc];
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

%% Return a flat list of {Key, Author, Text, Depth} for all messages in the
%% tangle rooted at RootKey, in depth-first order.  Depth starts at 0.
%% Returns [] if the root is unknown or has no tangle data.
thread(RootKey) ->
    try
        Tree = tangle:get_tangle(RootKey),
        flatten_thread(Tree, 0)
    catch _:_ ->
        []
    end.

%% Show the sub-thread rooted at MsgId, using TangleId as the tangle root
%% so references are resolved correctly (replies point to the original root).
thread_from(MsgId, TangleId) ->
    try
        {MsgId, Children} = tangle:descendants(MsgId, TangleId),
        Auth = mess_auth:get(MsgId),
        flatten_thread({MsgId, Auth, Children}, 0)
    catch _:_ ->
        []
    end.

flatten_thread({MsgId, Auth, Children}, Depth) when is_list(Children) ->
    [{MsgId, Auth, msg_text(MsgId, Auth), Depth} |
     lists:flatmap(fun(Child) -> flatten_thread(Child, Depth + 1) end, Children)];
flatten_thread({MsgId, Auth}, Depth) ->
    [{MsgId, Auth, msg_text(MsgId, Auth), Depth}].

msg_text(MsgId, Auth) ->
    try
        Feed = utils:find_or_create_feed_pid(Auth),
        Msg  = ssb_feed:fetch_msg(Feed, MsgId),
        case Msg#message.content of
            {Props} -> proplists:get_value(~"text", Props, ~"");
            _       -> ~""
        end
    catch _:_ -> ~""
    end.

is_post({Props}) when is_list(Props) ->
    proplists:get_value(~"type", Props) =:= ~"post";
is_post(_) -> false.
