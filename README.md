## Bring your own Ingress Controller to IKS Clusters

IBM Kubernetes Service (IKS) cluster created in a Multizone Region (MZR) provides an application load balancer (ALB) in each zone and a multi-zone load balancer (MZLB) for the region. Each ALB uses an IKS provided ingress controller instance in that specific zone to handle incoming ingress requests. Additional information on Ingress in IKS is available [here](https://cloud.ibm.com/docs/containers?topic=containers-ingress#components).

This document shows how to deploy a custom ingress controller to an IKS multi-zone cluster and replacing the default ingress controller provided by IKS.

#### Pre-requisites
##### Custom ingress controller helm chart  
- Using instructions in this document, _stable/nginx-ingress_ helm chart will be used to deploy the community ingress controller in a multi-zone IKS cluster. Instructions in this document, use this ingress controller as an example.  

  If planning to use this chart to deploy a custom ingress controller for production-grade workloads, refer to [nginx ingress controller documentation](https://github.com/helm/charts/tree/master/stable/nginx-ingress) to customize and configure the deployment to meet your requirements.

##### IKS cluster in Multizone Region
- A working IKS cluster created in a multi-zone region.    

##### Setup CLI
- Install [kubectl](https://kubernetes.io/docs/tasks/tools/install-kubectl/#install-kubectl) and [ibmcloud](https://cloud.ibm.com/docs/cli/reference/ibmcloud?topic=cloud-cli-install-ibmcloud-cli#shell_install) CLIs.  

- Install container-service plugin  
`$ ibmcloud plugin install container-service -r 'IBM Cloud'`  

- Log into IBM Cloud  
`$ ibmcloud login`  

- Initialize IKS plugin  
`$ ibmcloud ks init`  

- Set cluster config  
`$ eval $(ibmcloud ks cluster-config <cluster-name> |tail -2|head -1)`  

- Verify kubectl is set to manage your cluster  
`$ kubectl config current-context`  

#### Implement custom ingress controller  
To deploy a custom ingress controller in a multi-zone IKS cluster, one instance of custom ingress controller should be installed in each zone. For each instance of the custom ingress controller, kubernetes scheduler should schedule pods to only be deployed on different worker nodes in the same zone. And then, ALB service in each zone should be updated to connect to the custom ingress controller's pods in that respective zone.    
![](https://raw.githubusercontent.com/ssibm/iks-custom-ingress/master/docs/img/hld.png "Custom ingress controller in IKS cluster")

##### Get ALBid and Zone names
Following table shows an example cluster with 3 zones. Get ALBid and Zone name information for each ALB in your multi-zone IKS cluster. This information will be used in the next set of commands. They should be repeated for each combination of ALBid and Zone for all the zones.

- Get public ALB id and zone name, note down in a table like below.    
```bash
$ ibmcloud ks albs --cluster <cluster-name> | grep public
```  

ALBid and Zone information (example values)  

| Cluster             | Zone  | ALBid                                          |
| ------------------- | ----- | ---------------------------------------------- |
| example-cluster-dal | dal10 | public-crec315b18e2d7858e9d36fe1ad10cc803-alb1 |
| example-cluster-dal | dal12 | public-crec315b18e2d7858e9d36fe1ad10cc803-alb2 |
| example-cluster-dal | dal13 | public-crec315b18e2d7858e9d36fe1ad10cc803-alb3 |

<br>
>__NOTE: Repeat following sections for each zone (dal10, dal12, dal13 etc.) to complete deployment of custom ingress controller in your _Multizone_ IKS cluster.__

##### Disable Public ALB in IKS cluster
1. Disable IKS provided default ingress controller. Repeat this for ALB in each zone.  
```bash
$ ibmcloud ks alb-configure --albID <ALBid> --disable-deployment
```  

2. Check to confirm _Enabled_ state for each ALB is _false_  
```bash
$ ibmcloud ks albs --cluster <cluster-name>
```  

##### Add affinity rules to Helm values  
1. Generate helm values file containing node and pod affinity rules.  
Replace _<zone\>_ with zone name and run following command. Sets default ingress controller name to ___custom-ingress___, to override append _-i <ingress-name\>_ to end of the command.  Repeat this command for each zone.  
```bash
$ curl -sSL https://raw.githubusercontent.com/ssibm/iks-custom-ingress/master/scripts/create-values-affinity.sh | sh -s -- -z <zone>
```    
Values file with node affinity and pod anti-affinity rules will be created at _/tmp/values-affinity-<zone\>.yaml_. This ensures that kubernetes scheduler for the zone-specific custom ingress controller will create the pods on different nodes in the same zone.  

  ```yaml
  /tmp/values-affinity-dal10.yaml

  nameOverride: &app_name dal10-custom-ingress
  fullnameOverride: *app_name
  zone: &zone dal10
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
          topologyKey: kubernetes.io/hostname
  ```

##### Deploy custom ingress controller resources
This document deploys a custom ingress controller using _stable/nginx-ingress_ helm chart. If deploying a different ingress controller, add ___affinity:___ rules to deployment template in your chart or to the deployment resource yaml, and then install.  

1. Dry-run and confirm values are correctly set. Replace _<zone\>_ with target zone and run the following command. Repeat this for each zone.  
```bash
$ helm init  
$ helm install --name <zone>-custom-ingress --namespace kube-system stable/nginx-ingress -f /tmp/values-affinity-<zone>.yaml --dry-run --debug | less  
```

2. Deploy custom ingress controller in _kube-system_ namespace. Replace _\<zone>_ with target zone. Repeat this for each zone.  
```bash
$ helm install --name <zone>-custom-ingress --namespace kube-system stable/nginx-ingress -f /tmp/values-affinity-<zone>.yaml
```

##### Update ALB service  
- Edit ALB service, set _selector:_ labels to _app: <zone\>-<ingress-controller-name\>_. For custom ingress controller used in this example also set _component: controller_ to select controller pods. Depending on labels used in your custom ingress controller, use the required selector labels.  
Repeat this for each ALB.  
```bash
$ kubectl edit svc <ALBid> -n kube-system
```
  ```yaml
  spec:
    ...
    selector:
      app: <zone>-custom-ingress
      component: controller
    ...
  ```  
  Enter __:wq__ to exit and apply changes.  

##### Verify ALB is using custom ingress controller  
Repeat this for each ALB.  
1. Confirm IBM provided ingress controller is disabled.    
```bash
$ ibmcloud ks albs --cluster <cluster-name> | grep <ALBid>
```

2. Show the ALB service endpoints.  Note the service endpoint IP Addresses.
```bash
$ kubectl describe svc <ALBid> -n kube-system | grep Endpoints
```

3. List the custom ingress controller pods running in same zone.  Their IP Addresses should match the service endpoint addresses.  Also confirm pods are dispersed onto different nodes.
```bash
$ kubectl get pods -n kube-system -l app=<zone>-custom-ingress,component=controller -o wide
```

4. Confirm all the nodes running ALB specific pods are in same zone.  
```bash
$ kubectl get nodes -l failure-domain.beta.kubernetes.io/zone=<zone>
```  

This completes the deployment of custom ingress controller in all the zones used by your multi-zone cluster.  

#### Validate using sample app
##### Deploy sample app
A sample web application consisting of an Ingress resource will be used to validate the custom ingress controller is functional.  

- Install the sample app, this will create an ingress, a service, and a deployment.
```bash
$ kubectl apply -f https://raw.githubusercontent.com/ssibm/iks-custom-ingress/master/sample-app/ingress-app.yaml
```

##### Access sample app
Access the sample application using it's Ingress path to connect to the backend service.   

- Get Ingress Subdomain. Replace _<cluster-name\>_ with IKS cluster name.  
```bash
$ ibmcloud ks cluster-get <cluster-name> | grep "Ingress Subdomain" | awk '{print $NF}'
```

- Replace _<ingress-subdomain\>_ with value from above command and send the request with ingress path _/app1_.  
```bash
$ curl -ik https://<ingress-subdomain>/app1
```
If the request is successfully handled by the custom ingress controller and backend service is available, then response _hello from app1_ with response code 200 will be returned.  
```
HTTP/2 200
...
hello from app1
```

##### Delete sample app
- Run following command to delete the sample ingress app.  
```bash
$ kubectl delete -f https://raw.githubusercontent.com/ssibm/iks-custom-ingress/master/sample-app/ingress-app.yaml
```

#### Re-enable IKS Ingress Controller  
- Re-set ALB to use IKS provided default ingress controller. This will not delete the custom ingress controller, it only updates ALB service to handle all incoming ingress resource rules using the default ingress controller. Repeat this for _<ALBid\>_ in each zone.
```bash
$ ibmcloud ks alb-configure --albID <ALBid> --enable
```  

#### Delete custom ingress controller
- Replace _<zone\>_ with zone name to delete the custom ingress controller resources from _kube-system_ namespace. Repeat this for each zone in your MZR cluster.
```bash
$ helm delete --purge <zone>-custom-ingress -n kube-system
```

This completes a successful deployment and cleanup of a custom ingress controller in a IKS multi-zone cluster. For additional information on IBM Cloud and IBM Kubernetes Service go to
[IBM Cloud documentation](cloud.ibm.com/docs).
