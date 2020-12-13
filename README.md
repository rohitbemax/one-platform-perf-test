# One Platform Perf Tests

Gatling is a powerful open-source load and performance testing tool for web applications. 
Solr is the popular, blazing-fast, open source enterprise search platform built on Apache Lucene.

The intention of the project is make a robust framework to load test SolrCloud clusters; both dynamic indexing and querying.

The project is created in five modules:
### Dynamic Query Creator
### Gatling Solr DSL
### Gatling Solr Docker
### Gatling Solr Kubernetes
### Gatling Solr Jenkins

Note in this project we have utilised Wikipedia dump available here. Note: we have cleaned the data to get rid of special characters, HTML tags etc. to have proper text and numbers.

# Dynamic Query Creator

To perform load testing for querying, we need good randomized mix queries.

WikiIndexer - load entire data to dummy solr collection to make it ready for QuerySampler
QuerySampler - perform json faceting on dummy solr collection, pick random text values from fields, query collection again, and repeat the process again to create random queries and write it to a file.
FusionQueryCreator - read file created from QuerySampler and create classic Solr syntax queries with random rows, start, sort fields order etc.
SolrFacetQueryCreator -  read file created from QuerySampler and create JSON Facet Solr syntax queries with random rows, start, sort fields order etc.

Custom Query Creator - ‘highlighting’ ‘spell checking’ ‘suggestions’ randomized query params can be added in  SolrFacetQueryCreator or FusionQueryCreator.

JSON facet queries are created as -

            String json_string = "&" +
                    "json.facet={" +
                    "titles : {" +
                    "type : terms," +
                    "field : " + (r.nextBoolean() ? "title_t_sort" : "description_t_sort") + "," +
                    "limit : " + (String.valueOf(r.nextInt(
                            r.nextInt(100) + 1) + 1)) + "," +
                    "mincount : " + (String.valueOf(r.nextInt(
                            r.nextInt(10) + 1) + 1)) +
                    "}" +
                    "}";

            query += json_string;

# Gatling Solr DSL

Gatling supports HTTP endpoints for load testing, but it is not enough for SolrCloud cluster as a single node will become aggregator node everytime. Inspired by Kafka and JDBC DSL frameworks for Gatling, project is created.

Compile and Deploy

git clone https://github.com/sarkaramrit2/gatling-solr.git
cd gatling-solr
sbt assembly
cp target/gatling-solr*.jar GATLING_HOME/lib/

## DSL

val solrConf = solr.zkhost(Config.zkHost).collection(Config.defaultCollection)
 .numClients(Config.numClients.toInt).properties(Config.prop)

solr("queryRequest")
     // query to do
     .query[String](Config.basequery)

Sample code for Query:

object Query {
 // construct a feeder for our query params stored in the csv
 val feeder = tsv(Config.queryFeederSource).circular

 // each user sends loops queries
 val search = repeat(Config.numQueriesPerUser) {
   feed(feeder).exec(solr("queryRequest")
     // query to do
     .query[String](Config.basequery))
 }
}

// pass zookeeper string, default collection to query, poolSize for CloudSolrClients
val solrConf = solr.zkhost(Config.zkHost).collection(Config.defaultCollection)
 .numClients(Config.numClients.toInt).properties(Config.prop)

// A scenario where users execute queries
val users = scenario("Users").exec(Query.search)

setUp(
 users.inject(
   constantUsersPerSec(Config.maxNumUsers.toDouble) during (Config.totalTimeInMinutes.toDouble minutes),
   rampUsersPerSec(Config.minNumUsers.toDouble) to Config.maxNumUsers.toDouble during
     (Config.totalTimeInMinutes.toDouble minutes))
).protocols(solrConf)

Sample code for Index:

object Index {
 // construct a feeder for content stored in CSV file
 val feeder = solrIndexV2Feeder

 // each user sends batches
 val search = repeat(Config.numBatchesPerUser) {
   feed(feeder).exec(solr("indexRequest")
     .indexV2(Config.header, feeder.next.get("record").get)) // provide appropriate header
 }
}

// pass zookeeper string, default collection to index, poolSize for CloudSolrClients
val solrConf = solr.zkhost(Config.zkHost).collection(Config.defaultCollection)
 .numClients(Config.numClients.toInt).properties(Config.prop)

