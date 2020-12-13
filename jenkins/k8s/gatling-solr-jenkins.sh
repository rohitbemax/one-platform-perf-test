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

# 5 more nodes for solr cluster
ESTIMATED_NODES_1=$((GATLING_NODES))
ESTIMATED_NODES_2=$((GATLING_NODES + 1))

if [ "$IMPLICIT_CLUSTER" = true ]; then
  # TODO: hardcoded need to provide the check better, possible parameter passing
  ESTIMATED_NODES_1=$((ESTIMATED_NODES_1 + 4))
  ESTIMATED_NODES_2=$((ESTIMATED_NODES_2 + 4))
  if [ "$GCP" = "GCP" ] ; then
    cp ./jenkins/k8s/cluster-gcp-internal.yaml ./jenkins/k8s/cluster.yaml
  fi
else
  if [ "$GCP" = "GCP" ] ; then
    cp ./jenkins/k8s/cluster-gcp-external.yaml ./jenkins/k8s/cluster.yaml
  fi
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

# create oauth2 secrets
docker exec kubectl-support kubectl get secret oauth2 --namespace=default --export -o yaml >>secrets.yaml
docker cp secrets.yaml ${CID}:/opt/secrets.yaml
docker exec kubectl-support kubectl apply --namespace=${GCP_K8_CLUSTER_NAMESPACE} -f /opt/secrets.yaml
docker exec kubectl-support rm -rf /opt/secrets.yaml
rm -rf secrets.yaml

docker exec kubectl-support kubectl create -f /opt/cluster.yaml || echo "gatling service already created!!"
# buffer sleep for 3 mins to get the pods ready, and then check
sleep 15

if [ "$IMPLICIT_CLUSTER" = true ]; then
  # wait until all pods comes up running
  TOTAL_PODS=$(docker exec kubectl-support kubectl get pods --all-namespaces | grep "gatling" | grep "${GCP_K8_CLUSTER_NAMESPACE}" | grep "Running" | grep "1/1" | wc -l)
  # find better way to determine all pods running
  while [ "${TOTAL_PODS}" != "${ESTIMATED_NODES_1}" -a "${TOTAL_PODS}" != "${ESTIMATED_NODES_2}" ]; do
    sleep 15
    TOTAL_PODS=$(docker exec kubectl-support kubectl get pods --all-namespaces | grep "gatling" | grep "${GCP_K8_CLUSTER_NAMESPACE}" | grep "Running" | grep "1/1" | wc -l)
  done
else
  # wait until all pods comes up running
  TOTAL_PODS=$(docker exec kubectl-support kubectl get pods --all-namespaces | grep "gatling" | grep "${GCP_K8_CLUSTER_NAMESPACE}" | grep "Running" | grep "1/1" | wc -l)
  # find better way to determine all pods running
  while [ "${TOTAL_PODS}" != "${ESTIMATED_NODES_1}" -a "${TOTAL_PODS}" != "${ESTIMATED_NODES_2}" ]; do
    sleep 15
    TOTAL_PODS=$(docker exec kubectl-support kubectl get pods --all-namespaces | grep "gatling" | grep "${GCP_K8_CLUSTER_NAMESPACE}" | grep "Running" | grep "1/1" | wc -l)
  done
fi

# TODO: remove executing commands within the solr cluster and utilise Collection Admin API
if [ "$IMPLICIT_CLUSTER" = true ]; then
  # (re)create collection 'wiki'
  if [ "$RECREATE_COL" = true ]; then
    docker exec kubectl-support rm -rf /opt/collection-config
    docker cp ./src/main/java/performance/tests/conf ${CID}:/opt/collection-config
    docker exec kubectl-support kubectl cp /opt/collection-config ${GCP_K8_CLUSTER_NAMESPACE}/solr-dummy-cluster-0:/opt/solr/collection-config
    docker exec kubectl-support kubectl exec -n ${GCP_K8_CLUSTER_NAMESPACE} solr-dummy-cluster-0 -- /opt/solr/bin/solr delete -c wiki || echo "create collection now"
    docker exec kubectl-support kubectl exec -n ${GCP_K8_CLUSTER_NAMESPACE} solr-dummy-cluster-0 -- /opt/solr/bin/solr create -c wiki -s $((NUM_SHARDS)) -rf $((NUM_REPLICAS)) -d /opt/solr/collection-config/ || echo "collection already created"
  fi
