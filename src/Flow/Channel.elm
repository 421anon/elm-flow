module Flow.Channel exposing
    ( Channel
    , connect, join, filter
    , accept, acceptOne, acceptUntil
    )

{-| Channel primitives for connecting external event sources to `Flow`.

Use `connect` when you have both a subscription source and a command to
kick off the channel, or `join` when subscriptions alone are enough.
Then consume events with `Flow.await` (one event), `Flow.Channel.acceptUntil`
(events until a condition), or `Flow.subscribe` (all events indefinitely).

@docs Channel
@docs connect, join, filter
@docs accept, acceptOne, acceptUntil

-}

import Flow.Internal exposing (Flow(..), andThen, async)


{-| Per-subscription key passed to channel ports.

Use this to correlate a subscribe request and the values emitted for it.

-}
type alias ChannelKey =
    String


{-| An opaque handle describing how to connect an external event source to a
`Flow` pipeline. Build one with `connect` or `join`, then pass it to
`Flow.await` or `Flow.subscribe`.
-}
type Channel s a
    = Channel
        { cmdPort : ChannelKey -> Cmd (Flow s a)
        , subPort : ChannelKey -> (a -> Maybe (Flow s a)) -> Sub (Maybe (Flow s a))
        }


{-| Build a channel from a subscription source and a command that opens or
attaches it. The command is fired once when the channel is first awaited.

    -- Port declarations:
    --   port onMessage : (String -> msg) -> Sub msg
    --   port subscribe : String -> Cmd msg

    myChannel : Channel Model String
    myChannel =
        Flow.Channel.connect
            (\callback -> Ports.onMessage callback)
            (\_ -> Ports.subscribe "myTopic")

-}
connect : ((a -> Maybe (Flow s a)) -> Sub (Maybe (Flow s a))) -> (ChannelKey -> Cmd (Flow s a)) -> Channel s a
connect subPort cmdPort =
    Channel
        { cmdPort = cmdPort
        , subPort = \_ -> subPort
        }


{-| Build a channel from a subscription source when no startup command is needed.

    -- Port declaration:
    --   port onKeyDown : (String -> msg) -> Sub msg

    keyChannel : Channel Model String
    keyChannel =
        Flow.Channel.join (\callback -> Ports.onKeyDown callback)

-}
join : ((a -> Maybe (Flow s a)) -> Sub (Maybe (Flow s a))) -> Channel s a
join subPort =
    Channel
        { cmdPort = \_ -> Cmd.none
        , subPort = \_ -> subPort
        }


{-| Filter events for a channel. Only events for which the predicate returns
`True` are forwarded; others are silently dropped.

The predicate receives the internal channel key and the event payload.
In most cases you only need the payload:

    Flow.Channel.filter (\_ msg -> msg /= "") myChannel

-}
filter : (ChannelKey -> a -> Bool) -> Channel s a -> Channel s a
filter predicate (Channel channel) =
    Channel
        { channel
            | subPort =
                \key callback ->
                    channel.subPort key
                        (\a ->
                            if predicate key a then
                                callback a

                            else
                                Nothing
                        )
        }


awaitWith : (ChannelKey -> Cmd (Flow s a)) -> Channel s a -> (a -> Maybe (Flow s a)) -> Flow s a
awaitWith cmd (Channel channel) callback =
    Await
        (\key -> Cmd.map (\_ -> Batch []) (cmd key))
        (\key -> channel.subPort key callback)


{-| Subscribe to a channel and run the handler for every incoming event,
indefinitely. The subscription runs for the lifetime of the program with
no built-in way to stop it.

    listenForever : Flow Model ()
    listenForever =
        Flow.Channel.accept
            (\msg -> Flow.modify (\m -> { m | lastMessage = msg }))
            myChannel

-}
accept : (a -> Flow s ()) -> Channel s a -> Flow s a
accept handler ((Channel channel) as ch) =
    let
        continuation a =
            Just (andThen loop (async (handler a)))

        loop () =
            awaitWith (\_ -> Cmd.none) ch continuation
    in
    awaitWith channel.cmdPort ch continuation


{-| Wait for events from a channel, discarding each one until the predicate
returns `True`. Returns the first event that satisfies the predicate and
then closes the channel.

    -- wait until the server sends "done"
    Flow.Channel.acceptUntil (\msg -> msg == "done") myChannel

-}
acceptUntil : (a -> Bool) -> Channel s a -> Flow s a
acceptUntil shouldStop ((Channel channel) as ch) =
    awaitWith channel.cmdPort
        ch
        (\a ->
            if shouldStop a then
                Just (Pure a)

            else
                Just (acceptUntil shouldStop ch)
        )


{-| Wait for the next single event from a channel and return it. The channel
is closed after the first event arrives.

    -- read one message then continue
    Flow.Channel.acceptOne myChannel
        |> Flow.andThen (\msg -> Flow.modify (\m -> { m | lastMessage = msg }))

-}
acceptOne : Channel s a -> Flow s a
acceptOne =
    acceptUntil (always True)
