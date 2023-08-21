---
title: "Sensu Go Needs a Queue"
date: 2023-08-19T11:35:28-07:00
description: Learnings on sensu-go's need for a message queue
author: Christian Kruse
draft: false
tags:
    - sensu-go
    - Distributed Systems
    - Queues
---

Over the past two years I've been working with the supremely talented
[sensu](https://sensu.io) team developing and maintaining the open source monitoring
solution, [sensu-go](https://github.com/sensu/sensu-go). Throughout this journey a
significant challenge has emerged - persistent reliability and stability
problems in large deployments pushing the limits of sensu-go and its database,
etcd. With the next major version of sensu-go, 7.0, we aim to apply our
learnings and alleviate these stability and reliability issues.

One last key feature that needs reimagined is the round robin scheduling
feature. In order to implement this feature reliably, I believe we need a
message queuing system. Over the next few posts I hope to investigate potential
queueing systems for their suitability. First, though, some background on the
current solution and its shortcomings.

## A primer on sensu-go

Sensu-go is a distributed system consisting of a number of (mostly) stateless
backend nodes, an etcd database cluster, and upwards of 20k connected agent
processes. In normal operation, agents open up a bi-directional connection to
one of the backend nodes, the backend registers the agent's presence in the etcd
database, and scheduled events are sent best effort from the backends to their
connected agents based on configured "subscription" tags. This is the heart of
sensu-go, a centralized monitoring job command center, where hosts can be
grouped into subscriptions, and "checks" (or monitoring jobs) can be configured
to be executed by the agents running on these hosts. After checks are scheduled
on the agent a lot of interesting and powerful pipeline processing takes place,
but for the scope of this article we are only interested in what leads up to
check requests being delivered to an agent.

## The round robin scheduling feature

Round robin scheduling as it turns out is a rather popular sensu-go feature. By
default when a check is scheduled on a subscription, it is executed on all
connected agents with that subscription tag. With round robin scheduling, sensu
attempts to schedule that check to run on only one agent in that group. This is
frequently used for synthetics monitoring. For example, checking that an
external service e.g. `amazonaws.com` is available from the hosts in a
particular availability zone. In this case checking from all agents that the
service is available is unnecessary and counterproductive. Instead, it
would be better to schedule the check round robin so as to not depend on a
particular agent's availability to execute this check and to not overwhelm
operators with hundreds of agents reporting the same outage.

### The unreliable implementation

At the core of round robin scheduling in sensu-go is a ring buffer, implemented
by the `ring` package. In the case of round robin scheduling, each subscription
in a sensu namespace gets its own ring. `keepalived`, the backend component
responsible for handling the periodic keepalive events pushed by agents to their
connected backends, manages the contents of these ring buffers. When
`keepalived` receives a keepalive event from an agent it will add that agent to
the ring buffer for each of the agent's subscriptions. When an agent does not
report back in time for the next expected keepalive `keepalived` will remove the
agent from all ring buffers. The `schedulerd` backend component is responsible
for orchestrating the scheduling of checks. `schedulerd` registers Subscriptions
with the ring buffer, which pick a head of the ring and a schedule to advance
that head. When the head of the ring buffer is advanced, `schedulerd` is
notified of the next head and attempts to schedule the round robin check on that
agent if it is connected to that backend.

This algorithim is incredibly clever and has gotten the product this far. It
works well enough in healthy environments and, I suspect, when it does drop the
rare check execution it is unlikely to be noticed. This design has some
properties that make it quite nice, as well. The ring advances alphabetically,
equally covering the entire subscription pool. Also, because of etcd's strong
transactional consistency guarantees the ring operations are idempotent, sparing
the sensu backends from expensive coordination finding a leader to advance the
ring.

Fundamentally this approach is flawed. It can only ever promise at-most-once
execution of round robin checks. At any increment around the ring buffer it can
advance to an agent that has been separated from the cluster, or becomes
separated before the check request can be serviced. The ring buffer strategy
does not offer a solution for coordinating at-least-once execution, which is
desirable for sensu's use case.

An at-least-once execution would require a few changes.

1.) The ring buffer would need replaced by a more suitable strategy: a message
queue. Instead of coming to a distributed consensus of which agent the work is
to be scheduled on, the work should be described in a message and offered to the
group, locked by one consumer, and either acknowledge and deleted or unlocked
for another consumer to pick up.

2.) The use of sensu backends as brokers between agents and the message store
would either necessitate further changes to the agent/backend communication
protocol to facilitate an acknowledgement, or preferably a change in
architecture where the agents consume directly from the queue.

3.) Check executions should be scheduled only once. This means that sensu
backends either need a new mechanism to come to consensus on a leader to publish
the scheduling messages, or the messaging system needs to support deduplication.
Deduplication is the preferable option as the former would require either an
external locking service to function or complicated coordination between
backends using an asynchronous consensus algorithm.

### The stability issues it causes

The implementation of the `ring` package in sensu-go is backed by etcd. It
relies heavily on functions of etcd called leases and watchers which when
overused can both be a detriment to etcd cluster performance.

Leases function as an effective TTL for keys in etcd. When a leases lifetime
expires, either from being explicitly revoked by the application or because the
application doesn't issue a keep alive, the keys associated with that lease are
deleted. This is used as an effective dead man switch, so that agents separated
from the cluster can be removed from the ring buffer. Leases are also used as
the mechanism for scheduling the next ring advancement. When many leases are
expiring it can cause etcd nodes to fall behind on their heartbeat, and trigger
excessive leader elections.

Watchers allow clients to subscribe to a stream of changes made in the etcd
key-value store. In round robin scheduling each sensu backend creates a watcher
for each round robin check in order to watch for a trigger to the next ring
advancement. Watchers tend to mainly impact an etcd node's memory utilization.
Sensu's usage patterns can put a surprisingly high memory demands on an etcd
database. In under-provisioned environments the memory impact of many round
robin schedulers and their watchers can overwhelm a cluster, causing individual
nodes to crash and the cluster to fall behind.

## Tl;dr

For the time being, round robin scheduling has been disabled in sensu-go 7.0.
Our current implementation built on top of a ring buffer in etcd is unreliable,
delivering at-most-once execution, and contributes to cluster instability. A
message queue is necessary in order to deliver reliable round robin scheduling
moving forward.

I will be looking into several different messaging systems to identify their
suitability for sensu-go. The ideal system can support both pub/sub and
message queue modes, has a reliable message deduplication, and is open source
and widely available. I hope to look at [NSQ](https://nsq.io/),
[NATS](https://nats.io), [Apache Pulsar](https://pulsar.apache.org/) and more.
