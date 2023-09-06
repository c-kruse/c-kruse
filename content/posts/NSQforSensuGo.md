---
title: "NSQ for Sensu Go"
date: 2023-09-06T20:27:47Z
description: |
    Evaluating NSQ for use with sensu-go as a message queue solution to
    implement round robin scheduling.
author: Christian Kruse
tags:
    - sensu-go
    - Distributed Systems
    - Queues
---

In my previous post [Sensu Go Needs a Queue](/posts/sensugoneedsaqueue) I
talked about one of Sensu's use cases for a queue. In this post I am looking at
[NSQ](https://nsq.io), a promising distributed messaging platform that is easy
to operate and scales horizontally.

After analyzing NSQ's functionality and its operation under load similar to
what I expect a large sensu-go cluster may put on it, I have found that NSQ is
not a suitable candidate for sensu-go's round robin message queue solution.
NSQ's fundamental design would necessitate significant changes to sensu-go's
architecture in order to accommodate NSQ's lack of message de-duplication, and
the connection model used by NSQ would require functional changes to the round
robin scheduling feature before it _may_ be operationally tenable.

## NSQ's Messaging Model

NSQ's messaging model is organized into `topics`, streams of data, and
`channels`, downstream consumers. Producers publish messages to topics, and a
copy of that message is sent to each channel. Within a channel there can be
many subscribers. NSQ will deliver each message in the channel to one
subscriber.

{{< figure src="/postmedia/NSQMessageModel.gif" title="Message flow through NSQ" >}}

This is model is generally compatible with sensu's round robin scheduling
feature, with a small caveat.

In the case of sensu's round robin check scheduling, requests could be
published to a topic named by sensu namespace and subscription e.g.
`default.us-west-2`, and agents could join a `roundrobin_execution` channel
subscribed to topics according to their sensu subscriptions. Backend(s) would
publish check execution requests to the appropriate topic for the check's
subscription and NSQ will deliver the message to one of the agents. Of note,
nsq imposes a rather strict character length limit of 64 for topic and channel
names. Sensu has no restrictions on subscription name length. Because of this
we would need to either impose a restrictive limit to subscription names or
come up with some consistent hashing method for translating namespace and
subscription into a topic name.

## Deployment Architecture

NSQ is cleverly designed to scale horizontally with no coordination or
replication. It consists of a few components.

### nsqd

`nsqd` is the core of nsq. It is the service that accepts, queues and delivers
messages. It was designed to be deployed alongside the service publishing
messages, and can either be ran as a standalone service or a cluster using one
or more `nsqlookupd` instances.

### nsqlookupd

`nsqlookupd` is a service that functions as a discovery service for consumers.
Each `nsqd` instance can be pointed at one or multiple `nsqlookupd` services,
and they will self-report topic and channel information to lookupd. Consumers
can then query a `nsqlookupd` instance to discover producers for topics they
are interested in.

Like `nsqd`, `nsqlookupd` does no coordination.

### The Consumer

{{< figure src="/postmedia/NSQDiscovery.png" title="Consumers discovering producers" >}}

In a scaled NSQ cluster, consumers are configured to query `nsqlookupd`
instances for `nsqd` nodes producing topics. Consumers make a persistent TCP
connection per subscription per `nsqd` node.

This connection model is of large consequence for sensu-go. In environments
with thousands of sensu agents a modest number of subscriptions could easily
generate hundreds of thousands of persistent TCP connections to each `nsqd`
instance.

## Delivery Guarantees

NSQ offers at least once delivery with some caveats, but makes no guarantees on
message delivery ordering.

### Durability

Messages are non-durable by default in NSQ. Since there is no replication,
messages are coupled with the `nsqd` instance that accepted them. By default
messages are queued in memory first, and overflow is written to disk. The
in-memory queue size can be overwritten to `0` in order to queue all messages
on disk for a performance penalty.

### At least once delivery

Assuming a `nsqd` instance does not fail, as noted above in
[Durability](#durability), messages are delivered at least once. Messages can
be delivered multiple times due to client timeouts, network partitions, etc.

### Randomness

NSQ was not necessarily designed with this use case in mind, and makes no
guarantees about the distribution of message delivery to consumers in a
channel. That said, in my performance tests I collected rough data on these
distributions and judged them to be sufficiently normal for sensu's use case.

### Ordering

Message order is not guaranteed. I've seen several anecdotal reports that
message order can appear to be LIFO in high traffic environments.

## For use with sensu

I see several barriers to including NSQ in sensu-go's round robin scheduling
implementation.

### Poor connection model fit

NSQ's connection model is likely unstable for a typical sensu deployment.
Unlike the use cases documented by NSQ, where number of consumers roughly
equals producers, the typical sensu deployment contains thousands of agents.
Consumer connections scale per subscription and producer. This might mean 25k
agents, each with 10 subscriptions and 3 nsqd nodes (message producers.) This
would result in 250k TCP connections to each of the `nsqd` instance.

In my observations `nsqd` was able to handle many consumer connections until it
was overcome with memory pressure. Its memory footprint expanded fairly
rapidly, nearly 50 KB per connection. To me this indicates that running nsqd
would likely require an unacceptable amount of resources for most deployments.

Having a large amount of outbound connections coming from each agent is also a
drawback. A major selling point of sensu-go's agent model is the single
websocket connection that eases deployment in more restrictive network
environments.

### No Message De-Duplication

NSQ lacks message de-duplication. Since NSQ has no replication or coordination
it cannot offer message de-duplication. Without this feature, some distributed
coordination will need to be developed in sensu to establish which backend
nodes are responsible for scheduling round robin checks.

### Doubts about Message Ordering

I am still unsure if strict message ordering needs to be a requirement for
sensu-go's round robin message queue, but the lack of ordering guarantees in
NSQ could prove troublesome for the use case. A check execution request
delivered late is not much better than a missed delivery. I predict the
combination of eventual discovery via `nsqlookupd` and a mix of in memory and
disk persisted messages could lead to messages being effectively dropped due to
late delivery as nsqd nodes are added and replaced.

## Performance

NSQ has published their own [performance test
results.](https://nsq.io/overview/performance.html) In these, they were able to
service ~800k messages per second in a cluster of three nsqd nodes with nine
consumers. While impressive, this is quite different from sensu's usage
patterns. In order to test how NSQ behaves with relatively low volume and a
large number of consumers, I ran my own suite.

### Goal

Show now NSQ performs under a constant load of 40k messages per second with a
fleet of 50k simulated sensu agents while subscribed to an increasing number of
NSQ topics (sensu-go subscriptions.) Since consumer connections are created by
topic, each nsqd instance should expect to see 50k connections per topic. I'd
like to discover how and where this breaks down.

###  Scenario

I set up a cluster of 3 `nsqd` nodes, a single `nsqlookupd` node, and 3
consumer nodes. The high number of connections required a lot of tuning on both
the nsqd side and consumer side. On the consumer side I quickly ran out of
local ephemeral ports on a single IP (about 2^16-1024). Not wanting to move to
a large fleet of consumer hosts, I opted to allocate additional secondary IPs
to bind from on the consumer's primary network interface. The go program I
wrote to simulate many consumers also needed customized in order to bind from a
specific local IP, and the nsq go library's default configuration needed to be
specifically tuned for both the nsqd and nsqlookupd connections.

You can see the full lab here: https://github.com/c-kruse/sensu-queue-lab/tree/main/nsq

### Results

The test was ran in stages with progressively more topics.

| topics | consumers | result |
| ----- | ------ | ----- |
| 2 | 100k | as expected |
| 3 | 150k | as expected |
| 5 | 250k | as expected |
| 6 | 300k | OOM  - instable |


{{< figure src="/postmedia/NSQPerfNSQ.png" title="NSQ metrics during performance test" >}}

In the first three stages NSQ Clients climbed to the target number, the message
rates hovered right around the desired rate (marked with a yellow dashed line),
and queue depth only briefly spiked in the time between starting the write load
and read load.) In the final stage NSQ was not stable.

{{< figure src="/postmedia/NSQPerfResources.png" title="Node resources during performance test" >}}

In the first three stages CPU and memory utilization steadily climbed. Closer
inspection showed that each consumer connection was consuming between 40 and 50
KB. Network throughput remained relatively steady as the volume of messages was
a constant and the additional traffic from consumer identification and
heartbeats is negligible. In the final stage you can see nsqd breaking down.
The memory spikes as `nsqd` begins accepting connections past 300k, it then
resets down to zero and begins climbing again. Closer inspection showed that
what was happening here was a cycle where the kernel's oom-killer was killing
the process, systemd was restarting the service, and `nsqd` began accepting
connections until it was once again endangering the system.

## Conclusion

NSQ is a very cool messaging system that scaled admirably in ways it was not
necessarily designed to scale. It was quick to learn and reasonably easy to
operate. Sadly it is not a good fit for sensu-go. Next I hope to look into more
of a full featured queueing system with a more suitable connection model and
with support for message deduplication.

### More Reading

[NSQ's Design](https://nsq.io/overview/design.html)

[NSQ's self published performance report](https://nsq.io/overview/performance.html)

[Segment's blog on scaling NSQ](https://segment.com/blog/scaling-nsq/)

[Tuning it up to 1 Million: A blog post series that helped me create enough
consumer
connections](https://www.metabrew.com/article/a-million-user-comet-application-with-mochiweb-part-3)

