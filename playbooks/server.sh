#!/bin/bash

# docker-host = Docker engine/network role; task tag "docker" = container steps in service roles
sudo ansible-playbook main.yml --tags os,nftables,libvirt,docker-host,haproxy,repotekne,gerbera --ask-vault-pass -e@../group_vars_all/vault
