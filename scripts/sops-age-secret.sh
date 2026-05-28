#!/usr/bin/env sh

cat age.agekey |
kubectl create secret generic sops-age \
  --namespace=flux-system \
  --from-file=age.agekey=/dev/stdin
