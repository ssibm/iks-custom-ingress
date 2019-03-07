#!/bin/bash

usage="Usage: sh $0 -z <zone> [-i <ingress-controller-name>]"

# get args
while getopts ":i:z:" opt; do
  case ${opt} in
    i)  i=${OPTARG} ;;
    z)  z=${OPTARG} ;;
    *)
        echo -e 'Error: Invalid arg(s)'\\n$usage
        exit 1
        ;;
  esac
done
shift $((OPTIND -1))
[[ -z $i ]] && { i="custom-ingress"; echo -e 'Setting ingress name to "custom-ingress"'; }
[[ -z $z ]] && { echo -e 'Error: Missing arg -z <zone>'\\n$usage; exit 1; }
echo -e "Setting zone name to \"$z\""

# create values file
cat <<EOF > /tmp/values-affinity-$z.yaml
nameOverride: &app_name $z-$i
fullnameOverride: *app_name
zone: &zone $z
controller:
  replicaCount: 2
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - key: failure-domain.beta.kubernetes.io/zone
            operator: In
            values:
            - *zone
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchExpressions:
          - key: app
            operator: In
            values:
            - *app_name
          - key: component
            operator: In
            values:
            - controller
        topologyKey: kubernetes.io/hostname
EOF
[ $? == 0 ] && { echo "Created values file: /tmp/values-affinity-$z.yaml"; exit 0; } \
  || { echo "Failed to create controller.affinity values file"; exit 1; }