else
  # (re)create collection 'wiki'
  if [ "$RECREATE_COL" = true ]; then
    docker exec kubectl-support rm -rf /opt/collection-config
    docker cp ./src/main/java/performance/tests/conf ${CID}:/opt/collection-config
    docker exec kubectl-support kubectl cp /opt/collection-config ${GCP_K8_CLUSTER_NAMESPACE}/${EXT_SOLR_NODE_POD_NAME}:/opt/solr/collection-config
    docker exec kubectl-support kubectl exec -n ${GCP_K8_CLUSTER_NAMESPACE} ${EXT_SOLR_NODE_POD_NAME} -- /opt/solr/bin/solr delete -c wiki || echo "create collection now"
    docker exec kubectl-support kubectl exec -n ${GCP_K8_CLUSTER_NAMESPACE} ${EXT_SOLR_NODE_POD_NAME} -- /opt/solr/bin/solr create -c wiki -s $((NUM_SHARDS)) -rf $((NUM_REPLICAS)) -d /opt/solr/collection-config/ || echo "collection already created"
  fi
fi

# buffer time for prometheus to intake solr metrics
sleep 15

# optional property files a user may have uploaded to jenkins
# Note: Jenkins uses the same string for the file name, and the ENV var,
# so we're requiring INDEX_PROP_FILE (instead of index.config.properties) so bash can read the ENV var
if [ ! -z "${INDEX_PROP_FILE}" ]; then
  if [ ! -f ./INDEX_PROP_FILE ]; then
    echo "Found ENV{INDEX_PROP_FILE}=${INDEX_PROP_FILE} -- but ./INDEX_PROP_FILE not found, jenkins bug?" && exit -1
  fi
  echo "Copying user supplied index config to workspace/configs/index.config.properties"
  cp ./INDEX_PROP_FILE ./workspace/configs/index.config.properties

  # copy the configs from local to dockers
  docker cp ./workspace/configs/index.config.properties ${CID}:/opt/index.config.properties
  for ((c = 0; c < ${GATLING_NODES}; c++)); do
    docker exec kubectl-support kubectl cp /opt/index.config.properties ${GCP_K8_CLUSTER_NAMESPACE}/gatlingsolr-${c}:/opt/gatling/user-files/configs/index.config.properties
  done
else
  rm -rf ./INDEX_PROP_FILE
fi

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

# we're requiring INDEX_FEEDER_FILE (instead of actual file name) so bash can read the ENV var
if [ ! -z "${INDEX_FEEDER_FILE}" ]; then
  if [ ! -f ./INDEX_FEEDER_FILE ]; then
    echo "Found ENV{INDEX_FEEDER_FILE}=${INDEX_FEEDER_FILE} -- but ./INDEX_FEEDER_FILE not found, jenkins bug?" && exit -1
  fi
  echo "Copying user supplied patch to workspace/data/${INDEX_FEEDER_FILE}"
  cp ./INDEX_FEEDER_FILE ./workspace/data/${INDEX_FEEDER_FILE}

  # copy the data from local to dockers
  docker cp ./workspace/configs/${INDEX_FEEDER_FILE} ${CID}:/opt/${INDEX_FEEDER_FILE}
  for ((c = 0; c < ${GATLING_NODES}; c++)); do
    docker exec kubectl-support kubectl cp /opt/${INDEX_FEEDER_FILE} ${GCP_K8_CLUSTER_NAMESPACE}/gatlingsolr-${c}:/opt/gatling/user-files/data/${INDEX_FEEDER_FILE}
  done
else
  rm -rf ./INDEX_FEEDER_FILE
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

