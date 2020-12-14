#!/bin/bash

# Fail if no simulation class if specified
if [ -z "${SIMULATION_CLASS}" ]; then echo "SIMULATION_CLASS must be non-blank" && exit -1; fi

set -e
set -x

JOB_DESCRIPTION="${SIMULATION_CLASS}"

# Create appropriate directories under workspace

mkdir -p ./workspace/data
mkdir -p ./workspace/simulations
mkdir -p ./workspace/configs

GATLING_NODES=$((NUM_GATLING_NODES + 0))

ESTIMATED_NODES_1=$((GATLING_NODES))
ESTIMATED_NODES_2=$((GATLING_NODES + 1))

#We will be using the implicit cluster as true for Site-Search use case
if [ "$GCP" = "GCP" ] ; then
  cp ./jenkins/k8s/cluster-gcp-external.yaml ./jenkins/k8s/cluster.yaml
fi

CID=$(docker container ls -aq -f "name=kubectl-support")

# initialise the k8s cluster with zookeepers, solr clusters, gatling-solr image
sed -i "s/namespace_filler/${GCP_K8_CLUSTER_NAMESPACE}/" ./jenkins/k8s/cluster.yaml
sed -i "s/gatling-nodes-replicas/${GATLING_NODES}/" ./jenkins/k8s/cluster.yaml
docker cp ./jenkins/k8s/cluster.yaml ${CID}:/opt/cluster.yaml
# optional property files a user may have uploaded to jenkins
# Note: Jenkins uses the same string for the file name, and the ENV var,
# so we're requiring CLUSTER_YAML_FILE (instead of cluster.yaml) so bash can read the ENV var
if [ ! -z "${CLUSTER_YAML_FILE}" ]; then
  if [ ! -f ./CLUSTER_YAML_FILE ]; then
    echo "Found ENV{CLUSTER_YAML_FILE}=${CLUSTER_YAML_FILE} -- but ./CLUSTER_YAML_FILE not found, jenkins bug?" && exit -1
  fi
  echo "Copying user supplied index config to workspace/configs/index.config.properties"
  cp ./CLUSTER_YAML_FILE ./workspace/configs/${CLUSTER_YAML_FILE}

  # copy the configs from local to dockers
  docker cp ./workspace/configs/${CLUSTER_YAML_FILE} ${CID}:/opt/cluster.yaml
else
  rm -rf ./CLUSTER_YAML_FILE
fi

# delete gatling-solr service and statefulsets, redundant step
docker exec kubectl-support kubectl delete statefulsets gatlingsolr --namespace=${GCP_K8_CLUSTER_NAMESPACE} || echo "gatling statefulsets not available!!"
docker exec kubectl-support kubectl delete service gatlingsolr --namespace=${GCP_K8_CLUSTER_NAMESPACE} || echo "gatling service not available!!"
sleep 30

#Create Oauth2 secrets
docker exec kubectl-support kubectl get secret oauth2 --namespace=default --export -o yaml >>secrets.yaml
docker cp secrets.yaml ${CID}:/opt/secrets.yaml
docker exec kubectl-support kubectl apply --namespace=${GCP_K8_CLUSTER_NAMESPACE} -f /opt/secrets.yaml
docker exec kubectl-support rm -rf /opt/secrets.yaml
rm -rf secrets.yaml

docker exec kubectl-support kubectl create -f /opt/cluster.yaml || echo "gatling service already created!!"
# buffer sleep for 3 mins to get the pods ready, and then check
sleep 15

# wait until all pods comes up running
TOTAL_PODS=$(docker exec kubectl-support kubectl get pods --all-namespaces | grep "gatling" | grep "${GCP_K8_CLUSTER_NAMESPACE}" | grep "Running" | grep "1/1" | wc -l)
# find better way to determine all pods running
while [ "${TOTAL_PODS}" != "${ESTIMATED_NODES_1}" -a "${TOTAL_PODS}" != "${ESTIMATED_NODES_2}" ]; do
  sleep 15
  TOTAL_PODS=$(docker exec kubectl-support kubectl get pods --all-namespaces | grep "gatling" | grep "${GCP_K8_CLUSTER_NAMESPACE}" | grep "Running" | grep "1/1" | wc -l)
