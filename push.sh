#!/bin/bash
set -e

echo "Building images..."
docker compose -f compose/compose.dev.yaml build

echo "Tagging images..."
docker tag compose-catalog ghcr.io/iam-karan-suresh/retail-store-sample-catalog:1.3.0
docker tag compose-cart ghcr.io/iam-karan-suresh/retail-store-sample-cart:1.3.0
docker tag compose-orders ghcr.io/iam-karan-suresh/retail-store-sample-orders:1.3.0
docker tag compose-checkout ghcr.io/iam-karan-suresh/retail-store-sample-checkout:1.3.0
docker tag compose-ui ghcr.io/iam-karan-suresh/retail-store-sample-ui:1.3.0

echo "Pushing images..."
docker push ghcr.io/iam-karan-suresh/retail-store-sample-catalog:1.3.0
docker push ghcr.io/iam-karan-suresh/retail-store-sample-cart:1.3.0
docker push ghcr.io/iam-karan-suresh/retail-store-sample-orders:1.3.0
docker push ghcr.io/iam-karan-suresh/retail-store-sample-checkout:1.3.0
docker push ghcr.io/iam-karan-suresh/retail-store-sample-ui:1.3.0

echo "Done!"
