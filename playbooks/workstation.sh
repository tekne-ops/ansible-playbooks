#!/bin/bash

sudo ansible-playbook main.yml --tags network-host,os,pipewire,gaming,onedrive,bootstrap,nftables --ask-vault-pass
