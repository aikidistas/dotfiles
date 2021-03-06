#!/bin/bash
mkdir -p ~/.kube
export KUBECONFIG=$(find ~/.kube -maxdepth 1 -type f,l | grep -v '.kube/config' | grep -v '.kube/kubectx' | tr '\n' ':')
echo "# This file was generated by ~/dotfiles/bin/dotkube-compile.sh, do not edit manually" > ~/.kube/config
kubectl config view --flatten >> ~/.kube/config
chmod o-rw ~/.kube/config
chmod g-rw ~/.kube/config
