name := "one-platform-perf-tests"

organization := "com.lucidworks"

version := "1.0.0-SNAPSHOT"

scalaVersion := "2.12.7"

libraryDependencies ++= Seq(
  "io.gatling" % "gatling-core" % "3.0.1" % "provided",
  "io.gatling.highcharts" % "gatling-charts-highcharts" % "3.0.1" % "provided",
  "io.gatling" % "gatling-app" % "3.0.1" % "provided",
  "io.gatling" % "gatling-recorder" % "3.0.1" % "provided",
  "com.opencsv" % "opencsv" % "4.4" % "provided",
  ("org.apache.solr" % "solr-solrj" % "8.4.1")
    // Gatling contains slf4j-api
    .exclude("org.slf4j", "slf4j-api"),
  "ch.qos.logback" % "logback-classic" % "1.2.3",
  "org.scalaj" % "scalaj-http_2.12" % "2.4.2"
)

// Gatling contains scala-library
assemblyOption in assembly := (assemblyOption in assembly).value
  .copy(includeScala = false)

Compile / unmanagedJars := (baseDirectory.value / "custom-libs" ** "*.jar").classpath

assemblyMergeStrategy in assembly := {
  case PathList("META-INF", xs @ _*) => MergeStrategy.discard
  case x => MergeStrategy.first
}