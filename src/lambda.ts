import "./config";
import { SQSEvent, SQSHandler, APIGatewayEvent, APIGatewayProxyHandler, APIGatewayProxyResult } from "aws-lambda";
import { Client } from "@opensearch-project/opensearch";
import { AwsSigv4Signer } from "@opensearch-project/opensearch/lib/aws";
import { ResponseError } from "@opensearch-project/opensearch/lib/errors";

interface Model {
  index: string;
  id: number;
  data: any;
}

export const handler: SQSHandler = async (event: SQSEvent) => {
  for (const record of event.Records) {
    try {
      const { body, receiptHandle } = record;
      let message = JSON.parse(body);
      
      const updateFields = message.updateAnotherTopicList;
      delete message.updateAnotherTopicList;

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

      if (updateFields.length > 0) {
        for (const field of updateFields) {
          let scriptSource = "";
          const params: { [key: string]: any } = {};

          for (const fieldInfo of field.fieldValueInfo) {
            scriptSource += `ctx._source.${fieldInfo.fieldName} = params.${fieldInfo.fieldName};`;
            params[fieldInfo.fieldName] = fieldInfo.fieldValue;
          }

          await openSearchClient.updateByQuery({
            index: field.topic,
            body: {
              script: {
                source: scriptSource,
                params: params
              },
              query: {
                term: {
                  [field.referenceFieldName]: field.referenceId
                }
              }
            }
          });
        }
      }

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

  const from = Number(params.offset) || 0;
  const pageSize = Number(params.limitPerPage) || 10;
  const searchStr = params.search?.replace(/[{}]/g, "") || "";
  const topic = params.topic || "";

  const searchAttributes = buildSearchAttributes(topic, searchStr, from, pageSize);
  const openSearchClient = buildOpenSearchClient();
  const openSearchResponse = await openSearchClient.search(searchAttributes);
  const items = openSearchResponse.body.hits?.hits.map((hit: any) => hit._source);
  const totalCount = openSearchResponse.body.hits?.total?.value;

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
  });
};

const buildSearchAttributes = (topic: string, searchStr: string, from: number, pageSize: number) => {
  return {
    index: topic,
    body: {
      query: buildQuery(searchStr),
      sort: [
        {
          id: "asc",
        },
      ],
      from,
      size: pageSize,
    },
  };
};

const buildQuery = (searchStr: string) => {
  if (!searchStr) return { match_all: {} };

  const mustQueries = searchStr.split(",").map((pair) => {
    const [key, value] = pair.split("=");
    return {
      match: {
        [key.trim()]: value.trim(),
      },
    };
  });

  return { bool: { must: mustQueries } };
};

const buildResponse = (items: any, totalCount: Number) => {
  const body = { items, totalCount };
  return {
    statusCode: 200,
    body: JSON.stringify(body),
  };
};
