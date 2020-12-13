import java.util.concurrent.{Executors, ThreadFactory, TimeUnit}

import com.fasterxml.jackson.databind.ObjectMapper
import io.gatling.core.Predef._
import io.gatling.http.Predef._
import scalaj.http.Http

class ConstantQueryHttpSimulation extends Simulation {

  object Conf {

    def envVar(key: String): Option[String] = {
      val fromEnv = System.getenv(key.toUpperCase.replace('.', '_'))
      if (fromEnv != null && !fromEnv.trim.isEmpty) {
        Option.apply(fromEnv.trim)
      } else {
        Option.empty
      }
    }

    def getInt(key: String, dv: Integer): Integer = {
      val fromProp = System.getProperty(key)
      if (fromProp != null && !fromProp.trim.isEmpty) {
        Integer.parseInt(fromProp.trim)
      } else {
        val maybe = envVar(key)
        if (maybe.isDefined) {
          Integer.parseInt(maybe.get)
        } else {
          dv
        }
      }
    }

    def getStr(key: String, dv: String): String = {
      val fromProp = System.getProperty(key)
      if (fromProp != null && !fromProp.trim.isEmpty) {
        fromProp.trim
      } else {
        envVar(key).getOrElse(dv)
      }
    }

    val queriesPerSecond = getInt("qps.rps", 1)
    val usersPerSecond = getInt("usersPerSecond", 1)
    //val testDurationMins = getInt("qps.duration.mins", 60)
    val testDurationMins = getInt("qps.duration.mins", 1)
    //val queryFeederSource = getStr("qps.feeder.source", "data/BN-prod-5k-reqs.csv")
    val queryFeederSource = getStr("qps.feeder.source", "/Users/rohit/Desktop/zola_registry/output/tsv_solr_queries.txt")
    val rampDurationSecs = getInt("qps.ramp.secs", 10)
    val proxyHostAndPort = getStr("qps.fusion.url", "http://localhost:8764")
    val appId = getStr("qps.app", "test_zola")
    //val queryUrl = getStr("qps.query.url", s"${proxyHostAndPort}/api/apps/${appId}/query/${appId}")
    val queryUrl = getStr("qps.query.url", s"http://localhost:8764/api/apps/test_zola/query/zola_registry")
    val username = getStr("qps.fusion.user", "admin")
    val password = getStr("qps.fusion.pass", "root12345")

    val jsonObjectMapper = new ObjectMapper
    var jwtToken = ""
    var jwtExpiresIn : Long = 1790L

    def logConfig() = {
      println("\nConfigured FusionQueryTraffic Simulation with:")
      println(s"\t qps.rps = ${queriesPerSecond}")
      println(s"\t qps.duration.mins = ${testDurationMins}")
      println(s"\t qps.feeder.source = ${queryFeederSource}")
      println(s"\t qps.ramp.secs = ${rampDurationSecs}")
      println(s"\t qps.fusion.url = ${proxyHostAndPort}")
      println(s"\t qps.app = ${appId}")
      println(s"\t qps.query.url = ${queryUrl}")
      println(s"\t qps.fusion.user = ${username}")
      println("")
    }

    def updateJwtToken() = {
      val loginUrl = s"${proxyHostAndPort}/oauth2/token"
      val jsonResp = Http(loginUrl).postData("").auth(username, password)
          .execute(parser = {inputStream => jsonObjectMapper.readTree(inputStream)})
      if (!jsonResp.is2xx) throw new RuntimeException(s"Failed to login to ${loginUrl} due to: ${jsonResp.code}")
      jwtToken = jsonResp.body.get("access_token").asText()
      val expires_in = jsonResp.body.get("expires_in").asLong()
      val grace_secs = if (expires_in > 15L) 10L else 2L
      jwtExpiresIn = expires_in - grace_secs
      println(s"Successfully refreshed global JWT for load test ... will do again in ${jwtExpiresIn} secs")
    }

    // This function is rife with side-effects ;-)
    def initJwtAndStartBgRefreshThread() = {

      // Get the initial token ...
      updateJwtToken
      println(s"Received initial JWT from POST to ${proxyHostAndPort}/oauth2/token: ${jwtToken}\n")

      // Schedule a background task to refresh it before the token expires
      // Make the thread a daemon so the JVM can exit
      class DaemonFactory extends ThreadFactory {
        override def newThread(r: Runnable): Thread = {
          val t = new Thread(r)
          t.setDaemon(true)
          t
        }
      }
      val ex = Executors.newSingleThreadScheduledExecutor(new DaemonFactory)
      val task = new Runnable {
        def run() = updateJwtToken
      }
      ex.scheduleAtFixedRate(task, jwtExpiresIn, jwtExpiresIn, TimeUnit.SECONDS)
      println(s"Started background thread to refresh JWT in ${jwtExpiresIn} seconds from now ...\n")
    }
  }

  object Query {

    Conf.logConfig()
    //Conf.initJwtAndStartBgRefreshThread()

    // expect the query CSV file to contain a column named "params"
    val feeder = separatedValues(Conf.queryFeederSource, '\t').convert {
      case ("params", params) => {
        val at = params.indexOf("?")
        var queryParams = if (at != -1) params.substring(at+1) else params
        queryParams
      }
    }.circular

    val saveGlobalJWTInSession = exec { session => session.set("jwt", Conf.jwtToken) }

    val searchWithBasicAuth = feed(feeder)
        .exec(http("Query").get("?${params}")
            .basicAuth(Conf.username, Conf.password).check(status.in(200, 204)))

    val searchWithJWT = feed(feeder)
        .exec(http("Query").get("?${params}")
            .header("Authorization", "Bearer ${jwt}").check(status.in(200, 204)))
  }

  var httpConf = http
      .baseUrl(Conf.queryUrl)
      .acceptHeader("application/json,application/xml;q=0.9,*/*;q=0.8")
      .doNotTrackHeader("1")
      .acceptLanguageHeader("en-US,en;q=0.5")
      .acceptEncodingHeader("gzip, deflate")
      .userAgentHeader("Mozilla/5.0 (Macintosh; Intel Mac OS X 10.8; rv:16.0) Gecko/20100101 Firefox/16.0")
      .maxConnectionsPerHost(1000)
      .shareConnections
      .warmUp(s"${Conf.proxyHostAndPort}/api")


  //val qps = scenario("QPS-" + Conf.queriesPerSecond).exec(Query.saveGlobalJWTInSession).exec(Query.searchWithJWT)
  val qps = scenario("QPS-" + Conf.queriesPerSecond).exec(Query.searchWithBasicAuth)

  //Add users per second at constant rate for X minutes
  setUp(
    qps.inject(
      constantUsersPerSec(Conf.usersPerSecond.doubleValue()) during (Conf.testDurationMins minutes))
  ).protocols(httpConf)
}