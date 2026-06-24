#!/usr/bin/env bash
# Source this script to set S3 credentials for the Ceph RGW endpoint:
#   source ./scripts/s3-env.sh

export AWS_ACCESS_KEY_ID=$(kubectl -n rook-ceph get secret rook-ceph-object-user-ceph-objectstore-ceph-objectstore-admin -o jsonpath='{.data.AccessKey}' | base64 -d)
export AWS_SECRET_ACCESS_KEY=$(kubectl -n rook-ceph get secret rook-ceph-object-user-ceph-objectstore-ceph-objectstore-admin -o jsonpath='{.data.SecretKey}' | base64 -d)
export AWS_DEFAULT_REGION=us-east-1
export S3_ENDPOINT=https://s3.envoy.grendel71.net

echo "S3 credentials set. Use:"
echo "  aws s3 <command> --endpoint-url \$S3_ENDPOINT"
