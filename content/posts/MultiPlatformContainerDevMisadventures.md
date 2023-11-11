---
title: "Misadventures In Multi-Platform Container Development"
date: 2023-11-08T14:48:17-08:00
tags:
    - DevEx
    - Linux
    - Qemu
---

The other week while working away from home and using my phone with a poor
connection as a mobile hotspot for my intel based macbook, I ran into a need
for an aarch64 based system. I thought I would share what I came up with, not
because I think it is especially useful, but because it was a lot of fun
working through this without a stable internet connection. It has been a long
time since I have been forced to work this way. The experience reminded me of
hacking on computers in my parents basement, being as time efficient as
possible with my time on the dial-up connection tying up our line.

In the end I was able to get a Fedora CoreOS aarch64 image downloaded with the
little bandwith I had, and was able to get it running on my x86_64 macbook as a
[podman machine][podman-machine] using `qemu-system-aarch64`. I have since
tried to reproduce this setup without much success, but I don't really need to.
Someone has already sorted out a more convenient way to solve this type of
problem, and I've since read about that on the internet. Plus it really is
faster for me to provision an arm64 cloud instance.

## The Problem

I had been asked to see about a CGO linux/arm64 build of a go project using
boringcrypto and wanted a way to vet the result, by running the build on
various distributions. Having only an x86_64 PC I knew that I needed emulation.

## The Qemu-Direct Approach

The original plan was to run an emulated aarch64 system through [UTM][utm] with
the eventual goal to be able to run containers on that system. I chose Fedora
CoreOS because I knew it was on the small side and came with a container
runtime pre-installed. Once the download finished I ended up having a hard time
getting it running on UTM. It refused to add the `-fw_cfg` option to pass in
the ignition file, so I borrowed some of the defaults and moved towards using
`qemu-system-aarch64` directly. Eventually I got that working with bare serial
IO and minimal networking configuration, but was not pleased with the
experience. The host and guest couldn't reasonably communicate with eachother
over the network in this setup, I was stuck with a single terminal session that
had to be left active. Instead of delving back into qemu documentation and help
menus to sort that all out, I switched to a different approach: to swap out my
podman-machine's VM (qemu + MacOS's hypervisor) with the emulated aarch64
system.

## An Emulated Podman Machine

I already had a mostly working `qemu-system-aarch64` command, and hand some
familiarity with how podman-machine manages its linux VMs for MacOS. With
these, I was able to create a new podman machine, manually edit its
configuration to run an emulated aarch64 system, and start it through `podman
machine start` in relatively short order. I was able to run aarch64 containers
from my host system as if they were native, even including volume mounts and
podman netowrking. This was great, it solved my problem for the day. I had
discovered the clear and obvious way to run multi platform containers in
podman, or so I thought.

## Back Online

A few days later, having used my new aarch64 podman machine a handful of times
I though I'd check if there were already a feature request to support this.
Turns out there was a far more direct way to accomplish this using userspace
emulation instead of system. I stared back up the default podman machine, ran
`podman machine ssh` `sudo rmp-ostree install qemu-user-static && sudo
systemctl reboot;`, and just like that I was able to run arm64 containers.

## Reproducing the Fully Emulated System

As it turns out, I think I got lucky to have my podman machine start up with
little fuss. There is a lot of clever handoffs between podman and the CoreOS VM
with little to no visibility into its state. I felt I'd have to patch podman or
attach a debugger to really figure out what was going on. Given how convenient
the binfmt_misc + qemu userspace emulation is, I didn't see much value in
pursue it.

[podman-machine]: https://docs.podman.io/en/stable/markdown/podman-machine.1.html
[utm]: https://getutm.app/
