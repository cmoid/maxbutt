%% SPDX-License-Identifier: GPL-2.0-only
%%
%% Copyright (C) 2026 Charles Moid
%%
%% RPC bridge between the maxbutt Emacs client and a running erlbutt node.
%% Functions return simple terms that serialise cleanly over Erlang
%% distribution and are easy to destructure in elisp.
%%
%% Thread traversal is lazy: thread/1 and thread_from/2 return only the
%% tree structure {Key, Author, Depth} without fetching message content.
%% Call get_msg_text/1 on demand when the user selects a specific entry.
-module(maxbutt).

-include("../erlbutt/apps/ssb/include/ssb.hrl").

-export([browse_feed/2,
         my_id/0,
         profile_name/1,
         post/1,
         reply/2,
         vote/2,
         get_msg/1,
         get_msg_text/1,
         log/0,
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

%% Return the display name from a feed's own profile (most recent self-about
%% with a name field), or undefined if none has been set.
profile_name(FeedId) when is_binary(FeedId) ->
    case utils:find_or_create_feed_pid(FeedId) of
        bad -> undefined;
        Pid -> ssb_feed:profile_name(Pid)
    end.

%% Publish a text post. Returns {ok, Key} or {error, Reason}.
post(Text) when is_binary(Text) ->
    Content = {[{~"type", ~"post"}, {~"text", Text}]},
    our_feed_post(Content);
post(Text) when is_list(Text) ->
    post(list_to_binary(Text)).

%% Reply to RootKey with Text. Adds tangle links so the thread is traceable.
reply(RootKey, Text) when is_binary(Text) ->
    Content = {[{~"type",   ~"post"},
                {~"text",   Text},
                {~"root",   RootKey},
                {~"branch", [RootKey]}]},
    our_feed_post(Content).

%% Vote on MsgKey: Value is 1 (like) or -1 (unlike).
vote(MsgKey, Value) when Value =:= 1 orelse Value =:= -1 ->
    Content = {[{~"type",  ~"vote"},
                {~"vote",  {[{~"link",  MsgKey},
                              {~"value", Value},
                              {~"expression", case Value of 1 -> ~"Like"; _ -> ~"Unlike" end}]}}]},
    our_feed_post(Content).

%% Fetch a message by its key. Returns the #message{} record or {error, not_found}.
get_msg(Key) when is_binary(Key) ->
    case mess_auth:get(Key) of
        not_found -> {error, not_found};
        Author    ->
            FeedPid = utils:find_or_create_feed_pid(Author),
            ssb_feed:fetch_msg(FeedPid, Key)
    end.

%% Return all messages across all feeds as {Key, Author, ContentJson} triples.
%% Ordered per-feed by sequence; feed order is unspecified.
log() ->
    LogFile = <<(config:ssb_repo_loc())/binary, "log.offset">>,
    lists:reverse(
        utils:fold_log_file(
            fun(MsgData, Acc) ->
                try
                    #message{id = Key, author = Author, content = Content} =
                        message:decode(MsgData, false),
                    ContentJson = iolist_to_binary(utils:encode_rec(Content)),
                    [{Key, Author, ContentJson} | Acc]
                catch _:_ -> Acc
                end
            end, [], LogFile)).

our_feed_post(Content) ->
    OurId   = keys:pub_key_disp(),
    FeedPid = utils:find_or_create_feed_pid(OurId),
    ok = ssb_feed:post_content(FeedPid, Content),
    #message{id = Key} = ssb_feed:fetch_last_msg(FeedPid),
    {ok, Key}.

%% Return a flat list of {Key, Author, Depth} for all messages in the
%% tangle rooted at RootKey, in depth-first order.  Depth starts at 0.
%% Message content is NOT fetched — use get_msg_text/1 on demand.
%% Returns [] if the root is unknown or has no tangle data.
thread(RootKey) ->
    try
        Tree = tangle:get_tangle(RootKey),
        enrich_with_names(flatten_thread(Tree, 0))
    catch _:_ ->
        []
    end.

%% Show the sub-thread rooted at MsgId, using TangleId as the tangle root.
thread_from(MsgId, TangleId) ->
    try
        {MsgId, Children} = tangle:descendants(MsgId, TangleId),
        Auth = mess_auth:get(MsgId),
        enrich_with_names(flatten_thread({MsgId, Auth, Children}, 0))
    catch _:_ ->
        []
    end.

%% Add profile name for each entry. Fetches each unique author once.
%% Returns [{Key, Author, Name, Depth}] where Name may be undefined.
enrich_with_names(Entries) ->
    Authors = lists:usort([Auth || {_, Auth, _} <- Entries]),
    Names   = maps:from_list([{A, profile_name(A)} || A <- Authors]),
    [{Key, Auth, maps:get(Auth, Names, undefined), Depth}
     || {Key, Auth, Depth} <- Entries].

%% Fetch the displayable text for a single message on demand.
%% Returns the text field for posts, raw content JSON for other types.
get_msg_text(Key) when is_binary(Key) ->
    case get_msg(Key) of
        {error, not_found} ->
            ~"(message not found)";
        Msg ->
            case Msg#message.content of
                {Props} ->
                    case proplists:get_value(~"text", Props) of
                        undefined -> iolist_to_binary(utils:encode_rec({Props}));
                        Text      -> Text
                    end;
                Content when is_binary(Content) ->
                    Content
            end
    end.

flatten_thread({MsgId, Auth, Children}, Depth) when is_list(Children) ->
    [{MsgId, Auth, Depth} |
     lists:flatmap(fun(Child) -> flatten_thread(Child, Depth + 1) end, Children)];
flatten_thread({MsgId, Auth}, Depth) ->
    [{MsgId, Auth, Depth}].

is_post({Props}) when is_list(Props) ->
    proplists:get_value(~"type", Props) =:= ~"post";
is_post(_) -> false.
