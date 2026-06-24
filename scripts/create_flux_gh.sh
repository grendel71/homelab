 kubectl -n flux-system create secret generic flux-system \
  --from-literal=username=$GITHUB_USER \
  --from-literal=password=$GITHUB_TOKEN \
  --dry-run=client -o yaml | kubectl apply -f -
