//import org.apache.solr.common.SolrInputDocument;
//
//import java.io.BufferedReader;
//import java.io.FileReader;
//import java.util.ArrayList;
//import scala.io.Source
//
//class ConstantIndexLoadSimulation {
//
//    def readDocument(pathToJsonDump: String) :  {
//        So
//        val solrDocumentsAsJsonString = Source.fromFile(pathToJsonDump).getLines.toList
//
//
//        val reader = new BufferedReader(new FileReader(pathToJsonDump))
//        var String line = reader.readLine();
//        JSONParser parser = new JSONParser();
//        JSONObject jsonObject = null;
//        while (line != null) {
//
//            //One line is one SolrDocument
//            jsonObject = (JSONObject) parser.parse(line)
//            //System.out.println(jsonObject.toJSONString())
//            if(jsonObject != null) {
//                SolrInputDocument solrInputDocument = new SolrInputDocument();
//
//                jsonObject.forEach((key, value) -> {
//                    if (key.equals("")) {
//                        System.out.println("Key is empty will skip");
//                    } else {
//                        addFieldToSolrDocument(solrInputDocument, key + "", value + "");
//                    }
//                });
//
//                documentList.add(solrInputDocument);
//
//                if (documentList.size() == ConstantList.BATCH_SIZE) {
//                    //We will index to Solr per 5K documents and then reset the list
//                    System.out.println("Adding a batch of documents");
//                    updateAndCommitDocuments(documentList);
//                    documentList = new ArrayList<>();
//
//                }
//            }
//
//            numOverallDocuments++;
//            line = reader.readLine();
//        }
//    }
//}
