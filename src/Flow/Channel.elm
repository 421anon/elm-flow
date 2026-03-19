module Flow.Channel exposing
    ( Channel, ChannelKey
    , connect, join, filter
    , accept, acceptOne, acceptUntil
    )

{-| Channel primitives for connecting external event sources to `Flow`.

Use `connect` when you have both a subscription source and an optional command
to kick off/attach the channel, or `join` when you only need subscriptions.
Then consume events with `Flow.await`, `Flow.awaitUntil`, or `Flow.subscribe`.

@docs Channel, ChannelKey
@docs connect, join, filter
@docs accept, acceptOne, acceptUntil

-}

import Flow.Internal exposing (Flow(..), andThen, async)


{-| Per-subscription key passed to channel ports.

Use this to correlate a subscribe request and the values emitted for it.

-}
type alias ChannelKey =
    String


{-| Opaque channel handle that describes how to connect an external event source
to a `Flow` pipeline.
-}
type Channel s a
    = Channel
        { cmdPort : ChannelKey -> Cmd (Flow s a)
        , subPort : ChannelKey -> (a -> Maybe (Flow s a)) -> Sub (Maybe (Flow s a))
        }


{-| Build a channel from both a subscription source and a command that starts
or attaches it.
-}
connect : ((a -> Maybe (Flow s a)) -> Sub (Maybe (Flow s a))) -> (ChannelKey -> Cmd (Flow s a)) -> Channel s a
connect subPort cmdPort =
    Channel
        { cmdPort = cmdPort
        , subPort = \_ -> subPort
        }


{-| Build a channel from subscriptions only.

Use this when no startup command is required.

-}
join : ((a -> Maybe (Flow s a)) -> Sub (Maybe (Flow s a))) -> Channel s a
join subPort =
    Channel
        { cmdPort = \_ -> Cmd.none
        , subPort = \_ -> subPort
        }


{-| Filter events for a channel using both the generated `ChannelKey` and the
event payload.
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


{-| Subscribe to a channel and handle every incoming event indefinitely.
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


{-| Wait for channel events until the predicate returns `True`, then return
that final event.
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


{-| Wait for a single event from a channel and return it.
-}
acceptOne : Channel s a -> Flow s a
acceptOne =
    acceptUntil (always True)