// A scenario where users execute queries
val users = scenario("Users").exec(Index.search)

setUp(
 users.inject(
   atOnceUsers(Config.maxNumUsers.toInt))
).protocols(solrConf)


Property file path must be defined in the Simulation scala file.

The parameters needs to specified in index.config.properties:

indexFilePath -- absolute path to file to be indexed, allowed CSV, TSV.
numBatchesPerUser -- total batches of docs per user / concurrent thread, default.
maxNumUsers -- max number of users to be ramped up for testing, default.
minNumUsers -- min number of users for testing before ramping, default.
totalTimeInMinutes -- total time the users will make requests, default.
indexBatchSize -- total docs per batch for each users, default.
zkHost -- zookeeper string of the solr cluster, default.
defaultCollection -- collection docs to be indexed to, default.
header -- field names to be indexed in order, default.
header.sep -- separator for header to be split to generate field names, default.
fieldValues.sep -- separator each line in index file to be split on.
numClients -- total number of CloudSolrClients need to be used for testing.

The parameters needs to specified in query.config.properties:

queryFeederSource -- absolute path to file to be used for feeding queries.
numQueriesPerUser -- total number of queries per user.
maxNumUsers -- max number of users to be ramped up for testing, default.
minNumUsers -- min number of users for testing before ramping, default.
totalTimeInMinutes -- total time the users will make requests, default.
basequery -- query string with defaults specified.
zkHost -- zookeeper string of the solr cluster, default.
defaultCollection -- collection docs to be indexed to, default.
numClients -- total number of CloudSolrClients need to be used for testing.

Sample property files available here.

Sample Simulation scala files available here.

#### QuerySimulation 
#### IndexV2Simulation 

# Gatling Solr Docker

Gatling-Solr docker available at: https://cloud.docker.com/u/sarkaramrit2/repository/docker/sarkaramrit2/gatling-solr

Dockerfile for the project available here.

Using image to run container:
docker run -it -d --rm --name gatling-solr sarkaramrit2/gatling-solr
 
Run Simulation loaded and pass relevant parameters:
docker exec gatling-solr gatling.sh -s QuerySimulation -rd "--query-simulation--"
 
Mount configuration and simulation files from the host machine and run gatling:
docker run -it -d --rm -v configs:/opt/gatling/user-files/configs/ simulations:/opt/gatling/user-files/simulations/ \ --name gatling-solr sarkaramrit2/gatling-solr
 
Resources - 
GATLING_HOME set at /opt/gatling.
Property configs to be put under /opt/gatling/user-files/configs/.
Respective data files to be put under /opt/gatling/user-files/data/.
Default configs for Gatling under /opt/gatling/conf/.
Simulation scala files available under /opt/gatling/user-files/simulations/.
 
How to run test and generate reports with Docker

Sample script available here with appropriate comments.

# Gatling Solr Kubernetes

YAML file available here.

 apiVersion: v1
 kind: Pod
 metadata:
   name: gatling-solr
   labels:
     app: job
 spec:
   containers:
     - name: gatling-solr
       image: sarkaramrit2/gatling-solr:latest
       ports:
         - containerPort: 80

Steps to run

start K8 container
kubectl describe -f k8-pod.yaml 

running tests on container ‘gatling-solr’
kubectl exec gatling-solr -- gatling.sh -s QuerySimulation -rd "--query-simulation--"

running tests on custom configs, simulations, data etc
kubectl cp  PATH_TO/configs <some-namespace>/gatling-solr:/opt/gatling/user-files/configs
kubectl cp  PATH_TO/simulations <some-namespace>/gatling-solr:/opt/gatling/user-files/simulations
kubectl cp  PATH_TO/data <some-namespace>/gatling-solr:/opt/gatling/user-files/data

e.g. kubectl cp configs default/gatling-solr:/opt/gatling/user-files/configs
e.g. kubectl cp simulations default/gatling-solr:/opt/gatling/user-files/simulations

kubectl exec gatling-solr -- gatling.sh -s QuerySimulation -rd "--query-simulation--" #run-in-foreground
// kubectl exec gatling-solr -- gatling.sh -s IndexV2Simulation -rd "--index-simulation--"

Sample script available here.
