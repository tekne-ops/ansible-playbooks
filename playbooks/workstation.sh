#!/bin/bash

sudo ansible-playbook main.yml --tags os,pipewire,gaming,onedrive,bootstrap,nftables --ask-vault-pass
