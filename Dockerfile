FROM amazoncorretto:latest

MAINTAINER Rohit Singh <rohit.singh@lucidworks.com>

# working directory for gatling
WORKDIR /opt

# gating version
ENV GATLING_VERSION=3.0.0 \
    SOLR_VERSION=8.4.1 \
    SCALA_VERSION=2.12.7 \
    SBT_VERSION=1.2.1 \
    GATLING_SOLR_BRANCH=main

# Install Scala
RUN \
  yum update -y && yum install -y gzip epel-release && \
  yum repolist update -y; yum install curl tar -y && \
  curl -fsL https://downloads.typesafe.com/scala/$SCALA_VERSION/scala-$SCALA_VERSION.tgz | tar xfz - -C /root/ && \
  echo >> /root/.bashrc && \
  echo "export PATH=~/scala-$SCALA_VERSION/bin:$PATH" >> /root/.bashrc

# Install sbt
RUN \
  curl -L -o sbt-$SBT_VERSION.rpm https://dl.bintray.com/sbt/rpm/sbt-$SBT_VERSION.rpm && \
  rpm -U sbt-$SBT_VERSION.rpm && \
  rm sbt-$SBT_VERSION.rpm && \
  yum update && \
  yum install sbt && \
  sbt sbtVersion

#install git and create gatling-solr library
RUN yum update && \
    yum upgrade -y && \
    yum install -y git && \
    mkdir -p /tmp/downloads/gatling-solr && \
    cd /tmp/downloads/gatling-solr && \
    git clone https://github.com/rohitbemax/one-platform-perf-test.git && \
    cd /tmp/downloads/gatling-solr/one-platform-perf-test && \
    git checkout $GATLING_SOLR_BRANCH && \
    sbt clean assembly && \
    # install ps
    yum install procps -y && \
    cd /

# install gatling
RUN yum install -y wget bash unzip && \
  wget -q -O /tmp/downloads/gatling-$GATLING_VERSION.zip \
  https://repo1.maven.org/maven2/io/gatling/highcharts/gatling-charts-highcharts-bundle/$GATLING_VERSION/gatling-charts-highcharts-bundle-$GATLING_VERSION-bundle.zip && \
  mkdir -p /tmp/archive && cd /tmp/archive && \
  unzip /tmp/downloads/gatling-$GATLING_VERSION.zip && \
  mkdir -p /opt/gatling/ && \
  mv /tmp/archive/gatling-charts-highcharts-bundle-$GATLING_VERSION/* /opt/gatling/

# copy libraries, simulations, config files and remove tmp directly
RUN mkdir -p /opt/gatling/user-files/simulations/ && \
    mkdir -p /opt/gatling/user-files/configs/ && \
    cp /tmp/downloads/gatling-solr/one-platform-perf-test/src/test/scala/* /opt/gatling/user-files/simulations/ && \
    rm -rf /opt/gatling/user-files/simulations/computerdatabase && \
    cp /tmp/downloads/gatling-solr/one-platform-perf-test/src/test/resources/configs/* /opt/gatling/user-files/configs/ && \
    cp -rf /tmp/downloads/gatling-solr/one-platform-perf-test/src/test/resources/data /opt/gatling/user-files/ && \
    cp /tmp/downloads/gatling-solr/one-platform-perf-test/src/test/resources/gatling.conf /opt/gatling/conf/ && \
    cp /tmp/downloads/gatling-solr/one-platform-perf-test/src/test/resources/logback.xml /opt/gatling/conf/ && \
    cp /tmp/downloads/gatling-solr/one-platform-perf-test/src/test/resources/recorder.conf /opt/gatling/conf/ && \
    rm -rf /tmp/*

## copy large files to docker if present
#RUN mkdir -p /opt/gatling/user-files/external/data
#COPY ./src/test/resources/external/data/ /opt/gatling/user-files/external/data/

# change context to gatling directory
WORKDIR  /opt/gatling

# set directories below to be mountable from host
VOLUME ["/opt/gatling/conf", "/opt/gatling/results", "/opt/gatling/user-files"]

# set environment variables
ENV PATH /opt/gatling/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ENV GATLING_HOME /opt/gatling

CMD tail -f /dev/null