# we're requiring SIMULATION_FILE so bash can read the ENV var
if [ ! -z "${SIMULATION_FILE}" ]; then
  if [ ! -f ./SIMULATION_FILE ]; then
    echo "Found ENV{SIMULATION_FILE}=${SIMULATION_FILE} -- but ./SIMULATION_FILE not found, jenkins bug?" && exit -1
  fi
  echo "Copying user supplied patch to workspace/data/${SIMULATION_FILE}"
  cp ./SIMULATION_FILE ./workspace/simulations/${SIMULATION_FILE}

  # copy the simulation file from local to dockers
  docker cp ./workspace/simulations/${SIMULATION_FILE} ${CID}:/opt/${SIMULATION_FILE}
  for ((c = 0; c < ${GATLING_NODES}; c++)); do
    docker exec kubectl-support kubectl cp /opt/${SIMULATION_FILE} ${GCP_K8_CLUSTER_NAMESPACE}/gatlingsolr-${c}:/opt/gatling/user-files/simulations/${SIMULATION_FILE}
  done
else
  rm -rf ./SIMULATION_FILE
fi

# so we're requiring REMOTE_INDEX_FILE_PATH so bash can read the ENV var
if [ ! -z "${REMOTE_INDEX_FILE_PATH}" ]; then
  # download the remote indexing file
  for ((c = 0; c < ${GATLING_NODES}; c++)); do
    docker exec kubectl-support kubectl exec -n ${GCP_K8_CLUSTER_NAMESPACE} gatlingsolr-${c} -- mkdir -p /opt/gatling/user-files/external/data/
    docker exec kubectl-support kubectl exec -n ${GCP_K8_CLUSTER_NAMESPACE} gatlingsolr-${c} -- rm -rf /opt/gatling/user-files/external/data/external.data.txt*
    if [ "$PRINT_GATLING_LOG" = true ]; then
      if [ ! -z "${REMOTE_INDEX_FILES}" ]; then
        for ((g = 0; g < ${REMOTE_INDEX_FILES}; g++)); do
          docker exec kubectl-support kubectl exec -n ${GCP_K8_CLUSTER_NAMESPACE} gatlingsolr-${c} -- curl -s -N "${REMOTE_INDEX_FILE_PATH}"${g} --output /opt/gatling/user-files/external/data/external.data.txt${g}
        done
      else
        docker exec kubectl-support kubectl exec -n ${GCP_K8_CLUSTER_NAMESPACE} gatlingsolr-${c} -- curl -s -N "${REMOTE_INDEX_FILE_PATH}" --output /opt/gatling/user-files/external/data/external.data.txt
      fi
    else
      if [ ! -z "${REMOTE_INDEX_FILE_PATH}" ]; then
        for ((g = 0; g < ${REMOTE_INDEX_FILES}; g++)); do
          docker exec -d kubectl-support kubectl exec -n ${GCP_K8_CLUSTER_NAMESPACE} gatlingsolr-${c} -- curl -s -N "${REMOTE_INDEX_FILE_PATH}"${g} --output /opt/gatling/user-files/external/data/external.data.txt${g}
        done
      else
        docker exec -d kubectl-support kubectl exec -n ${GCP_K8_CLUSTER_NAMESPACE} gatlingsolr-${c} -- curl -s -N "${REMOTE_INDEX_FILE_PATH}" --output /opt/gatling/user-files/external/data/external.data.txt
      fi
    fi
  done

  # wait until index file copies to all gatling nodes
  for ((c = 0; c < ${GATLING_NODES}; c++)); do
    IF_CMD_EXEC=$(docker exec kubectl-support kubectl exec -n ${GCP_K8_CLUSTER_NAMESPACE} gatlingsolr-${c} -- ps | grep "curl" | wc -l)
    while [ "${IF_CMD_EXEC}" != "0" ]; do
      sleep 10
      IF_CMD_EXEC=$(docker exec kubectl-support kubectl exec -n ${GCP_K8_CLUSTER_NAMESPACE} gatlingsolr-${c} -- ps | grep "curl" | wc -l)
    done
  done
