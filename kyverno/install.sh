#!/usr/bin/env bash
set -eu
workspace=$(cd "$(dirname "$0")" && pwd -P)
APP_NS="app-mutate"
{
    cd "$workspace/"
    # delete resources (only once)
    if [ "$1" = "cleanup" ]; then
        helm uninstall "$APP_NS" -n "$APP_NS" || true
        kubectl delete ns "$APP_NS" || true
        kubectl delete -f kyverno-add-image-pullsecret-and-prefix.yaml || true
        helm uninstall kyverno -n kyverno || true
        kubectl delete ns kyverno || true
        exit 0
    fi

    # install kyverno (only once)
    if ! helm status kyverno -n kyverno >/dev/null 2>&1; then
        helm repo add kyverno https://kyverno.github.io/kyverno/
        helm repo update
        helm install kyverno kyverno/kyverno -n kyverno --create-namespace
    fi

    # apply policies
    kubectl apply -f kyverno-add-image-pullsecret-and-prefix.yaml -n kyverno

    # wait for sync-secrets policies to be created
    kubectl wait --for=jsonpath='{.metadata.name}'=sync-secrets --timeout=10s -n kyverno clusterpolicy/sync-secrets

    # check if secret sync during ns creation
    if [ ! -d "$workspace/$APP_NS" ]; then
        helm create "$APP_NS" # create a sample app with nginx image
    fi

    # make sure ns is recreated
    kubectl delete ns "$APP_NS" || true
    kubectl create ns "$APP_NS"
    # wait for secret to be created
    kubectl wait --for=jsonpath='{.metadata.name}'=my-secret --timeout=10s -n "$APP_NS" secret/my-secret

    # update image registry and add pull secret
    helm install "$APP_NS" ./"$APP_NS" -n "$APP_NS" --create-namespace

    # wait for pod to be created
    SECONDS=0
    timeout=10
    end=$((SECONDS + timeout))
    while [ $SECONDS -lt $end ]; do
        STATUS=$(kubectl get pod -l app.kubernetes.io/name="$APP_NS" -n "$APP_NS" -o jsonpath='{.items[*].status.phase}')
        if [ "$STATUS" = "Pending" ]; then
            echo "Pod is in Pending state."
            break
        fi
        echo "Waiting for pod to be created..."
        sleep 2
    done

    # check if image is updated with pull secret
    echo "Pod image:"
    kubectl get pod -n "$APP_NS" -o jsonpath='{.items[*].spec.containers[*].image}'
    printf "\nImage pull secrets:"
    kubectl get pod -n "$APP_NS" -o jsonpath='{.items[*].spec.imagePullSecrets}'
}
