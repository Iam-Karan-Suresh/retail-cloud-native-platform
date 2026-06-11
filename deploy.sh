#!/bin/bash
set -e

echo "Applying Observability Stack..."
kubectl apply -k k8s/observability

echo "Creating namespace..."
kubectl create namespace retail-store --dry-run=client -o yaml | kubectl apply -f -

echo "Deploying Helm charts..."
helm upgrade --install catalog ./src/catalog/chart -n retail-store
helm upgrade --install cart ./src/cart/chart -n retail-store
helm upgrade --install orders ./src/orders/chart -n retail-store
helm upgrade --install checkout ./src/checkout/chart -n retail-store
helm upgrade --install ui ./src/ui/chart -n retail-store

echo "Deployments initiated."
