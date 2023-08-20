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

One last key feature that must be reimagined is the round robin scheduling
feature. In order to implement this feature reliably, I believe we need a
message queuing system. Over the next few posts I hope to investigate potential
queueing systems for their suitability. First, though, some background on the
current solution and its shortcomings.

## A primer on sensu-go

Sensu-go is a distributed system consisting of a number of (mostly) stateless
backend nodes, an etcd database cluster, and upwards of 20k connected agent
processes. In normal operation, agents open up a bi-directional connection to
one of the backend nodes, the backend registers its presence in the etcd
database, and scheduled events are sent best effort from the backends to their
connected agents based on configured "subscription" tags. This is the heart of
sensu-go, a centralized monitoring job command center, where hosts can be
grouped into subscriptions, and "checks" (or monitoring jobs) can be configured
to be executed by the agents running on these hosts. After checks are scheduled
on the agent a lot of interesting and powerful pipeline processing takes place,
but for the scope of this article we are only interested in what leads up to
check requests being delivered to an agent.

## The round robin scheduling feature

Round robin scheduling as it turns out is a rather popular sensu-go feature. It
is frequently used for synthetics monitoring. Example: checking that
`foo.acme.com` is available from hosts in a particular availability zone. In
this use case it is likely desirable to check availability from _one_ host in
the AZ to save resources and spare operators from ensuing alert storm when each
host observes and reports the same outage.

### The unreliable implementation

At the core of round robin scheduling in sensu-go is a ring buffer, implemented
by the `ring` package. In the case of round robin scheduling, each subscription
in a sensu namespace gets its own ring. When `keepalived`, the backend component
responsible for handling the periodic keepalive events pushed by agents to their
connected backends, receives a keepalive from an agent it will add that agent
name to the ring buffers belonging to each of the agent's subscriptions.
`keepalived` will also remove agents from ring buffers if it knows that the
agent has disconnected. The `schedulerd` component responsible for orchestrating
the scheduling of checks will register a subscription with the ring buffer,
describing the ring to watch as well as the schedule to advance the head of the
ring. When the ring is advanced, `schedulerd` is notified of which agent is at
the head of the ring, and will attempt to schedule the round robin check on that
agent if it is connected to that backend.

Fundamentally this approach is flawed, as it can only ever promise at-most-once
execution of round robin checks. At any increment around the ring buffer it can
advance to an agent that has been separated from the cluster, or becomes
separated before the check request can be serviced. The ring buffer strategy
does not offer a solution for coordinating at-least-once execution, which is
desirable for sensu's use case.

An at-least-once execution would require a few changes.

1.) The ring buffer would need replaced by a more suitable strategy: a message
queue. Instead of coming to a distributed consensus of which agent the work is
to be scheduled on, the work should be described in a message and offered to the
group, locked by one consumer, and either acknowledge and deleted or unlocked.
This is of course what message queues do.

2.) The use of sensu backends as brokers between agents and the message store
would either necessitate further changes to the agent/backend communication
protocol to facilitate an acknowledgement, or preferably a change in
architecture where the agents consume directly from the queue.

3.) Check executions should be scheduled only once. This necessitates either a
message queueing system that supports deduplication or for sensu backends to
come to consensus on a leader. Deduplication is the preferable option as the
later requires either a reliable external locking service or coordination
between backends using an asynchronous consensus algorithm.

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
advancement. Watchers tend to impact an etcd node's memory utilization. As with
leases, this excess memory utilization can cause excessive leader elections in
under-provisioned environments. Depending on the particulars of the deployment
this can result in all sorts of issues, from etcd nodes crashing with OOM errors
to causing excessive leader elections as nodes struggle to keep up.

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
