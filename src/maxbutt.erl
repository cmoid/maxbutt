%% SPDX-License-Identifier: GPL-2.0-only
%%
%% Copyright (C) 2026 Charles Moid
%%
%% RPC bridge between the maxbutt Emacs client and a running erlbutt node.
%% Functions return simple terms that serialise cleanly over Erlang
%% distribution and are easy to destructure in elisp.
%%
%% maxbutt runs INSIDE the node's BEAM (loaded via distel), which is what
%% makes it useful and also what makes it fragile: it can reach anything,
%% so it has historically reached into whatever module happened to hold
%% the data.  When erlbutt reorganised its views in July 2026 this module
%% broke silently — `friends` had become `ssb_social_graph`, the display
%% name had moved to `ssb_feed_meta`, and `log/0` was reading a global
%% `log.offset` that no longer gets written, returning nothing at all.
%%
%% So: reads go through the core views' public APIs, and anything that
%% CONTROLS the node goes through the admin namespace (apps/admin) — the
%% same handlers sbutt and any other client use, just called in-process
%% rather than over muxrpc.  See doc/persistence.md §5 in erlbutt.
%%
%% Thread traversal is lazy: thread/1 and thread_from/2 return only the
%% tree structure {Key, Author, Depth} without fetching message content.
%% Call get_msg_text/1 on demand when the user selects a specific entry.
-module(maxbutt).

-include_lib("ssb/include/ssb.hrl").

-export([browse_feed/2,
         my_id/0,
         profile_name/1,
         following/0,
         following/1,
         post/1,
         reply/2,
         vote/2,
         follow/1,
         unfollow/1,
         block/1,
         get_msg/1,
         get_msg_text/1,
         log/0,
         thread/1,
         thread_from/2,
         dialer/0,
         dialer/1,
         dialer_toggle/0,
         status/0,
         views/0]).

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

%% Return the display name a feed has set for itself, or undefined.
%% Served from the ssb_feed_meta core view, which holds the latest
%% self-asserted value of every `about` field, not just the name.
profile_name(FeedId) when is_binary(FeedId) ->
    ssb_feed_meta:name(FeedId).

%% Feeds the local node follows, as {FeedId, Name} pairs sorted by id.
%% Name is undefined when the feed has not set one.
following() ->
    following(keys:pub_key_disp()).

%% Feeds FeedId follows, as {FeedId, Name} pairs sorted by id.
following(FeedId) when is_binary(FeedId) ->
    [{Id, profile_name(Id)}
     || Id <- lists:sort(ssb_social_graph:direct_follows(FeedId))].

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

%% Follow a feed. Publishes a contact message with following:true.
follow(FeedId) when is_binary(FeedId) ->
    Content = {[{~"type",      ~"contact"},
                {~"contact",   FeedId},
                {~"following", true}]},
    our_feed_post(Content).

%% Unfollow a feed. Publishes a contact message with following:false.
unfollow(FeedId) when is_binary(FeedId) ->
    Content = {[{~"type",      ~"contact"},
                {~"contact",   FeedId},
                {~"following", false}]},
    our_feed_post(Content).

%% Block a feed. Publishes a contact message with blocking:true and following:false.
block(FeedId) when is_binary(FeedId) ->
    Content = {[{~"type",      ~"contact"},
                {~"contact",   FeedId},
                {~"following", false},
                {~"blocking",  true}]},
    our_feed_post(Content).

%% Fetch a message by its key. Returns the #message{} record or {error, not_found}.
get_msg(Key) when is_binary(Key) ->
    case mess_auth:get(Key) of
        not_found -> {error, not_found};
        Author    ->
            FeedPid = utils:find_or_create_feed_pid(Author),
            ssb_feed:fetch_msg(FeedPid, Key)
    end.

%% Return every stored message as {Key, Author, ContentJson} triples, in
%% ARRIVAL order across all feeds.
%%
%% This used to fold a global <repo>/log.offset.  That file was retired
%% when the ingest journal landed and is no longer written, so this
%% quietly returned [] on any node built since — the failure mode that
%% motivated porting this module.  The journal is the replacement: it
%% records {FeedId, Seq} refs in arrival order and resolves bodies from
%% the per-feed store.
log() ->
    lists:reverse(
        ingest_journal:stream_messages(
            fun(MsgData, Acc) ->
                try
                    #message{id = Key, author = Author, content = Content} =
                        message:decode(MsgData, false),
                    ContentJson = iolist_to_binary(utils:encode_rec(Content)),
                    [{Key, Author, ContentJson} | Acc]
                catch _:_ -> Acc
                end
            end, [])).

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

%%% Node control ---------------------------------------------------------
%%%
%%% Routed through the admin namespace rather than calling peer_dialer and
%%% friends directly, so there is one definition of what "the control
%%% plane" is and maxbutt inherits new admin methods for free.

%% Current peer-dialer state as {ok, enabled | disabled}.
dialer() ->
    {ok, dialer_state()}.

%% Turn automatic peer dialing on or off; returns {ok, NewState}.
dialer(on)  -> dialer(true);
dialer(off) -> dialer(false);
dialer(true) ->
    _ = admin([~"dialer", ~"enable"]),
    dialer();
dialer(false) ->
    _ = admin([~"dialer", ~"disable"]),
    dialer().

%% Flip the peer-dialer state; returns {ok, enabled | disabled}.
dialer_toggle() ->
    dialer(dialer_state() =/= enabled).

dialer_state() ->
    case admin([~"dialer", ~"status"]) of
        {ok, {Props}} ->
            case proplists:get_value(~"enabled", Props) of
                true -> enabled;
                _    -> disabled
            end;
        _ ->
            unknown
    end.

%% Node summary: [{Key, Value}] with binary keys — id, uptimeMs, feeds,
%% dialerEnabled, replicationHops, archiveLength, isRoom, networkIds,
%% views.
status() ->
    case admin([~"status"]) of
        {ok, {Props}} -> Props;
        Err           -> Err
    end.

%% Registered views as {Module, Class, Version, Feeds, CaughtUp} tuples,
%% core views first.  `false` for CaughtUp means the view is still
%% folding and its answers are incomplete.
views() ->
    case admin([~"views", ~"list"]) of
        {ok, Rows} when is_list(Rows) ->
            [{binary_to_atom(gv(~"module", P), utf8),
              binary_to_atom(gv(~"class", P), utf8),
              gv(~"version", P),
              gv(~"feeds", P),
              gv(~"caughtUp", P)} || {P} <- Rows];
        Err ->
            Err
    end.

gv(Key, Props) ->
    proplists:get_value(Key, Props).

%% Call an admin method in-process.  maxbutt is in the node's BEAM, so it
%% does not need muxrpc to reach the admin app — but it should go through
%% the same handler every other client uses.  The caller is `owner`, which
%% is what a local operator is.
admin(Path) ->
    admin(Path, []).

admin(Path, Args) ->
    try admin_rpc:handle_rpc([~"admin" | Path], Args,
                             #{class => owner, feed_id => keys:pub_key_disp()}) of
        {reply, Reply}  -> {ok, Reply};
        {error, Reason} -> {error, Reason};
        Other           -> {error, Other}
    catch Class:Reason ->
            {error, {Class, Reason}}
    end.