fi

# so we're requiring REMOTE_UPDATE_FILE_PATH so bash can read the ENV var
if [ ! -z "${REMOTE_UPDATE_FILE_PATH}" ]; then
  # download the remote updating file
  for ((c = 0; c < ${GATLING_NODES}; c++)); do
    docker exec kubectl-support kubectl exec -n ${GCP_K8_CLUSTER_NAMESPACE} gatlingsolr-${c} -- mkdir -p /opt/gatling/user-files/external/data/
    docker exec kubectl-support kubectl exec -n ${GCP_K8_CLUSTER_NAMESPACE} gatlingsolr-${c} -- rm -rf /opt/gatling/user-files/external/data/external.update.txt*
    if [ "$PRINT_GATLING_LOG" = true ]; then
      if [ ! -z "${REMOTE_UPDATE_FILES}" ]; then
        for ((g = 0; g < ${REMOTE_UPDATE_FILES}; g++)); do
          docker exec kubectl-support kubectl exec -n ${GCP_K8_CLUSTER_NAMESPACE} gatlingsolr-${c} -- curl -s -N "${REMOTE_UPDATE_FILE_PATH}"${g} --output /opt/gatling/user-files/external/data/external.update.txt${g}
        done
      else
        docker exec kubectl-support kubectl exec -n ${GCP_K8_CLUSTER_NAMESPACE} gatlingsolr-${c} -- curl -s -N "${REMOTE_UPDATE_FILE_PATH}" --output /opt/gatling/user-files/external/data/external.update.txt
      fi
    else
      if [ ! -z "${REMOTE_UPDATE_FILES}" ]; then
        for ((g = 0; g < ${REMOTE_UPDATE_FILES}; g++)); do
          docker exec -d kubectl-support kubectl exec -n ${GCP_K8_CLUSTER_NAMESPACE} gatlingsolr-${c} -- curl -s -N "${REMOTE_UPDATE_FILE_PATH}"${g} --output /opt/gatling/user-files/external/data/external.update.txt${g}
        done
      else
        docker exec -d kubectl-support kubectl exec -n ${GCP_K8_CLUSTER_NAMESPACE} gatlingsolr-${c} -- curl -s -N "${REMOTE_UPDATE_FILE_PATH}" --output /opt/gatling/user-files/external/data/external.update.txt
      fi
    fi
  done

  # wait until update file copies to all gatling nodes
  for ((c = 0; c < ${GATLING_NODES}; c++)); do
    IF_CMD_EXEC=$(docker exec kubectl-support kubectl exec -n ${GCP_K8_CLUSTER_NAMESPACE} gatlingsolr-${c} -- ps | grep "curl" | wc -l)
    while [ "${IF_CMD_EXEC}" != "0" ]; do
      sleep 10
      IF_CMD_EXEC=$(docker exec kubectl-support kubectl exec -n ${GCP_K8_CLUSTER_NAMESPACE} gatlingsolr-${c} -- ps | grep "curl" | wc -l)
    done
  done
fi

