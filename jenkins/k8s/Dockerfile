FROM openjdk:11-jre

MAINTAINER Rohit Singh <rohit.singh@lucidworks.com>

# working directory for jenkins load testing
WORKDIR /opt

ENV GATLING_VERSION=3.0.0

# Install gcloud, kubectl, aws ekctl
RUN \
    export CLOUD_SDK_REPO="cloud-sdk" && \
    echo "deb http://packages.cloud.google.com/apt $CLOUD_SDK_REPO main" | tee -a /etc/apt/sources.list.d/google-cloud-sdk.list && \
    curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add - && \
    apt-get update -y && apt-get install google-cloud-sdk kubectl -y && \
    apt-get install wget -y && \
    curl -sL https://aka.ms/InstallAzureCLIDeb |    bash && \
    curl "https://s3.amazonaws.com/aws-cli/awscli-bundle.zip" -o "awscli-bundle.zip" && \
    unzip awscli-bundle.zip && \
    ./awscli-bundle/install -i /usr/local/aws -b /usr/local/bin/aws && \
    rm -rf awscli-bundle* && \
    curl --silent --location "https://github.com/weaveworks/eksctl/releases/download/latest_release/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp && \
    mv /tmp/eksctl /usr/local/bin

# install gatling
RUN apt-get install wget bash && \
  mkdir -p /tmp/downloads/ && \
  wget -q -O /tmp/downloads/gatling-${GATLING_VERSION}.zip \
  https://repo1.maven.org/maven2/io/gatling/highcharts/gatling-charts-highcharts-bundle/${GATLING_VERSION}/gatling-charts-highcharts-bundle-${GATLING_VERSION}-bundle.zip && \
  mkdir -p /tmp/archive && cd /tmp/archive && \
  unzip /tmp/downloads/gatling-${GATLING_VERSION}.zip && \
  mkdir -p /opt/gatling/ && \
  mv /tmp/archive/gatling-charts-highcharts-bundle-${GATLING_VERSION}/* /opt/gatling/ && \
  rm -rf /tmp/*

# set environment variables
ENV PATH /opt/gatling/bin:/usr/local/sbin:/usr/bin/gcloud:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ENV GATLING_HOME /opt/gatling












    
CMD tail -f /dev/null