done

# we're requiring QUERY_PROP_FILE (instead of query.config.properties) so bash can read the ENV var
if [ ! -z "${QUERY_PROP_FILE}" ]; then
  if [ ! -f ./QUERY_PROP_FILE ]; then
    echo "Found ENV{QUERY_PROP_FILE}=${QUERY_PROP_FILE} -- but ./QUERY_PROP_FILE not found, jenkins bug?" && exit -1
  fi
  echo "Copying user supplied query config to workspace/configs/query.config.properties"
  cp ./QUERY_PROP_FILE ./workspace/configs/query.config.properties

  # copy the configs from local to dockers
  docker cp ./workspace/configs/query.config.properties ${CID}:/opt/query.config.properties
  for ((c = 0; c < ${GATLING_NODES}; c++)); do
    docker exec kubectl-support kubectl cp /opt/query.config.properties ${GCP_K8_CLUSTER_NAMESPACE}/gatlingsolr-${c}:/opt/gatling/user-files/configs/query.config.properties
  done
else
  rm -rf ./QUERY_PROP_FILE
fi

# we're requiring QUERY_FEEDER_FILE (instead of actual file name) so bash can read the ENV var
if [ ! -z "${QUERY_FEEDER_FILE}" ]; then
  if [ ! -f ./QUERY_FEEDER_FILE ]; then
    echo "Found ENV{QUERY_FEEDER_FILE}=${QUERY_FEEDER_FILE} -- but ./QUERY_FEEDER_FILE not found, jenkins bug?" && exit -1
  fi
  echo "Copying user supplied patch to workspace/data/${QUERY_FEEDER_FILE}"
  cp ./QUERY_FEEDER_FILE ./workspace/data/${QUERY_FEEDER_FILE}

  # copy the data from local to dockers
  docker cp ./workspace/configs/${QUERY_FEEDER_FILE} ${CID}:/opt/${QUERY_FEEDER_FILE}
  for ((c = 0; c < ${GATLING_NODES}; c++)); do
    docker exec kubectl-support kubectl cp /opt/${QUERY_FEEDER_FILE} ${GCP_K8_CLUSTER_NAMESPACE}/gatlingsolr-${c}:/opt/gatling/user-files/data/${QUERY_FEEDER_FILE}
  done
else
  rm -rf ./QUERY_FEEDER_FILE
fi

# set gatling nodes heap settings
sed -i "s/replace-heap-settings/${GATLING_HEAP}/" ./jenkins/k8s/gatling.sh
docker cp ./jenkins/k8s/gatling.sh ${CID}:/opt/gatling.sh
# create results directory on the docker
for ((c = 0; c < ${GATLING_NODES}; c++)); do
  docker exec kubectl-support kubectl cp /opt/gatling.sh ${GCP_K8_CLUSTER_NAMESPACE}/gatlingsolr-${c}:/opt/gatling/bin/gatling.sh
done

# execute the load test on docker
echo "One-Platform Perf Test Status: Job Description - running....."

