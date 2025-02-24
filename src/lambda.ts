import "./config";
import { SQSEvent, SQSHandler, APIGatewayEvent, APIGatewayProxyHandler, APIGatewayProxyResult } from "aws-lambda";
import { Client } from "@opensearch-project/opensearch";
import { AwsSigv4Signer } from "@opensearch-project/opensearch/lib/aws";
import { ResponseError } from "@opensearch-project/opensearch/lib/errors";
import { join } from "path";
import { off } from "process";

interface Model {
  index: string;
  id: number;
  data: any;
}

interface Query {
  searchedFieldListWithAlias?: any,
  fromTopic?: string,
  alias?: string,
  listOpenSearchJoinInfo?: any,
  searchWhere?: any
}

export const handler: SQSHandler = async (event: SQSEvent) => {
  for (const record of event.Records) {
    try {
      const { body, receiptHandle } = record;
      const message = JSON.parse(body);

      const openSearchClient = buildOpenSearchClient();

      const model: Model = {
        index: message.topic,
        id: message.id,
        data: message,
      };

      await openSearchClient.index({
        index: model.index,
        id: model.id?.toString(),
        body: model.data,
      }); 

      console.log("Dados indexados no OpenSearch:", model);
    } catch (error) {
      if (error instanceof ResponseError) {
        console.error("ResponseError details:", error.meta.body);
        return;
      }

      console.error("Error processing record:", record);
      console.error("Error details:", error);
    }
  }
};

export const apiGatewayHandler: APIGatewayProxyHandler = async (
  event: APIGatewayEvent
): Promise<APIGatewayProxyResult> => {
  let params = event.queryStringParameters || {};

  const offset = Number(params.offset) || 0;
  const limit = Number(params.limitPerPage) || 10;
  const query: Query = params.query ? JSON.parse(params.query) : {};

  let fieldsToSearch = ""
  if (query.searchedFieldListWithAlias.length === 0) {
    fieldsToSearch += "*";
  } else {
    fieldsToSearch += query.searchedFieldListWithAlias.join();
  }

  const selectQuery = buildQuery(query, limit, offset); 
  
  console.log(selectQuery);

  const openSearchClient = buildOpenSearchClient();
  const openSearchResponse = await openSearchClient.transport.request({
    method: "POST",
    path: "_plugins/_sql",
    body: {
      query: "SELECT " + fieldsToSearch + selectQuery + " LIMIT " + limit + " OFFSET " + offset 
    }
  })

  const columns = openSearchResponse.body.schema.map((col: any) => col.name);
  const data = openSearchResponse.body.datarows.map((row: any[]) => {
    return row.reduce((acc, value, index) => {
      acc[columns[index]] = value;
      return acc;
    }, {} as Record<string, any>);
  });

  const items = data;

  const response = await openSearchClient.transport.request({
    method: "POST",
    path: "_plugins/_sql",
    body: {
      query: "SELECT query.id" + selectQuery
    }
  })

  const totalCount = response.body.total;

  return buildResponse(items, totalCount);
};

const buildOpenSearchClient = () => {
  return new Client({
    ...AwsSigv4Signer({
      region: "sa-east-1",
      getCredentials: async () => ({
        accessKeyId: process.env.AWS_ACCESS_KEY_ID!,
        secretAccessKey: process.env.AWS_SECRET_ACCESS_KEY!,
      }),
    }),
    node: process.env.OPENSEARCH_NODE!,
    requestTimeout: 60000,
  });
};

const buildQuery = (queryParams: Query, limit: Number, offset: Number) => {
  let fieldsToSearch = ""
  if (queryParams.searchedFieldListWithAlias.length === 0) {
    fieldsToSearch += "*";
  } else {
    fieldsToSearch += queryParams.searchedFieldListWithAlias.join();
  }

  let from = queryParams.fromTopic + " " + queryParams.alias

  let joinClause = "";  
  for (let joinDomain of queryParams.listOpenSearchJoinInfo) {
    joinClause += " join " + joinDomain.domainToJoin + " " + joinDomain.alias + " on " + joinDomain.joinCondition
  }

  let where = ""
  if (queryParams.searchWhere?.length > 0) {
    where = " WHERE " + queryParams.searchWhere.join(" AND ");
  }

  return " FROM " + from + joinClause + where;
};

const buildResponse = (items: any, totalCount: Number) => {
  const body = { items, totalCount };
  return {
    statusCode: 200,
    body: JSON.stringify(body),
  };
};