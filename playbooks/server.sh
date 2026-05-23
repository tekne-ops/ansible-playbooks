#!/bin/bash

# sudo ansible-playbook main.yml --tags os, nftables, docker, libvirt, haproxy, repotekne, gerbera --ask-vault-pass -e@../group_vars_all/vault
sudo ansible-playbook main.yml --tags haproxy --ask-vault-pass -e@../group_vars_all/vault
