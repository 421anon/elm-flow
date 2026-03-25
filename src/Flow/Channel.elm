module Flow.Channel exposing
    ( Channel
    , connect, join, filter
    , open, loop
    )

{-| Channel primitives for connecting external event sources to `Flow`.

Use `connect` when you have both a subscription source and a command to
kick off the channel, or `join` when subscriptions alone are enough.
Then consume events with `Flow.await`, `Flow.subscribe`, or `Flow.subscribeWhile`.

@docs Channel
@docs connect, join, filter
@docs open, loop

-}

import Flow.Internal exposing (Flow(..))


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
        { cmdPort : ChannelKey -> Cmd Never
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
connect : ((a -> Maybe (Flow s a)) -> Sub (Maybe (Flow s a))) -> (ChannelKey -> Cmd Never) -> Channel s a
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


{-| Fire the channel's setup command and suspend until the first value arrives.
The callback decides what to do next: `Just flow` to continue, `Nothing` to
close the subscription.

This is the low-level primitive that `Flow.await` and `Flow.subscribe` are
built on. Prefer those unless you need custom continuation logic.

-}
open : Channel s a -> (a -> Maybe (Flow s a)) -> Flow s a
open (Channel channel) callback =
    Await
        channel.cmdPort
        (\key -> channel.subPort key callback)


{-| Re-register on an already-open channel without firing the setup command again.
Used to loop inside a subscription after the channel has been opened with `open`.
-}
loop : Channel s a -> (a -> Maybe (Flow s a)) -> Flow s a
loop (Channel channel) callback =
    Await
        (\_ -> Cmd.none)
        (\key -> channel.subPort key callback)
