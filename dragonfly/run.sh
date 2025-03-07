#!/bin/bash

NODE_NAME=${2:-desktop-worker}
IMAGE_NAME=${3:-debian}
case $1 in
"init_cluster")
    # use kind to create a cluster with 3 nodes
    brew install kind
    kind create cluster --config kind-config.yaml # use docker-desktop to setup kind instead
    ;;
"poc")
    # setup the cluster-poc
    kubectl apply -f cluster-poc.yaml
    kubectl apply -f test-secret.yaml -n poc
    ;;
"scale")
    count=${2:-3}
    kubectl scale deployment/cluster-poc -n poc --replicas="$count" -n poc
    ;;
"metrics-server")
    kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
    kubectl patch deployment metrics-server -n kube-system --type='json' -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--kubelet-insecure-tls"}]'
    kubectl rollout restart deployment metrics-server -n kube-system
    ;;
"install")
    # install dragonfly
    echo "Note. install prometheus first if you want to use monitoring"
    helm repo add dragonfly https://dragonflyoss.github.io/helm-charts/
    helm upgrade --wait --create-namespace --namespace dragonfly-system dragonfly --install dragonfly/dragonfly -f values.yaml
    kubectl apply -f test-secret.yaml -n dragonfly-system
    ;;
"export_logs")
    mkdir -p logs
    kubectl get pods -n dragonfly-system -o custom-columns="NAMESPACE:.metadata.namespace,POD:.metadata.name" | tail -n +2 | while read ns pod; do
        echo "Fetching logs for $pod in namespace $ns"
        kubectl logs -n "$ns" "$pod" --all-containers >"logs/${ns}_${pod}.log" 2>&1
    done
    # tar -czf all-k8s-logs.tar.gz logs/
    # echo "Logs are saved in all-k8s-logs.tar.gz"
    ;;
"get_log")
    export POD_NAME=$(kubectl get pods --namespace dragonfly-system -l "app=dragonfly,release=dragonfly,component=client" -o=jsonpath='{.items[?(@.spec.nodeName=="'"$NODE_NAME"'")].metadata.name}' | head -n 1)
    export TASK_ID=$(kubectl -n dragonfly-system exec "$POD_NAME" -- sh -c "grep -hoP $IMAGE_NAME'.*task_id=\"\K[^\"]+' /var/log/dragonfly/dfdaemon/* | head -n 1")
    echo "POD Name: $POD_NAME"
    echo "Task ID: $TASK_ID"
    kubectl -n dragonfly-system exec -it "$POD_NAME" -- sh -c "grep $TASK_ID /var/log/dragonfly/dfdaemon/* | grep 'download task succeeded'"
    kubectl -n dragonfly-system exec "$POD_NAME" -- sh -c "grep $TASK_ID /var/log/dragonfly/dfdaemon/*" >dfdaemon.log
    ;;
"task_query")
    TASK_ID=$2
    kubectl logs -n dragonfly-system ds/dragonfly-client --all-containers=true --all-pods=true | grep "$TASK_ID" >task-"$TASK_ID".log
    ;;
"console")
    echo "Visit http://127.0.0.1:8080 to use your scheduler"
    kubectl --namespace dragonfly-system port-forward svc/dragonfly-manager 8080:8080
    ;;
"prometheus")
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
    helm upgrade --install --create-namespace --namespace prometheus prometheus prometheus-community/kube-prometheus-stack -f prometheus.yaml

    ;;
"grafana")
    echo "login with admin and password:"
    kubectl --namespace prometheus get secrets prometheus-grafana -o jsonpath="{.data.admin-password}" | base64 -d
    echo
    echo "and you can import dragonfly dashboard: 15945, 15944, 21053 and 21054 later."
    export POD_NAME=$(kubectl --namespace prometheus get pod -l "app.kubernetes.io/name=grafana,app.kubernetes.io/instance=prometheus" -oname)
    kubectl --namespace prometheus port-forward $POD_NAME 3000
    ;;
"pull")
    # pull the debian image from docker hub
    time docker exec -i "$NODE_NAME" /usr/local/bin/crictl pull "$IMAGE_NAME"
    ;;
*)
    echo "Usage: $0 [init_cluster|poc|scale|metrics-server|install|export_logs|get_log|task_query|console|prometheus|grafana|pull]"
    ;;
esac
