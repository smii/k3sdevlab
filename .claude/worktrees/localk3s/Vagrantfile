# -*- mode: ruby -*-
# vi: set ft=ruby :
#
# k3sdevlab Vagrant Environment
# ===============================
# Boots a self-contained K3s + ArgoCD homelab for local development and testing.
#
# DNS:  nip.io wildcard — all services are reachable at *.<VM_IP>.nip.io
#       from your host browser with NO /etc/hosts changes required.
#
# TLS:  Self-signed CA (cert-manager). Run `bash vagrant/trust-ca.sh` once
#       on your host to install the CA and eliminate browser warnings.
#
# Git:  A local git-daemon serves the patched repo inside the VM so ArgoCD
#       works fully offline without GitHub access.
#
# Usage:
#   vagrant up                          # lite profile (8 GB RAM, recommended)
#   VAGRANT_PROFILE=full vagrant up     # full profile (12 GB RAM — adds Harbor/Loki/CrowdSec)
#   VAGRANT_VM_IP=10.10.10.10 vagrant up  # custom IP (if 192.168.56.100 conflicts)
#
# Requirements:
#   VirtualBox (default) OR libvirt/KVM (vagrant plugin install vagrant-libvirt)

PROFILE = ENV.fetch("VAGRANT_PROFILE", "lite")
VM_IP   = ENV.fetch("VAGRANT_VM_IP", "192.168.56.100")
MEMORY  = PROFILE == "full" ? 12288 : 8192
CPUS    = 4

Vagrant.configure("2") do |config|
  # Default box — works with VirtualBox and (via override) libvirt
  config.vm.box      = "ubuntu/jammy64"
  config.vm.hostname = "k3sdevlab"

  # Fixed private-network IP.  nip.io resolves *.192.168.56.100.nip.io → this IP
  # on the public internet so the host browser just works.
  config.vm.network "private_network", ip: VM_IP

  # Sync the project into the VM.  Excludes secrets, large artifacts, and the
  # existing Vagrant state so the VM always gets a clean copy of the repo.
  config.vm.synced_folder ".", "/homelab",
    type: "rsync",
    rsync__exclude: [
      ".git/", ".vagrant/", "*.log",
      ".env",           # never sync the production .env
      "test/",
      "sec_key/"        # TransIP credentials — keep off the VM
    ]

  # Main provisioner — idempotent, safe to re-run with `vagrant provision`
  config.vm.provision "shell",
    path: "vagrant/provision.sh",
    env: {
      "VM_IP"           => VM_IP,
      "VAGRANT_PROFILE" => PROFILE
    }

  # ── VirtualBox (default, no plugin needed) ──────────────────────────────────
  config.vm.provider "virtualbox" do |vb|
    vb.name   = "k3sdevlab-#{PROFILE}"
    vb.memory = MEMORY
    vb.cpus   = CPUS
    # Improve DNS performance inside the VM
    vb.customize ["modifyvm", :id, "--natdnshostresolver1", "on"]
    vb.customize ["modifyvm", :id, "--natdnsproxy1",        "on"]
    # Use virtio for better throughput
    vb.customize ["modifyvm", :id, "--nictype1", "virtio"]
    vb.customize ["modifyvm", :id, "--nictype2", "virtio"]
  end

  # ── libvirt / KVM (vagrant plugin install vagrant-libvirt) ──────────────────
  config.vm.provider :libvirt do |lv, override|
    override.vm.box = "generic/ubuntu2204"
    lv.driver         = "kvm"
    lv.memory         = MEMORY
    lv.cpus           = CPUS
    lv.disk_bus       = "virtio"
    lv.nic_model_type = "virtio"
  end
end
