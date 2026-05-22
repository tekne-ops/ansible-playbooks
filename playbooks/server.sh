#!/bin/bash

sudo ansible-playbook main.yml --tags os, nftables, docker, libvirt, haproxy, repotekne, gerbera --ask-vault-pass -e@vault