# read each class and execute the tests
while read -r CLASS; do

  #create directory on the docker to store the results
  for ((c = 0; c < ${GATLING_NODES}; c++)); do
    docker exec kubectl-support kubectl exec -n ${GCP_K8_CLUSTER_NAMESPACE} gatlingsolr-${c} -- mkdir -p /tmp/gatling-perf-tests-${c}-${CLASS}/results
  done

  # run gatling test for a simulation and pass relevant params
  for ((c = 0; c < ${GATLING_NODES}; c++)); do
    if [ "$PRINT_GATLING_LOG" = true ]; then
      docker exec kubectl-support kubectl exec -n ${GCP_K8_CLUSTER_NAMESPACE} gatlingsolr-${c} -- gatling.sh -s ${CLASS} -rd "--simulation--" -rf /tmp/gatling-perf-tests-${c}-${CLASS}/results -nr || echo "Current Simulation Ended!!"
    else
      docker exec -d kubectl-support kubectl exec -n ${GCP_K8_CLUSTER_NAMESPACE} gatlingsolr-${c} -- gatling.sh -s ${CLASS} -rd "--simulation--" -rf /tmp/gatling-perf-tests-${c}-${CLASS}/results -nr || echo "Current Simulation Ended!!"
    fi
  done

  for ((c = 0; c < ${GATLING_NODES}; c++)); do
    IF_CMD_EXEC=$(docker exec kubectl-support kubectl exec -n ${GCP_K8_CLUSTER_NAMESPACE} gatlingsolr-${c} -- ps | grep "gatling" | wc -l)
    while [ "${IF_CMD_EXEC}" != "0" ]; do
      sleep 20
      IF_CMD_EXEC=$(docker exec kubectl-support kubectl exec -n ${GCP_K8_CLUSTER_NAMESPACE} gatlingsolr-${c} -- ps | grep "gatling" | wc -l)
    done
  done

  if [ ! -z "${INDEX_GATLING_NODES}" ] && [[ ${CLASS} != "Index"* ]]; then
    # generate the index reports
    for ((c = 0; c < ${INDEX_GATLING_NODES}; c++)); do
      docker exec kubectl-support mkdir -p /opt/index-results/reports-${c}-${CLASS}
      docker exec kubectl-support kubectl cp ${GCP_K8_CLUSTER_NAMESPACE}/gatlingsolr-${c}:/tmp/gatling-perf-tests-${c}-${CLASS}/results/ /opt/index-results/reports-${c}-${CLASS}/ || echo "!! Logs not present !!"
    done

    # generate the query reports
    for ((c = ${INDEX_GATLING_NODES}; c < ${GATLING_NODES}; c++)); do
      docker exec kubectl-support mkdir -p /opt/query-results/reports-${c}-${CLASS}
      docker exec kubectl-support kubectl cp ${GCP_K8_CLUSTER_NAMESPACE}/gatlingsolr-${c}:/tmp/gatling-perf-tests-${c}-${CLASS}/results/ /opt/query-results/reports-${c}-${CLASS}/ || echo "!! Logs not present !!"
    done

    echo "!! Index Reports !!"
    docker exec kubectl-support gatling.sh -ro /opt/index-results/
    echo "!! Query Reports !!"
    docker exec kubectl-support gatling.sh -ro /opt/query-results/

    # copy the perf tests to the workspace
    mkdir -p workspace/index-reports-${BUILD_NUMBER}/${CLASS}
    docker cp ${CID}:/opt/index-results ./workspace/index-reports-${BUILD_NUMBER}/${CLASS}
    mkdir -p workspace/query-reports-${BUILD_NUMBER}/${CLASS}
    docker cp ${CID}:/opt/query-results ./workspace/query-reports-${BUILD_NUMBER}/${CLASS}
    docker exec kubectl-support rm -rf /opt/index-results/ /opt/query-results/
  else

    # generate the index reports
    for ((c = 0; c < ${GATLING_NODES}; c++)); do
      docker exec kubectl-support mkdir -p /opt/results/reports-${c}-${CLASS}
      docker exec kubectl-support kubectl cp ${GCP_K8_CLUSTER_NAMESPACE}/gatlingsolr-${c}:/tmp/gatling-perf-tests-${c}-${CLASS}/results/ /opt/results/reports-${c}-${CLASS}/ || echo "!! Logs not present !!"
    done

    echo "!! Reports !!"
    docker exec kubectl-support gatling.sh -ro /opt/results/
    # copy the perf tests to the workspace
    mkdir -p workspace/reports-${BUILD_NUMBER}/${CLASS}
    docker cp ${CID}:/opt/results ./workspace/reports-${BUILD_NUMBER}/${CLASS}
    docker exec kubectl-support rm -rf /opt/results/
  fi

done <<<"${SIMULATION_CLASS}"

#delete gatling services
docker exec kubectl-support kubectl delete -f /opt/cluster.yaml || echo "Gatling service already deleted!!"