# so we're requiring REMOTE_QUERY_FILE_PATH so bash can read the ENV var
if [ ! -z "${REMOTE_QUERY_FILE_PATH}" ]; then
  # download the remote indexing file
  for ((c = 0; c < ${GATLING_NODES}; c++)); do
    docker exec kubectl-support kubectl exec -n ${GCP_K8_CLUSTER_NAMESPACE} gatlingsolr-${c} -- mkdir -p /opt/gatling/user-files/external/data/
    docker exec kubectl-support kubectl exec -n ${GCP_K8_CLUSTER_NAMESPACE} gatlingsolr-${c} -- rm -rf /opt/gatling/user-files/external/data/external.query.txt*
    if [ "$PRINT_GATLING_LOG" = true ]; then
      if [ ! -z "${REMOTE_QUERY_FILES}" ]; then
        for ((g = 0; g < ${REMOTE_QUERY_FILES}; g++)); do
          docker exec kubectl-support kubectl exec -n ${GCP_K8_CLUSTER_NAMESPACE} gatlingsolr-${c} -- curl -s -N "${REMOTE_QUERY_FILE_PATH}"${c} --output /opt/gatling/user-files/external/data/external.query.txt${c}
        done
      else
        docker exec kubectl-support kubectl exec -n ${GCP_K8_CLUSTER_NAMESPACE} gatlingsolr-${c} -- curl -s -N "${REMOTE_QUERY_FILE_PATH}" --output /opt/gatling/user-files/external/data/external.query.txt
      fi
    else
      if [ ! -z "${REMOTE_QUERY_FILES}" ]; then
        for ((g = 0; g < ${REMOTE_QUERY_FILES}; g++)); do
          docker exec -d kubectl-support kubectl exec -n ${GCP_K8_CLUSTER_NAMESPACE} gatlingsolr-${c} -- curl -s -N "${REMOTE_QUERY_FILE_PATH}"${g} --output /opt/gatling/user-files/external/data/external.query.txt${g}
        done
      else
        docker exec -d kubectl-support kubectl exec -n ${GCP_K8_CLUSTER_NAMESPACE} gatlingsolr-${c} -- curl -s -N "${REMOTE_QUERY_FILE_PATH}" --output /opt/gatling/user-files/external/data/external.query.txt
      fi
    fi
  done

  # wait until query file copies to all gatling nodes
  for ((c = 0; c < ${GATLING_NODES}; c++)); do
    IF_CMD_EXEC=$(docker exec kubectl-support kubectl exec -n ${GCP_K8_CLUSTER_NAMESPACE} gatlingsolr-${c} -- ps | grep "curl" | wc -l)
    while [ "${IF_CMD_EXEC}" != "0" ]; do
      sleep 10
      IF_CMD_EXEC=$(docker exec kubectl-support kubectl exec -n ${GCP_K8_CLUSTER_NAMESPACE} gatlingsolr-${c} -- ps | grep "curl" | wc -l)
    done
  done
fi

# set gatling nodes heap settings
sed -i "s/replace-heap-settings/${GATLING_HEAP}/" ./jenkins/k8s/gatling.sh
docker cp ./jenkins/k8s/gatling.sh ${CID}:/opt/gatling.sh
# create results directory on the docker
for ((c = 0; c < ${GATLING_NODES}; c++)); do
  docker exec kubectl-support kubectl cp /opt/gatling.sh ${GCP_K8_CLUSTER_NAMESPACE}/gatlingsolr-${c}:/opt/gatling/bin/gatling.sh
done

# execute the load test on docker
echo "JOB DESCRIPTION: running....."

# read each class and execute the tests
while read -r CLASS; do

  # create results directory on the docker
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

if [ "$IMPLICIT_CLUSTER" = true ]; then
  # copy the logs to the workspace
  docker exec kubectl-support kubectl cp ${GCP_K8_CLUSTER_NAMESPACE}/solr-dummy-cluster-0:/opt/solr/logs /opt/solr-logs
  docker cp ${CID}:/opt/solr-logs ./workspace/reports-${BUILD_NUMBER}/solr-logs
fi

# TODO: remove executing commands within the solr cluster and utilise Collection Admin API
# if [ "$IMPLICIT_CLUSTER" = true ] ; then
# docker exec kubectl-support kubectl exec -n ${GCP_K8_CLUSTER_NAMESPACE} solr-dummy-cluster-0 -- /opt/solr/bin/solr delete -c wiki || echo "create collection now"
# else
# docker exec kubectl-support kubectl exec -n ${GCP_K8_CLUSTER_NAMESPACE} ${EXT_SOLR_NODE_POD_NAME} -- /opt/solr/bin/solr delete -c wiki || echo "create collection now"
# fi

#delete gatling services
docker exec kubectl-support kubectl delete -f /opt/cluster.yaml || echo "gatling service already deleted!!"
